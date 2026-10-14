// 边界雾 pass: composite_fog（composite2 槽，TAA 之前、bloom 链之前——编号约定「TAA 之前的效果
// 从 2 往前排」；雾边界与雾中几何由 composite_taa 时间累积平滑）。
// vsh = 通用全屏 vsh（本 program 无自定义 vsh 段，fsh 按需声明同名 in）；TAAU 时 quad 经
// FULLSCREEN_RENDER_REGION（world0/composite2 入口 vsh 定义）缩进渲染子区域、与 deferred_init
// 同款——读写均限于 [0,S]² 内就地，composite_taa 随后上采样恢复全屏。
// 单 pass 对 colortex6 就地雾化（同位置 texelFetch 读 + 写回——composite12 的 colortex7 透传 /
// composite_taa 读 colortex6 写 colortex6 同款已知取舍）：距离 / 方向取 **depthtex0（全部几何，
// 含水 / 手 / 粒子 / 实体）**去抖重建——水面随其表面深度、以最终合成色（水 × 已雾背景）单点被
// 雾化，前向程序无需逐路施加（首代接入形态 deferred_init 两分支 + 前向 after 路径已按反馈撤销，
// git 历史含完整形态）；天空像素（depth >= 1）取 z = 1 远平面视线、距离因子恒 1；去抖基底与
// deferred_init 同式同源「像素 uv − vJitter」（TAAU 再 /S）——vJitter 经通用全屏 vsh 的同名
// varying 传入，免 applyInverseJitter 内 taaJitterUV 的每像素 Halton 表动态索引与除法重算；
// viewPos 重建走 space.glsl 的 screenToViewCanonical 典则闭式（均 2026-09 性能优化，机制见 main 内注释）
// 雾色 / 因子式见 lib/atmosphere/fog.glsl；帧数据（日月世界方向 / 地平线 / LUT 有效性）直接取通用
// 全屏 vsh 的同名 varying。几何分支另施加**大气散射雾 / 空气透视**（lib/atmosphere/aerial.glsl 的
// applyAerialPerspective，AERIAL_PERSPECTIVE 宏门控、边界雾之前）：物理式 surface × T + S——中近距
// 物理空气感（方向性 / 色彩 / 曙暮光分层），与边界雾两段式分工（boundary 兜 far 端渲染边界融接）；
// 天空像素不施加（不变式③）。另接入**水下雾**（WATER_FOG 宏，lib/water/fog.glsl 的
// applyUnderwaterFog：isEyeInWater == 1 时按 depthtex0 表面距离的整屏吸收雾——与 gbuffers_water
// 的水面框架同源、雾色光照共用单真源）。BOUNDARY_FOG / AERIAL_PERSPECTIVE / WATER_FOG **三宏全关**时
// 整 pass 透传旁路（末地恒走旁路，仅在输出处钳制负 RGB）——
// colortex6 同位置 fetch 原样写回（不可 discard：读改写 pass 的输出经引擎 ping-pong 翻转进下一 pass，
// 丢弃 = 翻转目标保持帧头 clear 黑 → 黑屏，机制见 main 内注释）；单关其一 = 该段编译剔除、另一段照常

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/compat/voxy/scene.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/lighting/ambient.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/aerial.glsl"
#include "/lib/atmosphere/fog.glsl"
#include "/lib/atmosphere/clouds.glsl"
// 水下雾（2026-10 自 lib/lighting/water.glsl 按功能拆分——本 pass 只消费 fog.glsl 的
// applyUnderwaterFog，波场 / SSR / 主着色不进本链）
#include "/lib/water/fog.glsl"
#include "/program/fullscreen_vsh.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

#if defined(VOXY) && defined(SR_INSTALLED) && defined(SR_SHOULD_APPLY_SCALE) && SR_SHOULD_APPLY_SCALE == 1
/* RENDERTARGETS: 6,20,31 */
#else
/* DRAWBUFFERS:6 */
#endif

// 通用全屏 vsh 输出的帧数据——按需 in 声明（vJitter 与 deferred_init 同款消费：去抖基底
// 「像素 uv − vJitter」，TAAU 再 /S）；getSkyColor 入参族（fog.glsl 雾色采样）；vDirectIrradiance /
// vSkyAmbient 为水下雾的雾色光照（lib/water/fog.glsl 的 applyUnderwaterFog 消费）
in vec2 vJitter;
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vHorizon;
in vec3 vDirectIrradiance;
in vec3 vSkyAmbient;
flat in float vSkyLutValid; // 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）

layout(location = 0) out vec4 outColor; // colortex6：雾化后的场景颜色

#if defined(VOXY) && defined(SR_UPSCALE)
layout(location = 1) out vec4 outSrDepth;
layout(location = 2) out vec4 outSrMotion;
#endif

