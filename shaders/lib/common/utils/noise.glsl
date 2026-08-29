// 噪声 / 抖动 / TAA jitter 工具（通用，与具体效果解耦）
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：
//   lib/common/globals/constants.glsl（GOLDEN_RATIO / TAA_JITTER_SAMPLES / TAA_JITTER_SCALE /
//     TAAU 开启时的 RENDER_SCALE）、
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

// temporal bayer 时域噪声（春v2 同款）：单帧为 bayer64 空间低频图案（相邻像素值相近——TAA 方差
// 钳制的邻域统计不被高频噪声抬高方差，故弃用单帧高频的 IGN），帧间按 golden ratio 步进相位、
// 与 bayer64 的 64 相位对齐——64 帧遍历 [0,1) 的 64 个均匀错开相位，时间累积等价 64 相位超采样；
// 用于时域旋转 / 抖动采样图案（阴影 PCF 采样盘），composite_taa 时间累积解析成收敛结果
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

// vsh 注入：clip 空间平移（1 px = 2/res NDC，乘 w 保透视）。TAAU：先缩放进左下 [0,S]² 子区域
// 再叠 jitter——jitter 仍以全屏（目标）像素为单位注入、幅度语义自动成为目标像素域抖动，
// composite_taa 的上采样解析据此恢复目标分辨率细节
vec4 applyTAAJitter(vec4 clipPos) {
#ifdef TAAU
    clipPos.xy = clipPos.xy * RENDER_SCALE + (RENDER_SCALE - 1.0) * clipPos.w;
#endif
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

// ---------------- TAAU 渲染子区域外片元剔除（仅片段阶段） ----------------
// GPU 多边形裁剪按全屏 NDC、不知子区域边界——视锥外近带（NDC xy ∈ [1, 1/S]）几何缩放后落进
// 子区域外、白跑 fsh（正确性由读端钳边免疫，纯性能剔除；kappa / photon / FSR2 同款）。调用纪律：
// **置于集中屏幕导数之后、一切纹理采样之前**（discard 后幸存像素导数未定义，与 cutout discard
// 同一纪律）。ceil + 1 texel 容差吸收非整渲染分辨率的半像素边界、宁可少剔不误杀；TAAU 关闭时
// 恒 false 零成本。#ifdef STAGE_FRAGMENT 守卫——gl_FragCoord 为片段专属输入而本文件亦被 vsh 编译
#ifdef STAGE_FRAGMENT
bool outsideRenderRegion() {
#ifdef TAAU
    vec2 limit = ceil(vec2(viewWidth, viewHeight) * RENDER_SCALE) + 1.0;
    return any(greaterThan(gl_FragCoord.xy, limit)) || any(lessThan(gl_FragCoord.xy, vec2(-1.0)));
#else
    return false;
#endif
}
#endif

#endif
