// 初始化 pass: deferred_init（deferred 阶段）
// 位于不透明 gbuffers 之后、半透明之前；初始化场景颜色 colortex0：
// 解包 colortex4 的 albedo 后反 gamma（sRGB→线性，见 utils/color.glsl srgbToLinear）写入，
// colortex0 自此全程线性：前向半透明按线性混合，final 在线性域合成 bloom 并 tonemap，
// 其末段的 linearToSrgb 是唯一离开线性空间的位置
// 光照接入点：读 colortex4（albedo + 高光）、colortex5（观察空间法线 + 原始 lmcoord，
// 重映射见 pipeline/gbuffer_data.glsl remapLightmap）、depthtex0（天空区分 / 位置重建）计算后写回 colortex0
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    vec3 color = srgbToLinear(unpack2x16To4x8(texture(colortex4, vTexCoord).rg).rgb);
    outColor = vec4(color, 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
