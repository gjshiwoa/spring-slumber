#version 330 compatibility
#define STAGE_VERTEX
#define OPAQUE_GSH // 本入口挂几何着色器（gbuffers_terrain.gsh 植被判定）：program 内 vsh 输出侧据此挂 vGsh 前缀衔接 gsh
#include "/program/gbuffers_opaque.glsl"
