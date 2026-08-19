// Bloom 上采样回卷 pass：composite_bloom_upsample（world0/composite9~12 入口，入口定义 BLOOM_LEVEL = 目标 tile 序号 3~0）
// 金字塔自粗向细逐级合并：tile BLOOM_LEVEL = 本级原始内容 × 级权重 + 上一 pass 已合并
// tile BLOOM_LEVEL+1 的 tent 放大 2 倍相加（lib/post/bloom.glsl 的 bloomUpsampleTile），
// 粗级模糊经逐级 tent 累积成连续衰减（每级仅 2 倍放大，无大倍率双线性的菱形网格 / 离散半径环）：
//   tile != BLOOM_LEVEL 的像素原样复制回写，非 tile 像素（tile 间隔与包围盒内边角）同样复制回写、
//   不 discard——BLOOM_LEVEL 0 兼写 colortex7 须包围盒整写（见下），discard 会连座丢弃全部附件；
//   每 pass 重写整个图集包围盒，跨 pass 保值、对 OptiFine / Iris 的 main/alt 翻转语义免疫，同下采样链
//   （tile4 恒为原始下采样内容——composite12 测光依赖，绝不被本链覆盖）
// BLOOM_LEVEL == 0（composite12，上采样链末级）：兼自动曝光寄生存储（春v2 同款 pass 设计，不新增
// 全屏 pass）——colortex7 曝光槽位（图集包围盒内 tile3/tile4 间隔 texel，lib/post/exposure.glsl 的
// exposureTexel）测图集最粗 tile（tile4）对数平均亮度（春雷算法、固定 16 点核）、与槽位上一帧曝光
// 指数平滑后写回，其余像素 colortex7 同位置读回原样透传（本 pass 是 colortex7 唯一写入者，包围盒
// 区域整写保值，clear = false 跨帧存活、无 flip.* 依赖）；tile4 源安全：本 pass 读 colortex1 为上一
// pass（composite11）终态，tile4 自 composite8 写入后只被复制回写、恒为原始下采样内容，无同 pass 竞争
// （无须改源 tile3——那是把槽位寄生到下采样链末级 composite8 才有的竞争，tile4 正是其在写的 tile）
// DRAWBUFFERS 随输出缓冲不同下放入口文件（composite9~11 = 1、composite12 = 17），program 不携带以免展开后重复
// 场景合成与曝光应用、AgX、gamma 在 final 单 pass 完成
// vsh 把 quad 压缩到全图集包围盒，只光栅化需要区域（全屏 discard 浪费填充率）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

#if BLOOM_LEVEL == 0
layout(location = 0) out vec4 outColor; // colortex1：tile 图集
layout(location = 1) out vec4 outMisc;  // colortex7：曝光槽位 + 其余透传
#else
layout(location = 0) out vec4 outColor;
#endif

void main() {
    bool inTile = false;
    for (int k = 0; k < BLOOM_TILE_COUNT; k++) {
        vec4 rect = bloomTileRect(k);
        if (all(greaterThanEqual(vTexCoord, rect.xy)) && all(lessThanEqual(vTexCoord, rect.xy + rect.zw))) {
            if (k != BLOOM_LEVEL) {
                outColor = texture(colortex1, vTexCoord);
            } else {
                vec2 tileLocal = (vTexCoord - rect.xy) / rect.zw;
                outColor = vec4(bloomUpsampleTile(BLOOM_LEVEL, tileLocal), 1.0);
            }
            inTile = true;
            break;
        }
    }
    // 非 tile 像素（间隔与包围盒内边角）复制回写：colortex7 包围盒整写不可 discard，
    // colortex1 侧这些纹素无读者、复制回写只增保值纪律不增语义
    if (!inTile) outColor = texture(colortex1, vTexCoord);

#if BLOOM_LEVEL == 0
    // 自动曝光寄生存储：仅槽位 1 texel 付测光成本，其余像素透传保持 colortex7 既有内容
    if (ivec2(gl_FragCoord.xy) == exposureTexel()) {
        outMisc = vec4(adaptedExposure(targetExposure(sceneAverageLuminance())), 0.0, 0.0, 1.0);
    } else {
        outMisc = texelFetch(colortex7, ivec2(gl_FragCoord.xy), 0);
    }
#endif
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    vec4 pos = ftransform();
    vec2 quadUv = pos.xy / pos.w * 0.5 + 0.5;
    // quad 压缩到全图集包围盒（复制回写须覆盖所有 tile 与 colortex7 槽位，春雷 / c13 同款技巧）
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
