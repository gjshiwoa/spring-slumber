// pass 顺序标记（诊断工具，仅读取端）：判定当前 gbuffers 阶段 pass 相对 deferred 的执行时机
// 「有一部分 gbuffer 阶段文件可能同时在 deferred 前后使用」——标记生命周期（一个帧循环）：
//   composite12 帧末复位 0 → 帧头 gbuffers（deferred 之前，如 textured 族）读 0 →
//   deferred_init 写 1 → 之后的前向 gbuffers（water / hand_water / weather）读 1 → 复位，循环。
// colortex7Clear = false 令槽跨帧存活；写入 / 复位为一次性小逻辑，分别内联于 deferred_init 与
// composite_bloom_upsample（BLOOM_LEVEL 0），本文件只承载读取。
//
// 用法：被测 gbuffers fsh include 本文件后调用 isAfterDeferred()——true = 本 pass 在 deferred
// 之后执行、false = 之前。
//
// 已知限制：依赖本包 colortex7 无逐 pass 翻转的槽位协议假设（deferred_init 为诊断期第二写入者
// 例外，标记槽单 texel、其余区域同位置读回透传逐位保值）；deferred_init 同 pass 读（LUT 采样）+
// 写 colortex7 与 composite12 透传同款已知取舍（个别驱动 UB，AGENTS.md 已知限制有记载）。
//
// 依赖先行 include：constants（PASS_ORDER_MARKER_TEXEL）/ uniforms（colortex7）
#ifndef LIB_PASS_ORDER_MARKER_GLSL
#define LIB_PASS_ORDER_MARKER_GLSL

// 当前 pass 是否在 deferred 之后执行（标记槽 r > 0.5 = deferred_init 本帧已写 1）。
// gaux4 = colortex7 的采样别名——本函数在 gbuffers vsh 消费，gbuffers 阶段读缓冲须用 gaux 名
bool isAfterDeferred() {
    return texelFetch(gaux4, PASS_ORDER_MARKER_TEXEL, 0).r > 0.5;
}

#endif
