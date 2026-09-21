#version 330 compatibility
#define STAGE_FRAGMENT
// FORWARD_HW_BLEND：hand_water 恒 deferred 后——引擎硬件混合（机制见 gbuffers_translucent 头注）；
// 单附件输出
#define FORWARD_HW_BLEND
#include "/program/gbuffers_translucent_simple.glsl"

/* DRAWBUFFERS:6 */
