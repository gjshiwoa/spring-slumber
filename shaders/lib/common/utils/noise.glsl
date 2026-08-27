// 噪声 / 抖动 / TAA jitter 工具（通用，与具体效果解耦）
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：
//   lib/common/globals/constants.glsl（GOLDEN_RATIO / TAA_JITTER_SAMPLES / TAA_JITTER_SCALE）、
//   lib/common/globals/uniforms.glsl（frameCounter / viewWidth / viewHeight）
#ifndef LIB_NOISE_GLSL
#define LIB_NOISE_GLSL

// ---------------- 噪声 ----------------

// 2x2 bayer 有序抖动基矩阵（robobo1221 构造，春v2 noise.glsl 同款）
float bayer2(vec2 a) {
    a = floor(a);
    return fract(dot(a, vec2(0.5, a.y * 0.75)));
}

// 逐级递归翻倍矩阵尺寸（bayer4 = 4x4 ... bayer64 = 64x64）：低两级图案平铺、乘 0.25 权重叠加进当前级
#define bayer4(a)  (bayer2(0.5 * (a)) * 0.25 + bayer2(a))
#define bayer8(a)  (bayer4(0.5 * (a)) * 0.25 + bayer2(a))
#define bayer16(a) (bayer8(0.5 * (a)) * 0.25 + bayer2(a))
#define bayer32(a) (bayer16(0.5 * (a)) * 0.25 + bayer2(a))
#define bayer64(a) (bayer32(0.5 * (a)) * 0.25 + bayer2(a))

// temporal bayer 时域噪声（春v2 temporalBayer64 同款）：单帧为 bayer64 空间规则图案（相邻像素值相近、
// 8x8 tile 内规则渐变——空间低频，TAA 方差钳制的邻域统计不被高频噪声抬高方差、历史权重不被误压），
// 帧间按 golden ratio（1/φ）低差异步进旋转相位，与 bayer64 的 64 相位对齐——64 帧恰好遍历 [0,1) 的
// 64 个均匀错开相位，时间累积等价 64 相位超采样（此前的 IGN 逐像素去相关、单帧内高频，邻域统计会把
// 噪声当方差钳掉历史，收敛慢且阴影残留噪点）。用于时域旋转 / 抖动采样图案（如阴影 PCF 采样盘，
// 见 lib/lighting/shadow.glsl），composite_taa 时间累积把噪声解析成收敛结果
float temporalBayer64(vec2 pixelPos) {
    return fract(bayer64(pixelPos) + float(frameCounter % 64) * GOLDEN_RATIO);
}

// ---------------- TAA jitter（对应春雷 lib/common/utils/stochastic.glsl 的 jitter 部分） ----------------
// 由 gbuffer 类 program 的 vsh 与通用全屏 vsh（program/fullscreen_vsh.glsl，其 vJitter 即
// taaJitterUV 的 vsh 侧一次算好）按需平铺引入

// 当前帧抖动相位（像素域 [-0.5, 0.5] × TAA_JITTER_SCALE，Halton(2,3) 16 相位）
vec2 taaJitterSample() {
    return TAA_JITTER_SAMPLES[frameCounter & 15] * TAA_JITTER_SCALE;
}

// 当前帧抖动（uv 域）
vec2 taaJitterUV() {
    return taaJitterSample() / vec2(viewWidth, viewHeight);
}

// vsh 注入：clip 空间平移（春雷 applyStableJitter 同款；1 px = 2/res NDC，乘 w 保持透视正确）
vec4 applyTAAJitter(vec4 clipPos) {
    clipPos.xy += taaJitterSample() * (2.0 / vec2(viewWidth, viewHeight)) * clipPos.w;
    return clipPos;
}

// uv 域补偿对：几何已 +jitter，屏幕坐标 <-> 无抖动坐标互转（未来 SSR / SSAO 等采样一致性用，春雷同款）
vec2 applyJitter(vec2 uv) {
    return uv + taaJitterUV();
}

vec2 applyInverseJitter(vec2 uv) {
    return uv - taaJitterUV();
}

#endif
