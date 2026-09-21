// 天空纹理: gbuffers_sky_tex（备选，当前未链接，skytextured 入口现指向 gbuffers_empty）
// 太阳 / 月亮贴图，骨架阶段原色直通（不做发光补偿）；输出主颜色 colortex6（同 gbuffers_sky——
// 链接前须先给 deferred_init 天空分支让路，否则被全屏覆盖）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:6 */

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(tex, vTexCoord) * vColor;
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
}

#endif
