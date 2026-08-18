// 前向完整类: gbuffers_water（半透明完整处理）
// deferred 之后绘制的前向半透明（water 入口），按引擎 alpha 混合写 colortex0
// 当前为框架阶段：直接输出 tex 颜色并转线性（sRGB→线性，pow 2.2），无光照 / 雾 / 水面效果
// 完整处理扩展点：共享 lib/lighting.glsl 的 shadeSurface、雾 / 水下效果、水面扰动等
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
