// 纯色几何类: gbuffers_basic
// 与 gbuffers_textured 的区别: 不采样纹理，只输出 gl_Color
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"

VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    outColor = vColor;
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vColor = gl_Color;
}

#endif
