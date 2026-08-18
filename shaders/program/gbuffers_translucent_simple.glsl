// 前向简单类: gbuffers_translucent_simple（半透明简单处理）
// 保留引擎混合的前向半透明（hand_water / weather / textured / textured_lit 入口复用；
// line / particles 无入口，沿回退链落到 basic / textured_lit 进入本程序或 gbuffers_color），
// 按 alpha 混合写 colortex0；与 gbuffers_water 的完整处理相对，只做轻量处理
// 当前为框架阶段：直接输出 tex 颜色并转线性（sRGB→线性，pow 2.2），无光照
// 简单处理扩展点：光照图轻量着色 / 雾等（不接入 shadeSurface 全量光照）
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
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    color.rgb = pow(color.rgb, vec3(2.2)); // sRGB → 线性
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
