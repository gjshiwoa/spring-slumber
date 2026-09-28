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
// 全屏 vsh 的同名 varying。BOUNDARY_FOG 宏关闭时整 pass 透传旁路——colortex6 同位置 fetch 原样
// 写回（不可 discard：读改写 pass 的输出经引擎 ping-pong 翻转进下一 pass，丢弃 = 翻转目标保持
// 帧头 clear 黑 → 黑屏，机制见 main 内注释）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/lighting/ambient.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/fog.glsl"
#include "/program/fullscreen_vsh.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:6 */

// 通用全屏 vsh 输出的帧数据——按需 in 声明（vJitter 与 deferred_init 同款消费：去抖基底
// 「像素 uv − vJitter」，TAAU 再 /S）；getSkyColor 入参族（fog.glsl 雾色采样）
in vec2 vJitter;
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vHorizon;
flat in float vSkyLutValid; // 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）

layout(location = 0) out vec4 outColor; // colortex6：雾化后的场景颜色

void main() {
#ifndef BOUNDARY_FOG
    // 宏关闭：整 pass 透传旁路。不可 discard——本 pass 读改写 colortex6（DRAWBUFFERS:6 + uniforms
    // 采样器声明），引擎 ping-pong 把输出翻到另一份缓冲，discard 时那份从未被写入、保持帧头
    // clear 黑，composite_taa 读到全黑 → 黑屏（2026-09 实测修复）；透传写回保持翻转语义、
    // colortex6 逐位直达。雾体留在 #else：直排其后会参与编译、引用已编译剔除的 applyBoundaryFog
    outColor = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
#else
    // 深度 / 颜色采样 texelFetch 精确纹素（全屏 pass 逐像素与缓冲一一对应，与 deferred_init 同款
    // 纪律）；depthtex0 = 全部几何（含水 / 手 / 粒子——水随其表面深度被雾化的关键）
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    float depth = texelFetch(depthtex0, pixel, 0).r;
    bool skyPixel = depth >= 1.0;

    // 去抖全视场 uv（buffer uv → 无抖动全视场 uv，与 deferred_init 基底严格同式；jitter 经
    // vJitter varying 传入——vsh 侧同一 taaJitterUV 实现，全 quad 恒定值的插值舍入 ~1e-11 px）
#ifdef TAAU
    vec2 uv = (gl_FragCoord.xy / vec2(viewWidth, viewHeight) - vJitter) / RENDER_SCALE;
#else
    vec2 uv = gl_FragCoord.xy / vec2(viewWidth, viewHeight) - vJitter;
#endif

    // 天空像素 z = 1 落在远平面（不归一化，applyBoundaryFog 内部只取方向）；几何像素取本像素原始
    // 深度。重建走 screenToViewCanonical 典则透视闭式（与 screenToView 代数恒等、免每像素
    // mat4 + 3 div——本 pass 逐像素全屏重建的最廉价路径，shadow.glsl 步内场化同款公式）。
    // 近景整像素在 applyBoundaryFog 早退（免世界换算与 LUT fetch），本 pass 常态成本 =
    // 2 fetch + 闭式重建（1 div）+ 1 length
    vec3 viewPos = screenToViewCanonical(uv, depth);
    vec3 color = texelFetch(colortex6, pixel, 0).rgb;
    applyBoundaryFog(color, viewPos, skyPixel, vSunDirection, vMoonDirection, vHorizon, vSkyLutValid > 0.5);

    outColor = vec4(color, 1.0);
#endif
}

#endif
