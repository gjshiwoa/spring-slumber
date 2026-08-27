// TAA 解析 pass: composite_taa（world0/composite3 入口）
// vsh = 通用全屏 vsh（program/fullscreen_vsh.glsl——vTexCoord / vJitter / vExposure
// 等帧数据 varying 的来源，本 program 无自定义 vsh 段）；fsh 按需声明同名 in
// 位于全部 gbuffers（含 deferred 之后的前向半透明）之后、bloom 链（composite4~8）之前：
// 读抖动后的线性 colortex0（几何 vsh 抖动 + 天空 deferred_init 亚像素求值）与 depthtex0，
// 重投影采 colortex3 历史（天空锚点走无穷远方向仅旋转链），方差钳制 + 置信度混合后写回
// colortex0，并把混合色 + 本帧最近片元线性深度（天空像素为哨兵）写进 colortex3 供下帧
//（DRAWBUFFERS:03 单程序独占 ping-pong，不依赖 flip.*）；bloom 图集与自动曝光测光自此吃抗锯齿后的稳定图像
// 钳制域曝光归一化（春雷同思路）：本帧曝光要到上采样链末级（composite12）才写入，这里读
// colortex7 曝光槽位拿到的恰是上一帧的适应值——工作域乘它把暗景拉进 tonemap 压缩段、σ 远离
// epsilon 地板（低亮度钳制失效会拖影），vsh 取一次经 varying 传入，结果除回后存储（历史仍为未曝光线性值）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/post/exposure.glsl"
#include "/program/fullscreen_vsh.glsl"
#include "/lib/post/taa.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:03 */

// 通用全屏 vsh 输出的帧数据——按需 in 声明
in vec2 vTexCoord;   // 全屏 uv
in vec2 vJitter;     // 当前帧 jitter（uv 域），resolveTAA 的解析参数
in float vExposure;  // 上一帧自适应曝光（composite12 尚未执行，槽位为上帧适应值），钳制域归一化用

layout(location = 0) out vec4 outColor;   // colortex0：解析后的场景颜色
layout(location = 1) out vec4 outHistory; // colortex3：rgb = 混合色，a = 本帧锚点线性深度

void main() {
    float historyDepth;
    vec3 color = resolveTAA(vTexCoord, ivec2(gl_FragCoord.xy), vJitter, vExposure, historyDepth);

    outColor = vec4(color, 1.0);
    outHistory = vec4(color, historyDepth);
}

#endif
