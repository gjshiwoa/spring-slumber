// 天空背景: gbuffers_sky（备选，当前未链接，skybasic 入口现指向 gbuffers_empty）
// 骨架阶段直通原版天空色（顶点色）；lib/atmosphere/sky.glsl 程序化天空已备好，暂不接入
//（输出主颜色 colortex6——链接前须先给 deferred_init 天空分支让路，否则被全屏覆盖）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"

VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:6 */

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
