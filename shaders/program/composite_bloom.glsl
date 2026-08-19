// Bloom 下采样 pass：composite_bloom（world0/composite4~8 入口，入口定义 BLOOM_LEVEL = 0~4）
// 链式金字塔第 BLOOM_LEVEL 级，读写 colortex1 tile 图集（lib/post/bloom.glsl 的布局）：
//   tile < BLOOM_LEVEL 的像素原样复制回写（每 pass 重写自己需要的全部 tile，跨 pass 保值，
//   对 OptiFine / Iris 的 main/alt 缓冲翻转语义免疫，无需 flip.* 配置）
//   tile == BLOOM_LEVEL 的像素从上一级 tile（或 colortex0）做 13-tap 高斯下采样
//   其余像素（tile 间隔与图集外）discard
// vsh 把 quad 压缩到 tiles 0~BLOOM_LEVEL 的包围盒，只光栅化需要区域（全屏 discard 浪费填充率）
// 上采样回卷在 composite_bloom_upsample（composite9~12），场景合成在 composite_bloom_merge（composite13），composite_tonemap 只做纯 AgX
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
    for (int k = 0; k <= BLOOM_LEVEL; k++) {
        vec4 rect = bloomTileRect(k);
        if (all(greaterThanEqual(vTexCoord, rect.xy)) && all(lessThanEqual(vTexCoord, rect.xy + rect.zw))) {
            if (k < BLOOM_LEVEL) {
                outColor = texture(colortex1, vTexCoord);
            } else {
                vec2 tileLocal = (vTexCoord - rect.xy) / rect.zw;
                outColor = vec4(bloomDownsampleTile(BLOOM_LEVEL, tileLocal), 1.0);
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
    // quad 压缩到 tiles 0~BLOOM_LEVEL 的包围盒（原点恒为 (0,0)，春雷 / c13 同款技巧）
    vec2 rectMax = vec2(0.0);
    for (int k = 0; k <= BLOOM_LEVEL; k++) {
        vec4 rect = bloomTileRect(k);
        rectMax = max(rectMax, rect.xy + rect.zw);
    }
    vec2 rectUv = quadUv * rectMax;
    pos.xy = (rectUv * 2.0 - 1.0) * pos.w;
    gl_Position = pos;
    vTexCoord = rectUv;
}

#endif
