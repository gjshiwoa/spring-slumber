#version 330 compatibility
#define STAGE_VERTEX
// TAAU：本 pass quad 缩进与 gbuffers 相同的左下 [0,S]² 渲染子区域（读写均限于子区域内就地进行，
// composite_taa 随后上采样恢复全屏）；宏须在 fullscreen_vsh 展开前定义（deferred1 入口同款）
#define FULLSCREEN_RENDER_REGION
#include "/program/composite_fog.glsl"