void main() {
#if defined(VOXY) && defined(SR_UPSCALE)
    // Final SR inputs are produced after LOD transparency and vanilla forward draws.
    // Keep opaque depth aligned with deferred terrain motion beneath LOD transparency.
    ivec2 srPixel = ivec2(gl_FragCoord.xy);
    float srDepth = texelFetch(depthtex1, srPixel, 0).r;
    vec2 srUv = applyInverseJitter(gl_FragCoord.xy / vec2(viewWidth, viewHeight), vJitter);
    vec3 srViewPos = screenToViewCanonical(srUv, srDepth);
    bool srLodSurface;
    bool srSurfaceValid = voxyScenePosition(gl_FragCoord.xy, vJitter, srDepth, false, srViewPos, srLodSurface);
    if (srSurfaceValid && srLodSurface)
        srDepth = min(voxyWindowDepth(srViewPos), 1.0 - 1.0 / 16777216.0);
    // SR 外部深度接口要求原版投影域；只导出到颜色附件，不回写 depthtex。
    outSrDepth = vec4(srDepth);
    outSrMotion = texelFetch(colortex31, srPixel, 0);
    if (srSurfaceValid && srLodSurface)
        outSrMotion = vec4(voxySceneMotionVector(srUv, srViewPos), 0.0, 1.0);
#endif
#if defined(END) || (!defined(BOUNDARY_FOG) && !defined(AERIAL_PERSPECTIVE) && !defined(WATER_FOG))
    // 两雾宏全关：整 pass 透传旁路。不可 discard——本 pass 读改写 colortex6（DRAWBUFFERS:6 + uniforms
    // 采样器声明），引擎 ping-pong 把输出翻到另一份缓冲，discard 时那份从未被写入、保持帧头
    // clear 黑，composite_taa 读到全黑 → 黑屏（2026-09 实测修复）；透传写回保持翻转语义、
    // colortex6 保留非负颜色与 alpha。雾体留在 #else：直排其后会参与编译、引用已编译剔除的施加函数
    outColor = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
#else
    // 深度 / 颜色采样 texelFetch 精确纹素（全屏 pass 逐像素与缓冲一一对应，与 deferred_init 同款
    // 纪律）；depthtex0 = 全部几何（含水 / 手 / 粒子——水随其表面深度被雾化的关键）
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex0, pixel, 0).r;
    bool skyPixel = depth >= 1.0;

    // 去抖全视场 uv（buffer uv → 无抖动全视场 uv，与 deferred_init 基底严格同式；公式单真源 =
    // noise.glsl 的 applyInverseJitter 参数版——jitter 经 vJitter varying 传入，免 taaJitterUV 的
    // 每像素 Halton 表动态索引与除法重算，全 quad 恒定值的插值舍入 ~1e-11 px）
    vec2 uv = applyInverseJitter(gl_FragCoord.xy / vec2(viewWidth, viewHeight), vJitter);

    // 天空像素 z = 1 落在远平面（不归一化，雾函数内部只取方向）；几何像素取本像素原始
    // 深度。重建走 screenToViewCanonical 典则透视闭式（与 screenToView 代数恒等、免每像素
    // mat4 + 3 div——本 pass 逐像素全屏重建的最廉价路径，shadow.glsl 步内场化同款公式）。
    // 近景整像素在两雾的早退链免世界换算与 LUT fetch（aerial：距离 < AERIAL_FOG_START·far 起始
    // 门 fade = 0；boundary：距离因子 0），本 pass 常态成本 = 2 fetch + 闭式重建（1 div）+ 1 length
    vec3 viewPos = screenToViewCanonical(uv, depth);
#ifdef VOXY
    voxyVisibleSurfacePosition(gl_FragCoord.xy, vJitter, depth, viewPos, skyPixel);
#endif
    vec3 color = texelFetch(colortex6, pixel, 0).rgb;
#ifdef WATER_FOG
    // 水下雾（lib/water/fog.glsl 的 applyUnderwaterFog，方案移植自春v2 waterFog / underWaterFog）：
    // 相机在水中的整屏吸收雾，按 depthtex0 表面距离结算——水面像素的水下观视（折射 / 反射 / Fresnel）
    // 已在 gbuffers_water 处理、此处只按「眼到该表面」的路径吸收（两路不重复计费）；aerial / boundary
    // 在水下各自早退（lib 内 isEyeInWater 判定），水下只余本段
    if (isEyeInWater == 1)
        applyUnderwaterFog(color, viewPos, skyPixel, vDirectIrradiance, vSkyAmbient);
#endif
#ifdef AERIAL_PERSPECTIVE
    // 空气透视先行（不变式③：天空像素不施加——渐近一致性只在几何侧成立）；与边界雾两段式
    // 叠加（0.7~0.9·far 带 double-dip 为风格化取舍，调参联动见 AGENTS.md）
    if (!skyPixel)
        applyAerialPerspective(color, viewPos, vSunDirection, vMoonDirection, vHorizon, vSkyLutValid > 0.5);
#endif
#ifdef BOUNDARY_FOG
    applyBoundaryFog(color, viewPos, skyPixel, vSunDirection, vMoonDirection, vHorizon, vSkyLutValid > 0.5);
#endif

    outColor = vec4(color, 1.0);
#endif
    // TAAU / SR (including DLSS) input: preserve HDR highlights and alpha, reject negative RGB.
    outColor.rgb = max(outColor.rgb, vec3(0.0));
}

#endif
