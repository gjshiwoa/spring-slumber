#version 330 compatibility
#define STAGE_FRAGMENT
// FORWARD_HW_BLEND：water 恒 deferred 后——引擎硬件混合（ROP 原子合成，draw 内重叠半透明
// 片段定序正确；手动 texelFetch + mix 读改写在该场景是竞态、重叠处闪纹理）；单附件输出
#define FORWARD_HW_BLEND
#include "/program/gbuffers_translucent.glsl"

/* DRAWBUFFERS:6 */
