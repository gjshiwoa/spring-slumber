// TAA 解析 pass: composite_taa（world0/composite3 入口）
// 位于全部 gbuffers（含 deferred 之后的前向半透明）之后、bloom 链（composite4~8）之前：
// 读抖动后的线性 colortex0 与 depthtex0，重投影采 colortex3 历史，方差钳制 + 置信度混合后写回
// colortex0，并把混合色 + 本帧最近片元线性深度写进 colortex3 供下帧（DRAWBUFFERS:03 单程序独占
// ping-pong，不依赖 flip.*）；bloom 图集与自动曝光测光自此吃抗锯齿后的稳定图像
// 钳制域曝光归一化（春雷同思路）：本帧曝光要到上采样链末级（composite12）才写入，这里读
// colortex7 曝光槽位拿到的恰是上一帧的适应值——工作域乘它把暗景拉进 tonemap 压缩段、σ 远离
// epsilon 地板（低亮度钳制失效会拖影），vsh 取一次经 varying 传入，结果除回后存储（历史仍为未曝光线性值）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/utils/jitter.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/post/taa.glsl"

VARYING vec2 vTexCoord;
VARYING vec2 vJitter;   // 当前帧 jitter（uv 域），全屏恒定：四顶点写同值，插值精确
VARYING float vExposure; // 上一帧自适应曝光（colortex7 曝光槽位），钳制域归一化用，同上全屏恒定

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:03 */

layout(location = 0) out vec4 outColor;   // colortex0：解析后的场景颜色
layout(location = 1) out vec4 outHistory; // colortex3：rgb = 混合色，a = 本帧锚点线性深度

void main() {
    float historyDepth;
    vec3 color = resolveTAA(vTexCoord, ivec2(gl_FragCoord.xy), vJitter, vExposure, historyDepth);

    outColor = vec4(color, 1.0);
    outHistory = vec4(color, historyDepth);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
    vJitter = taaJitterUV();
    float exposure = readAdaptedExposure();
    vExposure = (exposure > 1e-4 && exposure < 1e4) ? exposure : 1.0; // 首帧 / 重载后槽位可能无效，回退中性 1.0（帧 0 本就弃历史）
}

#endif
