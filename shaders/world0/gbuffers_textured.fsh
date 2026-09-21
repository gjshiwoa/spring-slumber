#version 330 compatibility
#define STAGE_FRAGMENT
// 手动档（时机两可：OptiFine 位在 deferred 前须关混合整像素写 gbuffer；DRAWBUFFERS 与程序侧
// 手动档布局一致——程序文件已不带 DRAWBUFFERS、由入口提供）
#include "/program/gbuffers_translucent_simple.glsl"

/* DRAWBUFFERS:456 */
