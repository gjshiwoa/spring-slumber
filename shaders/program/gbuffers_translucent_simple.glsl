// 前向半透明（简单处理）: gbuffers_translucent_simple
// 保留引擎混合的前向半透明（hand_water / weather / textured / textured_lit 入口复用；
// line / particles 无入口，沿回退链落到 basic / textured_lit 进入本程序或 gbuffers_color），
// 按 alpha 混合写线性 colortex0；与 gbuffers_translucent 的完整处理相对，只做轻量处理
// 当前为框架阶段：直接输出 tex 颜色并转线性（srgbToLinear），无光照
// 简单处理扩展点：光照图轻量着色 / 雾等（不接入 shadeSurface 全量光照）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/noise.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    // TAAU 子区域外片元剔除（机制见 noise.glsl 的 outsideRenderRegion；半透明混合本无 Early-Z 顾虑）
    if (outsideRenderRegion()) discard;

    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    color.rgb = srgbToLinear(color.rgb); // 与 deferred_init 初始化的线性 colortex0 混合
    outColor = color;
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
}

#endif
