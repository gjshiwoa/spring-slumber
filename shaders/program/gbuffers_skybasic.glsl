// 天空背景: gbuffers_skybasic
// 骨架阶段直通原版天空色（顶点色）；lib/sky.glsl 程序化天空已备好，暂不接入
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/constants.glsl"
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
