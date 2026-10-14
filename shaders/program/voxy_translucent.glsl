#define VOXY_TRANSLUCENT_PATCH
#ifndef VOXY
#define VOXY
#endif
#include "/lib/common/globals/constants.glsl"
#include "/lib/common/utils/packing.glsl"
layout(location = 0) out vec4 outTransColor;
layout(location = 1) out vec4 outTransDetail;
#include "/lib/compat/voxy/material.glsl"
