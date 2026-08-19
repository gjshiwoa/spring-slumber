// Bloom 上采样回卷 pass：composite_bloom_upsample（world0/composite9~12 入口，入口定义 BLOOM_LEVEL = 目标 tile 序号 3~0）
// 金字塔自粗向细逐级合并：tile BLOOM_LEVEL = 本级原始内容 × 级权重 + 上一 pass 已合并
// tile BLOOM_LEVEL+1 的 tent 放大 2 倍相加（lib/post/bloom.glsl 的 bloomUpsampleTile），
// 粗级模糊经逐级 tent 累积成连续衰减（每级仅 2 倍放大，无大倍率双线性的菱形网格 / 离散半径环）：
//   tile != BLOOM_LEVEL 的像素原样复制回写（每 pass 重写全部 tile，跨 pass 保值，
//   对 OptiFine / Iris 的 main/alt 缓冲翻转语义免疫，同下采样链；tile4 恒为原始下采样
//   内容——composite13 测光依赖，绝不被本链覆盖）
//   其余像素（tile 间隔与图集外）discard
// vsh 把 quad 压缩到全图集包围盒，只光栅化需要区域（全屏 discard 浪费填充率）
// 场景合成在 composite_bloom_merge（composite13，getBloom 只读 tile0），composite_tonemap 只做纯 AgX
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/post/bloom.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:1 */

layout(location = 0) out vec4 outColor;

void main() {
    for (int k = 0; k < BLOOM_TILE_COUNT; k++) {
        vec4 rect = bloomTileRect(k);
        if (all(greaterThanEqual(vTexCoord, rect.xy)) && all(lessThanEqual(vTexCoord, rect.xy + rect.zw))) {
            if (k != BLOOM_LEVEL) {
                outColor = texture(colortex1, vTexCoord);
            } else {
                vec2 tileLocal = (vTexCoord - rect.xy) / rect.zw;
                outColor = vec4(bloomUpsampleTile(BLOOM_LEVEL, tileLocal), 1.0);
            }
            return;
        }
    }
    discard;
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    vec4 pos = ftransform();
    vec2 quadUv = pos.xy / pos.w * 0.5 + 0.5;
    // quad 压缩到全图集包围盒（复制回写须覆盖所有 tile，春雷 / c13 同款技巧）
    vec2 rectMax = vec2(0.0);
    for (int k = 0; k < BLOOM_TILE_COUNT; k++) {
        vec4 rect = bloomTileRect(k);
        rectMax = max(rectMax, rect.xy + rect.zw);
    }
    vec2 rectUv = quadUv * rectMax;
    pos.xy = (rectUv * 2.0 - 1.0) * pos.w;
    gl_Position = pos;
    vTexCoord = rectUv;
}

#endif
