// 手动合成（纯色）: gbuffers_color
// 非光照纯色几何（选框等，basic 入口复用）在 deferred 之前绘制，
// 与 gbuffers_color_textured 同理：关闭引擎混合，着色器内手动合成打包进 colortex4.rg
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/utils/jitter.glsl"

VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:4 */

layout(location = 0) out vec4 outMaterial; // colortex4

void main() {
    // 与背景已写入的打包颜色手动合成（引擎混合已由 shaders.properties 关闭）
    vec4 previous = texelFetch(colortex4, ivec2(gl_FragCoord.xy), 0);
    vec3 previousColor = unpack2x16To4x8(previous.rg).rgb;
    vec3 color = mix(previousColor, vColor.rgb, vColor.a);

    outMaterial = vec4(pack4x8To2x16(vec4(color, 1.0)), previous.ba);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vColor = gl_Color;
}

#endif
