// 实体类: gbuffers_entities
// 与 gbuffers_terrain 的区别: 叠加 entityColor（受伤红闪等实体着色）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < 0.1) discard; // cutout 透贴
    color.rgb = mix(color.rgb, entityColor.rgb, entityColor.a);
    outColor = color;
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
