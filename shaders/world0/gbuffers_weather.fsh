#version 330 compatibility
#define STAGE_FRAGMENT
// FORWARD_HW_BLEND：weather 恒 deferred 后——引擎硬件混合（机制见 gbuffers_translucent 头注；
// 雨丝同 draw 内互相交叉正是手动合成竞态闪烁的重灾区）；单附件输出
#define FORWARD_HW_BLEND
#include "/program/gbuffers_translucent_simple.glsl"

/* DRAWBUFFERS:6 */
