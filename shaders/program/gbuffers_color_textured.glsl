// 手动合成（带纹理）: gbuffers_color_textured（备选，当前未链接）
// deferred 之前绘制的混合几何（粒子等，textured / textured_lit / particles 入口复用）
// 打包通道不能直接吃引擎 alpha 混合（字节串扰），按春雷方式：关闭本程序混合，
// 着色器内采样已有内容手动合成后重新打包写入 colortex4.rg（不写 colortex5，
// 背景的法线 / lm 数据保持完好）；随后随背景像素一起经过 deferred_init
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:4 */

layout(location = 0) out vec4 outMaterial; // colortex4

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    // 与背景已写入的打包颜色手动合成（引擎混合已由 shaders.properties 关闭）；
    // 合成只作用于 rgb——物品标记不参与混合，a 通道整像素置空
    vec4 previous = texelFetch(colortex4, ivec2(gl_FragCoord.xy), 0);
    vec3 previousColor = unpack2x16To4x8(previous.rg).rgb;
    color.rgb = mix(previousColor, color.rgb, color.a);

    outMaterial = vec4(pack4x8To2x16(vec4(color.rgb, MATERIAL_NONE)), previous.ba);
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
