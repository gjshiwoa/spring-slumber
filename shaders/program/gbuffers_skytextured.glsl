// 天空纹理: gbuffers_skytextured
// 太阳 / 月亮贴图，骨架阶段原色直通（不做发光补偿）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/constants.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

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
