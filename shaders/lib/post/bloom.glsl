// Bloom 工具库：tile 图集布局与链式下采样、textureNice 上采样合并入口
// 依赖先行 include：lib/common/globals/constants.glsl（BLOOM_*）、lib/common/globals/uniforms.glsl（colortex0 / colortex1、
// viewWidth / viewHeight）、lib/common/utils/filters.glsl（textureNice / downsample13Tap）
//
// 图集布局（缓冲归一化坐标，全尺寸 colortex1，不用 size.buffer——低版本 OptiFine 不支持）：
//   tile0 = 左上 1/4×1/4（屏幕 1/4 分辨率起步，c13 同款；砍掉 1/2 级省最大头开销），
//   tile1~4 在其右侧纵向堆叠（边长 1/8、1/16、1/32、1/64），图集仅占缓冲 ~10% 面积
//   tile 间隔 4 texel，吸收采样半径与奇数分辨率下的分数纹素边界，防串色
//   每个 tile 都覆盖整个场景（边长逐级减半），所有矩形计算不假设缓冲实际分辨率（textureSize 运行时推导）
#ifndef LIB_BLOOM_GLSL
#define LIB_BLOOM_GLSL

const int BLOOM_TILE_COUNT = 5; // 金字塔级数：1/4 ~ 1/64

// 返回 tile k 的矩形：xy = 原点、zw = 边长（缓冲归一化）
vec4 bloomTileRect(int k) {
    vec2 gap = 4.0 / vec2(textureSize(colortex1, 0));
    float size = exp2(-float(k + 2));
    if (k == 0) return vec4(0.0, 0.0, size, size);
    vec2 origin = vec2(0.25 + gap.x, 0.0);
    for (int i = 1; i < k; i++) origin.y += exp2(-float(i + 2)) + gap.y;
    return vec4(origin, size, size);
}

// 计算第 k 级 tile 的下采样结果（tileLocal = tile 内容归一化坐标，像素中心即源 2×2 区域中心）
// k = 0 直接从 colortex0 全屏取，k > 0 从上一级 tile 取（链式）
vec3 bloomDownsampleTile(int k, vec2 tileLocal) {
    if (k == 0) {
        vec2 srcTexel = 1.0 / vec2(viewWidth, viewHeight);
        vec4 clampRect = vec4(srcTexel * 0.5, 1.0 - srcTexel * 0.5);
        return downsample13Tap(colortex0, tileLocal, BLOOM_BLUR_STEP * srcTexel, clampRect);
    }
    vec4 srcRect = bloomTileRect(k - 1);
    vec2 bufTexel = 1.0 / vec2(textureSize(colortex1, 0));
    vec2 srcCenter = srcRect.xy + tileLocal * srcRect.zw;
    vec4 clampRect = vec4(srcRect.xy + bufTexel * 0.5, srcRect.xy + srcRect.zw - bufTexel * 0.5);
    return downsample13Tap(colortex1, srcCenter, BLOOM_BLUR_STEP * bufTexel, clampRect);
}

// 合并入口（composite_bloom_merge 调用）：5 个 tile 经 textureNice 放大加权平均，
// 返回与场景同量级的泛光颜色；乘 BLOOM_STRENGTH 与场景相加在 composite_bloom_merge 完成
// （tonemap 前线性域）；除以权重和 3.0（= Σ BLOOM_WEIGHTS）归一；
// 采样坐标钳制 tile 内缩 1 纹素（吸收 textureNice 的向内弯折），不越出 tile
vec3 getBloom(vec2 screenUv) {
    vec2 bufTexel = 1.0 / vec2(textureSize(colortex1, 0));
    vec3 bloom = vec3(0.0);
    for (int k = 0; k < BLOOM_TILE_COUNT; k++) {
        vec4 rect = bloomTileRect(k);
        vec2 uv = clamp(rect.xy + screenUv * rect.zw, rect.xy + bufTexel, rect.xy + rect.zw - bufTexel);
        bloom += textureNice(colortex1, uv) * BLOOM_WEIGHTS[k];
    }
    return bloom / 3.0;
}

#endif
