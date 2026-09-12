// 初始化 pass: deferred_init（deferred 阶段；vsh = 通用全屏 vsh，本 program 无自定义 vsh 段，
// fsh 按需声明同名 in）。位于不透明 gbuffers 之后、半透明之前，初始化场景颜色 colortex0：
// 位置重建统一去抖基底——`像素 uv − vJitter`（TAAU 再 /S）一次算出，天空视线（z = 1 远平面）与
// 几何 viewPos（z = depthtex1 原始深度）共用同一组 xy（几何 vsh 抖动 +J 后本像素含「位置 −J」处
// 场景，去抖重建得到真实位置）；几何信息采样全 texelFetch(gl_FragCoord) 精确纹素、无 vTexCoord。
// 天空与深度缓冲几何在地平线边界像素内衔接一致、阴影贴图采样位置逐帧对齐，composite_taa 时间
// 累积平滑 LUT 双线性 facets 与地平线边界
// 天空像素（depthtex1 >= 1——纯不透明深度，depthtex0 此刻可能已混入粒子深度）采样 colortex7
// sky-view LUT，随后叠加 2D 平面云（lib/atmosphere/clouds.glsl：LUT 是纯方向函数、云有平移视差
// 故不进 LUT；预乘合成 cloud.rgb + 天空 × cloud.a）；天空在本 pass 进 colortex0 是时序关键——
// 之后半透明引擎混合才有正确天空背景（含云），画在 composite（半透明之后）则水面叠天空处混到黑底
// colortex0 自此全程线性（final 的 linearToSrgb 是唯一离开线性空间的位置）
// 几何像素：解包 colortex4/5（albedo / 八面体法线 / lmcoord 重映射）+ 去抖 uv 重建 viewPos 后经
// shadeSurface 着色（直接光 = 阴影可见性 × 直射透射率 × 辐照度 × wrap 余弦 + 环境 / 方块光，
// 见 lib/lighting/lighting.glsl；albedo a 通道植被标记经 materialSSSStrength 转为 SSS 强度）

#define FULLSCREEN_DIRECT_TRANSMITTANCE

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#ifdef CLOUDS_2D
#define FULLSCREEN_CLOUD_TRANSMITTANCE // 云高处透射率 varying（CLOUDS_2D 在 constants.glsl——宏门控须在其后；atmosphere.glsl 已于上方引入）
#endif
#include "/program/fullscreen_vsh.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/clouds.glsl"
#include "/lib/lighting/shadow.glsl"
#ifdef STAGE_FRAGMENT
// 通用全屏 vsh 输出的帧数据——按需 in 声明；须位于 lighting.glsl 之前（shadeSurface 直接引用
// 同名全局），getSkyColor 的方向 / 地平线 / LUT 有效性经参数传入
in vec2 vJitter;
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vLightDirection;
in vec3 vDirectIrradiance;
in vec3 vDirectTransmittance;
#ifdef CLOUDS_2D
in vec3 vCloudTransmittance;
#endif
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

    // 统一去抖 uv：gl_FragCoord 像素中心 uv − 当前帧 jitter（与几何抖动同相位），天空视线与几何
    // viewPos 共用的位置重建基底。TAAU：本 pass quad 已缩进左下 [0,S]² 子区域，gl_FragCoord/视口
    // ∈ [0,S]——除 S 归一回视场全域、jitter 随域同步 /S，一步合成 (像素 uv − vJitter) / S
#ifdef TAAU
    vec2 uv = (gl_FragCoord.xy / vec2(viewWidth, viewHeight) - vJitter) / RENDER_SCALE;
#else
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight) - vJitter;
#endif

    vec3 color;
    if (depth >= 1.0) {
        // 天空视线：z = 1 落在远平面（不归一化，getSkyColor / getPlanarClouds 内部归一）；LUT 为
        // composite12 上帧生成（滞后一帧无视觉差异），非活动半区由 getSkyColor 门控跳过、有效性取
        // vsh 探针（无效即首帧 / 缓冲重建，回退轻量天空）
        vec3 skyDirView = screenToView(vec3(uv, 1.0));
        color = getSkyColor(skyDirView, vSunDirection, vMoonDirection, vHorizon, vSkyLutValid > 0.5);
#ifdef CLOUDS_2D
        // 2D 平面云叠加（预乘合成）：地形像素不进本分支、遮挡天然正确；云不写深度，TAA 按天空
        // 路径处理（纯旋转链重投影），TAAU 档与天空同路径上采样
        vec4 cloud = getPlanarClouds(skyDirView, vLightDirection,
                                     vDirectIrradiance, vCloudTransmittance, vSkyAmbient);
        color = cloud.rgb + color * cloud.a;
#endif
    } else {
        // 几何光照：colortex4.rg 解包 albedo（sRGB 反 gamma；a 通道为标记位），colortex5.rg 八面体
        // 法线、.ba 原始 lmcoord 重映射；viewPos = 去抖 uv + 本像素原始深度
        vec4 gAlbedoSpec = texelFetch(colortex4, pixel, 0);
        vec4 gNormalLm = texelFetch(colortex5, pixel, 0);
        vec4 gAlbedo = unpack2x16To4x8(gAlbedoSpec.rg);
        vec3 albedo = srgbToLinear(gAlbedo.rgb);
        float sssStrength = materialSSSStrength(gAlbedo.a);
        vec3 normalView = decodeOctahedral(gNormalLm.rg);
        vec2 lm = remapLightmap(gNormalLm.ba);
        vec3 viewPos = screenToView(vec3(uv, depth));
        color = shadeSurface(albedo, normalView, lm, viewPos, vDirectTransmittance, sssStrength);

        // ---- 调试：物品标记可视化（红 = 植被（gsh 程序化判定）、绿 = 显式排除（block.properties →
        // MATERIAL_SOLID，如草方块）、原色 = 未标记；块注释停用，恢复时去掉 /* 与 */ 两行）----
        /*
        if (sssStrength > 0.0) {
            color = vec3(1.0, 0.0, 0.0);
        } else if (abs(gAlbedo.a - MATERIAL_SOLID) < 0.5 / 255.0) {
            color = vec3(0.0, 1.0, 0.0);
        }
        */
    }
    outColor = vec4(color, 1.0);
}

#endif
