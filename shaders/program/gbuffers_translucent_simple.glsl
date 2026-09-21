// 前向半透明（简单处理）: gbuffers_translucent_simple
// hand_water / weather / textured / textured_lit 入口复用（line / particles 无入口，沿回退链落到
// basic / textured_lit 进入本程序），按 pass 顺序标记自适应（lib/common/pipeline/pass_order_marker.glsl，
// vsh 判定经 flat varying 下传——引擎把本族放 deferred 前后都能正确出画）；「之后」路径分两档、
// 由入口宏 FORWARD_HW_BLEND 选择（hand_water / weather 恒 deferred 后、入口启用；textured 族
// 时机两可、入口不启用）：
//   deferred 之后 + FORWARD_HW_BLEND（hand_water / weather 入口）：光照图轻量着色
//     （forwardLightmapShade，春v2 textured_lit 同构、辐照度形式对齐 shadeSurface——无直射 /
//     阴影 / 法线〔阳光下略暗于受光地形，春v2 同取舍〕；夜视项不接——shadeSurface 亦无、避免
//     与地形观感分叉，接的话两侧成对加）后输出直通 (lit, alpha)、引擎硬件混合（ROP 按提交序
//     原子合成进 colortex6——手动「texelFetch 背景 + mix」的读改写在同一 draw 内重叠半透明片段
//     间是竞态、逐帧结果不同 = 重叠处纹理闪烁，雨丝交叉实测；跨 draw 亦天然正确、无「读正在写
//     的缓冲」取舍）；单附件 DRAWBUFFERS:6（下放入口）、colortex4/5 完全不写
//   deferred 之后 + 手动档（textured 族入口）：同式轻量着色后手动 alpha 合成——背景 fetch
//     gaux3（= colortex6 主颜色）+ mix 写回，跨 draw 链式叠加正确，同 draw 重叠竞态为本档残余
//     （粒子 / 闪电交叠偶发）；colortex4/5 本分支不写——gbuffer 读者（deferred_init 几何分支）
//     只读 depthtex1 < 1 像素、该区域每帧被不透明 gbuffers 先行整写，遗留内容活不到读者面前
//   deferred 之前（textured 族的 OptiFine 默认位，粒子 / 闪电由此重新可见）：不计算光照，几何
//     打包写 colortex4/5（与 gbuffers_opaque 同格式：albedo+标记 / 导数法线 / lmcoord，标记置空——
//     半透明混合类纪律），deferred_init 解包延迟光照；colortex6 随写 0（deferred_init 全屏覆盖）
//     ——本位要求引擎混合关（打包整像素写入、shaders.properties 含回退链各阶段名）；FORWARD_
//     HW_BLEND 档恒不达（hand_water / weather 恒 deferred 后）、不写 gbuffer。lightning 原加色
//     混合亦归 alpha 合成（其 deferred 前本被覆盖不可见，可见时机修复后按需加自发光分支——春v2
//     LIGHTNING 宏同位职责）
// DRAWBUFFERS 下放入口文件（多入口输出不同，同 composite_bloom_upsample 惯例）：
// FORWARD_HW_BLEND 档 6（hand_water / weather）、手动档 456（textured / textured_lit）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/pipeline/pass_order_marker.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/material.glsl"
#include "/lib/lighting/ambient.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos; // 「之前」路径导数法线的位置基底（同 gbuffers_opaque）
VARYING vec3 vSkyAmbient; // 天空环境辐照度基色（vsh 探针一次取好；同通用全屏 vsh 的同名 varying 语义）
flat VARYING float vAfterDeferred; // pass 顺序判定 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

// DRAWBUFFERS 在入口文件：FORWARD_HW_BLEND 档 6（单附件、引擎混合）/ 手动档 456（多入口输出不同）

#ifdef FORWARD_HW_BLEND
layout(location = 0) out vec4 outColor; // colortex6：直通 (lit, alpha)、引擎 ROP 原子合成
#else
layout(location = 0) out vec4 outMaterial; // colortex4：「之前」= 打包几何 /「之后」= 不写（无读者）
layout(location = 1) out vec4 outDetail;   // colortex5：同上
layout(location = 2) out vec4 outColor;    // colortex6：「之后」= 手动合成光照 /「之前」= 随写 0（deferred 覆盖）
#endif

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;

    // 导数先于 discard（「之前」路径 TBN 需要；纪律同 gbuffers_opaque——discard 后 quad 内幸存
    // 像素导数未定义，先集中求好；TBN 构造与 normals 采样推迟到分支内）
    vec3 dp1 = dFdx(vViewPos);
    vec3 dp2 = dFdy(vViewPos);
    vec2 duv1 = dFdx(vTexCoord);
    vec2 duv2 = dFdy(vTexCoord);

    // TAAU 子区域外片元剔除（机制见 noise.glsl 的 outsideRenderRegion；半透明混合本无 Early-Z 顾虑）
    if (outsideRenderRegion()) discard;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    if (vAfterDeferred > 0.5) {
        // deferred 之后：光照图轻量着色（forwardLightmapShade）后按档合成（两档语义见头注）
        vec2 lm = remapLightmap(vLmcoord);
        vec3 lit = forwardLightmapShade(srgbToLinear(color.rgb), lm, vSkyAmbient);
#ifdef FORWARD_HW_BLEND
        outColor = vec4(lit, color.a); // 直通 alpha、引擎 ROP 原子合成（draw 内重叠定序正确）
#else
        // 手动档：背景取 gaux3（= colortex6 主颜色，deferred_init 写入；主颜色放 colortex6 正是为
        // gbuffers 阶段可采样——colortex0~3 采样单元被游戏纹理占用）；合成结果写回 colortex6、
        // 跨 draw 链式叠加背景正确；colortex4/5 本分支不写（无读者，见头注）
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        outColor = vec4(mix(texelFetch(gaux3, pixel, 0).rgb, lit, color.a), 1.0);
#endif
    } else {
        // deferred 之前：几何进 colortex4/5（deferred_init 延迟光照）；alpha 的 cutout 职责已尽、
        // a 通道置空标记（半透明混合类纪律，实体入口同款）；colortex6 随写 0、deferred_init 覆盖。
        // FORWARD_HW_BLEND 档恒不达（hand_water / weather 恒 deferred 后）、不写 gbuffer
#ifndef FORWARD_HW_BLEND
        vec3 viewNormal = gbufferViewNormal(dp1, dp2, duv1, duv2, vTexCoord);
        color.a = MATERIAL_NONE;
        outMaterial = packGbufferMaterial(color, vTexCoord);
        outDetail = packGbufferDetail(viewNormal, vLmcoord);
#endif
        outColor = vec4(0.0);
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    // 天空环境基色探针（lib/lighting/ambient.glsl，与通用全屏 vsh 同一实现）：本程序不采样
    // 天空 LUT、有效性出参不消费（局部变量即丢弃）
    float lutValid;
    vSkyAmbient = skyAmbientColor(lutValid);
    // pass 顺序判定一次（vsh 顶点级，fsh 经 flat varying 消费）
    vAfterDeferred = isAfterDeferred() ? 1.0 : 0.0;
}

#endif
