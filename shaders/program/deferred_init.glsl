// 初始化 pass: deferred_init（deferred 阶段）
// vsh = 通用全屏 vsh（program/fullscreen_vsh.glsl——帧数据 varying 的唯一来源，
// 本 program 无自定义 vsh 段）；fsh 按需声明同名 in
// 位于不透明 gbuffers 之后、半透明之前；初始化场景颜色 colortex0：
// 位置重建统一去抖基底——减 vJitter（vsh 帧数据）去当前帧 TAA jitter 后的屏幕空间 uv，天空视线（z = 1
// 远平面）与几何 viewPos（z = 本像素 depthtex1 原始深度）共用同一组 xy（几何 vsh 抖动 +J 后本像素含
// 「位置 −J」处场景，去抖重建得到几何真实位置；几何信息采样 texelFetch(gl_FragCoord) 精确
// 纹素——内容按抖动光栅落位、逐像素与缓冲一一对应，不经滤波路径、无需 vTexCoord）——天空与深度缓冲几何在地平线边界像素内衔接一致、阴影贴图（不注入抖动）
// 的采样位置逐帧对齐不随 16 相位翻动，composite_taa 时间累积平滑 LUT 双线性 facets 与
// 地平线几何边界
// 天空像素（depthtex1 >= 1）采样 colortex7 sky-view LUT（atmosphere/sky.glsl 的 getSkyColor，
// 光源方向与地平线几何取 vsh 帧数据，200×100 太阳半区、composite12 上帧生成；Hillaire 非线性参数化集中于地平线与太阳侧）——
// 时序关键：天空在本 pass 进入 colortex0，之后的半透明（water / weather / hand_water）引擎
// 混合才有正确天空背景，这也是天空画在 composite（半透明之后）做不到的
// 深度取 depthtex1（纯不透明几何）：depthtex0 在 deferred 时刻可能已混入 deferred 前绘制的
// textured 族（粒子 / 闪电）深度，天空判定须以纯不透明深度为准
// colortex0 自此全程线性：前向半透明按线性混合，final 在线性域合成 bloom 并 tonemap，
// 其末段的 linearToSrgb 是唯一离开线性空间的位置
// 几何光照：读 colortex4（albedo + 高光）、colortex5（观察空间法线 + 原始 lmcoord，重映射见
// pipeline/gbuffer_data.glsl remapLightmap）、去抖 uv + depthtex1 原始深度重建观察空间位置后经
// lib/lighting/lighting.glsl 的 shadeSurface 着色（直接光 = shadowtex 阴影可见性 × 相机高度近似的大气透射率
// × 直射辐照度；透射率与光源方向 / 时间 / 颜色基色均由 vsh 帧数据提供，见 lib/lighting/shadow.glsl）

#define FULLSCREEN_DIRECT_TRANSMITTANCE

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/jitter.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/program/fullscreen_vsh.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/lighting/shadow.glsl"
#ifdef STAGE_FRAGMENT
// 通用全屏 vsh 输出的帧数据——按需 in 声明；须位于 lighting.glsl 之前（shadeSurface 直接引用
// 同名全局），getSkyColor 的方向 / 地平线 / LUT 有效性经参数传入
in vec2 vJitter;
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vLightDirection;
in float vSunHeight;
in vec3 vDirectIrradiance;
in vec3 vDirectTransmittance;
in vec3 vSkyAmbient;
in vec3 vHorizon;
flat in float vSkyLutValid; // 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）
#endif
#include "/lib/lighting/lighting.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    // 几何信息（depthtex1 / colortex4/5）texelFetch 精确纹素读取——不插值、无 vTexCoord
    //（全屏 pass 逐像素与缓冲一一对应，与 composite_taa 的锚点采样同款纪律）
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex1, pixel, 0).r;

    // 统一去抖 uv：gl_FragCoord 像素中心 uv（与 vTexCoord 像素中心插值等价）− 当前帧 jitter
    //（vsh 帧数据 vJitter，与几何抖动同相位），天空视线与几何 viewPos 共用的位置重建基底
    //（[0,1] 屏幕空间，z 各取远平面 1 / 本像素原始深度，NDC 转换在 screenToView 内部）
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight) - vJitter;

    vec3 color;
    if (depth >= 1.0) {
        // 天空视线：z = 1 经 screenToView 落在远平面上（不归一化，getSkyColor 内部归一）；
        // getSkyColor 为 colortex7 sky-view LUT 双线性采样（composite12 上一帧生成，滞后一帧
        // 无视觉差异），composite_taa 的时间累积把 16 相位亚像素采样解析成抗锯齿
        //（大气地平线高频边界不再锯齿）；非活动半区（光源低于 SKY_LIGHT_MIN_HEIGHT、
        // 生成端整区写 0）由 getSkyColor 内部门控跳过 fetch，有效性取 vsh 探针
        //（vSkyLutValid，无效即首帧 / 缓冲重建回退轻量天空）
        color = getSkyColor(screenToView(vec3(uv, 1.0)),
                            vSunDirection, vMoonDirection, vHorizon, vSkyLutValid > 0.5);
    } else {
        // 几何光照：colortex4.rg 解包 albedo（sRGB，反 gamma），colortex5.rg 八面体观察空间法线、
        // .ba 原始 lmcoord 重映射；viewPos = 去抖 uv + 本像素原始深度
        vec4 gAlbedoSpec = texelFetch(colortex4, pixel, 0);
        vec4 gNormalLm = texelFetch(colortex5, pixel, 0);
        vec3 albedo = srgbToLinear(unpack2x16To4x8(gAlbedoSpec.rg).rgb);
        vec3 normalView = decodeOctahedral(gNormalLm.rg);
        vec2 lm = remapLightmap(gNormalLm.ba);
        vec3 viewPos = screenToView(vec3(uv, depth));
        color = shadeSurface(albedo, normalView, lm, viewPos, vDirectTransmittance);
    }
    outColor = vec4(color, 1.0);
}

#endif
