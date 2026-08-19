// 前向半透明（完整处理）: gbuffers_translucent
// deferred 之后绘制的前向半透明（water 入口），按引擎 alpha 混合写线性 colortex0
// 当前为框架阶段：直接输出 tex 颜色并转线性（srgbToLinear），无光照 / 雾 / 水面效果
// 完整处理扩展点：共享 lib/lighting/lighting.glsl 的 shadeSurface、雾 / 水下效果、水面扰动等
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    color.rgb = srgbToLinear(color.rgb); // 与 deferred_init 初始化的线性 colortex0 混合
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
