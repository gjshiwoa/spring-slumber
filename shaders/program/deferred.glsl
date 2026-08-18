// 延迟阶段: deferred
// 位于不透明 gbuffers 之后、半透明之前；骨架阶段解包 colortex4 的 albedo 直通写 colortex0
// 光照接入点：读 colortex4（albedo + 高光）、colortex5（观察空间法线 + 原始 lmcoord，
// 重映射见 common.glsl remapLightmap）、depthtex0（天空区分 / 位置重建）计算后写回 colortex0
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/constants.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/packing.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    vec3 color = unpack2x16To4x8(texture(colortex4, vTexCoord).rg).rgb;
    outColor = vec4(color, 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
