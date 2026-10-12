// 材质贴图采样：以输出分辨率的 UV 足迹选择 mip，而非低分辨率子区域的足迹。
// 依赖先行 include：constants.glsl（TAAU / SR_UPSCALE / EFFECTIVE_RENDER_SCALE）。
// 仅用于经过 applyTAAJitter 子区域缩放的几何材质（tex / normals / specular）；
// shadow、未缩放的天空贴图、屏幕缓冲与噪声不得接入。
#ifndef LIB_MATERIAL_TEXTURE_GLSL
#define LIB_MATERIAL_TEXTURE_GLSL

#ifdef STAGE_FRAGMENT
// 调用方必须在 discard / 非一致分支之前求好 UV 导数；显式梯度允许实际 fetch
// 留在剔除之后。不要缩放传给 calculateTBN 的原始导数（那是几何基底，不是 mip 足迹）。
vec4 sampleMaterialTexture(sampler2D tex, vec2 texCoord, vec2 duv1, vec2 duv2) {
#if defined(TAAU) || defined(SR_UPSCALE)
    // 低分辨率导数约为原生的 1/S，乘 S 抵消：等效 mip bias = log2(S)。
    // SR 生效时 EFFECTIVE_RENDER_SCALE 已是 SR_RENDER_SCALE_FACTOR（constants.glsl 派生）。
    duv1 *= EFFECTIVE_RENDER_SCALE;
    duv2 *= EFFECTIVE_RENDER_SCALE;
#endif
    return textureGrad(tex, texCoord, duv1, duv2);
}
#endif

#endif
