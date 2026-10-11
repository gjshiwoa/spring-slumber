// TAA 解析 pass: composite_taa（composite3 入口；vsh = 通用全屏 vsh，本 program 无自定义 vsh 段，
// fsh 按需声明同名 in）。位于全部 gbuffers（含 deferred 后的前向半透明）之后、bloom 链之前：
// 读抖动后的线性 colortex6 与 depthtex0，重投影采 colortex3 历史、九样本重建 / 软方差修正 + 独立解遮挡混合后写回
// colortex6（TAAU 时为上采样后的全屏目标分辨率，机制见 lib/post/taa.glsl），混合色 + 本帧锚点
// 线性深度写 colortex3 供下帧（DRAWBUFFERS:63 单程序独占 ping-pong，不依赖 flip.*）；bloom 图集
// 与自动曝光测光自此吃抗锯齿后的稳定图像。TAAU 下 quad 保持全屏——本 pass 是上采样器，与缩进
// 子区域的 deferred_init（FULLSCREEN_RENDER_REGION）分工
// SR 超分接管（SR_UPSCALE）：SR 算法族自带时域累积与上采样，在 composite3 前触发点（superresolution.v3.json）
// 通过 autotex6 / autotex31 选择当前有效的颜色 / MV（SR JSON 的 colortexN 固定指 main，
// 不等于 GLSL sampler 的自动绑定），配合 noTranslucentDepthtex、写回 autotex6 的全屏 upscaled 色彩——本
// pass 整体透传旁路（colortex6 同位置 fetch 写回、维持 ping-pong 翻转语义；不可 discard，
// composite_fog 旁路同款纪律），colortex3 历史停写（DRAWBUFFERS:6、无消费者）；jitter 与渲染比例
// 两源均由 SR 供给（constants.glsl / noise.glsl 的接管点），bloom 链及之后零适配（colortex6 已是
// 全屏稳定图像）
// 曝光归一化：本帧曝光要到 composite12 才写入，这里读 colortex7 槽位拿到的是上一帧适应值——
// 工作域乘它把暗景拉进 tonemap 压缩段、σ 远离 epsilon 地板（见 taa.glsl 头注释），vsh 取一次
// 经 varying 传入，结果除回后存储（历史仍为未曝光线性值）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/lighting/ambient.glsl"
#include "/program/fullscreen_vsh.glsl"
#include "/lib/post/taa.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

// 通用全屏 vsh 输出的帧数据——按需 in 声明
in vec2 vTexCoord;   // 全屏 uv
in vec2 vJitter;     // 当前帧 jitter（uv 域），resolveTAA 的解析参数
in float vExposure;  // 上一帧自适应曝光（composite12 尚未执行，槽位为上帧适应值），钳制域归一化用

// 引擎输出指令必须直接检查 SR 注入宏，不能依赖派生 SR_* 宏：OptiFine 1.12 的
// MacroState 连失活分支中的 #define 也登记，会误认 SR 已启用；GLSL 预处理器却
// 正确跳过该定义。否则 DRAWBUFFERS 被漏扫（旧引擎不识别 RENDERTARGETS）。
#if defined(SR_INSTALLED) && defined(SR_SHOULD_APPLY_SCALE) && SR_SHOULD_APPLY_SCALE == 1
/* DRAWBUFFERS:6 */
#else
/* DRAWBUFFERS:63 */
#endif

layout(location = 0) out vec4 outColor;   // colortex6：解析后的场景颜色（SR 接管 = SR 写回的 upscaled 色彩透传）
#ifndef SR_UPSCALE
layout(location = 1) out vec4 outHistory; // colortex3：rgb = 混合色，a = 本帧锚点线性深度
#endif

void main() {
#ifdef SR_UPSCALE
    // SR 接管：透传 SR 已写回的全屏 upscaled 色彩（不可 discard——读改写 pass 的 ping-pong 翻转
    // 语义，composite_fog 旁路同款纪律）；vJitter / vExposure / vTexCoord 未消费、链接器剔除
    outColor = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0);
#else
    float historyDepth;
    float debugValue;
    vec3 color = resolveTAA(vTexCoord, ivec2(gl_FragCoord.xy), vJitter, vExposure, historyDepth, debugValue);

#if TAA_DEBUG_VIEW > 0
    // RGB 不变：bloom / 自动曝光仍读正常场景，诊断不反馈到下一帧。
    outColor = vec4(color, debugValue);
#else
    outColor = vec4(color, 1.0);
#endif
    outHistory = vec4(color, historyDepth);
#endif
}

#endif
