// Bloom 工具库：tile 图集布局、链式下采样、渐进上采样回卷与合并入口
// 依赖先行 include：lib/common/globals/constants.glsl（BLOOM_*）、lib/common/globals/uniforms.glsl（colortex0 / colortex1、
// viewWidth / viewHeight）、lib/common/utils/filters.glsl（tentFilter4 / downsample13Tap）
//
// 图集布局（缓冲归一化坐标，全尺寸 colortex1，不用 size.buffer——低版本 OptiFine 不支持）：
//   tile0 = 左上 1/4×1/4（屏幕 1/4 分辨率起步，c13 同款；砍掉 1/2 级省最大头开销），
//   tile1~4 在其右侧纵向堆叠（边长 1/8、1/16、1/32、1/64），图集仅占缓冲 ~10% 面积
//   tile 间隔 4 texel，吸收采样半径与奇数分辨率下的分数纹素边界，防串色
//   每个 tile 都覆盖整个场景（边长逐级减半），所有矩形计算不假设缓冲实际分辨率（textureSize 运行时推导）
//
// 双链金字塔（COD AW 式，下采样 composite4~8 + 上采样回卷 composite9~12）：
//   下采样：tile k = 13-tap 高斯取自上一级（tile0 取自 colortex0），各 tile 存原始金字塔
//   上采样：tile k = 本级原始内容 × 级权重 + 上一 pass 已合并 tile k+1 的 tent 放大 2 倍相加，
//           粗级模糊经逐级 tent 累积成连续衰减——单次大倍率双线性放大的菱形网格、
//           离散半径直接叠加的环状过渡（网格感 / 空隙感）在此结构下不再产生
#ifndef LIB_BLOOM_GLSL
#define LIB_BLOOM_GLSL

const int BLOOM_TILE_COUNT = 5; // 金字塔级数：1/4 ~ 1/64

// 返回 tile k 的矩形：xy = 原点、zw = 边长（缓冲归一化）
vec4 bloomTileRect(int k) {
    vec2 gap = 4.0 / vec2(textureSize(colortex1, 0));
    float size = exp2(-float(k + 2));
    if (k == 0) return vec4(0.0, 0.0, size, size);

    // Σ(i=1..k-1) 2^-(i+2) = 0.25 × (1 - 2^-(k-1))，避免每像素小循环
    float level = float(k - 1);
    vec2 origin = vec2(
        0.25 + gap.x,
        0.25 * (1.0 - exp2(-level)) + level * gap.y
    );
    return vec4(origin, size, size);
}
// 图集包围盒右上角（缓冲归一化）：composite_bloom_upsample 的 vsh 光栅压缩与
// composite12 的 fsh 包围盒判定（colortex7 透传 / 写 0 分支）共用
vec2 bloomTileRectMax() {
    vec2 rectMax = vec2(0.0);
    for (int k = 0; k < BLOOM_TILE_COUNT; k++) {
        vec4 rect = bloomTileRect(k);
        rectMax = max(rectMax, rect.xy + rect.zw);
    }
    return rectMax;
}

// colortex7 需要跨帧保值的完整预留区域：天空盒 + sky-view LUT + 曝光 gutter。
// composite12 的 outMisc 必须覆盖此范围，不能只覆盖 Bloom 图集包围盒。
vec2 bloomMiscRectMax() {
    vec2 miscSize = vec2(textureSize(colortex7, 0));
    vec2 skyboxMax = vec2(float(SKYBOX_LUT_SIZE)) / miscSize;
    vec2 skyViewMax = vec2(
        float(SKYVIEW_LUT_ORIGIN_X + SKYVIEW_LUT_W),
        float(2 * SKYVIEW_LUT_H)
    ) / miscSize;
    return max(skyboxMax, skyViewMax);
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

// 计算第 k 级 tile 的金字塔合并结果（composite_bloom_upsample 调用，k = 0~3 目标级，
// tileLocal = 目标 tile 内容归一化坐标，目标纹素中心自然落在源 2×2 区域的子纹素位置）：
// 本级原始内容乘级权重 + 上一 pass 已合并 tile k+1 的 tentFilter4 放大 2 倍相加；
// k = 3 的源 tile4 是唯一未经合并的原始级，乘末级权重后并入。
// 权重在相加处逐级施加（tile0 由此累积全部级权重，getBloom 统一除以权重和归一）
vec3 bloomUpsampleTile(int k, vec2 tileLocal, ivec2 pixel) {
    vec4 rect = bloomTileRect(k);
    vec4 srcRect = bloomTileRect(k + 1);
    vec2 bufTexel = 1.0 / vec2(textureSize(colortex1, 0));
    vec2 srcCenter = srcRect.xy + tileLocal * srcRect.zw;
    vec4 clampRect = vec4(srcRect.xy + bufTexel * 0.5, srcRect.xy + srcRect.zw - bufTexel * 0.5);
    vec3 coarse = tentFilter4(colortex1, srcCenter, bufTexel, clampRect);
    if (k == BLOOM_TILE_COUNT - 2) coarse *= BLOOM_WEIGHTS[BLOOM_TILE_COUNT - 1];
    vec3 fine = texelFetch(colortex1, pixel, 0).rgb;
    return fine * BLOOM_WEIGHTS[k] + coarse;
}

// 合并入口（final 调用）：回卷链已把全部级合并进 tile0，此处仅 tent 放大 4 倍（单级 4 倍 + tent
// 无网格伪影）；除以权重和归一，返回与场景同量级的泛光颜色
vec3 getBloom(vec2 screenUv) {
    vec2 bufTexel = 1.0 / vec2(textureSize(colortex1, 0));
    vec2 uv = clamp(screenUv * 0.25, bufTexel * 0.5, vec2(0.25) - bufTexel * 0.5);
    return textureLod(colortex1, uv, 0.0).rgb / BLOOM_WEIGHT_SUM;
}
#endif
