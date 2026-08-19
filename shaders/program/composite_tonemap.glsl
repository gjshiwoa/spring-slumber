// Tonemap pass: composite_tonemap（world0/composite14 入口）
// 位于全部 gbuffers 与 bloom 合成（composite_bloom_merge）之后、final 之前；
// 读线性 colortex0（已含 bloom），乘 colortex7 右上角的自适应曝光（lib/post/exposure.glsl，
// composite_bloom_merge 测光并写入）后做 AgX tonemap（lib/post/tonemap.glsl，春雷同款）写回 colortex0
// AgX 末段 pow 2.2 即「回到线性」（display-referred linear，春雷 09_final 前半同款），
// 缓冲保持线性，gamma 矫正（linearToSrgb）留给 final
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/exposure.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    vec3 color = texture(colortex0, vTexCoord).rgb * readAdaptedExposure();
    outColor = vec4(agx(color), 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
