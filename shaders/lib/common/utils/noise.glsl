// 噪声 / 抖动 / TAA jitter 工具（通用，与具体效果解耦）
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：
//   lib/common/globals/constants.glsl（GOLDEN_RATIO / TAA_JITTER_SAMPLES / TAA_JITTER_SCALE /
//     子区域机制开启时的 EFFECTIVE_RENDER_SCALE）、
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

// ---------------- simplex / worley 噪声基元（程序化图案——云；结构移植自春v2 noise.glsl） ----------------
// hash 为本包替换的无 sin 浮点 hash（Dave Hoskins 构造，纯乘加 + fract、零超越函数——多数 GPU
// 的 sin 走 SFU / 多周期展开、吞吐低于常规 ALU，且纯 IEEE 运算跨驱动位确定、比 sin 更利于 TAA
// 时间累积）。替换春v2 sin-dot 系的代价：云图案整体更换（统计等价、观感需 A/B）。输入坐标须
// ~1e4 量级内有界——消费方为角域坐标（云 = 世界 xz / 云壳半径，octave 放大后 ~10³~10⁴），该量级
// 内精度无损；更大坐标域须换整数 hash（扩展点）

// rand2 / hash13 / hash33 源自 "Hash without Sine"（https://www.shadertoy.com/view/4djSRW），
// 其随代码发布的 MIT 声明原样保留于下（依 MIT 条款：版权与许可声明须随副本保留）：
//
// MIT License
//
// Copyright (c) 2014 David Hoskins
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// [0,1)² hash（worley 特征点等）
vec2 rand2(vec2 p) {
    vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// simplex 梯度向量（[-1,1]，rand2 同款 hash ×2−1）
vec2 hash22(vec2 p) {
    return -1.0 + 2.0 * rand2(p);
}

// [0,1) / [0,1)³ 3D hash（rand2 同族，星盘点星消费——sky.glsl getStars 的立方体网格
// 分格；星图坐标有界 [−1,1]³ × 网格密度 ~60，精度域内无忧）
float hash13(vec3 p3) {
    p3 = fract(p3 * 0.1031);
    p3 += dot(p3, p3.zyx + 31.32);
    return fract((p3.x + p3.y) * p3.z);
}

vec3 hash33(vec3 p3) {
    p3 = fract(p3 * vec3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yxz + 33.33);
    return fract((p3.xxy + p3.yxx) * p3.zyx);
}

// 解析 simplex 噪声（[-1,1]，IQ / Gustavson 构造）
float simplex2d(vec2 p) {
    const float K1 = 0.366025404;
    const float K2 = 0.211324865;

    vec2 i = floor(p + (p.x + p.y) * K1);
    vec2 a = p - (i - (i.x + i.y) * K2);
    vec2 o = (a.x < a.y) ? vec2(0.0, 1.0) : vec2(1.0, 0.0);
    vec2 b = a - o + K2;
    vec2 c = a - 1.0 + 2.0 * K2;
    vec3 h = max(0.5 - vec3(dot(a, a), dot(b, b), dot(c, c)), 0.0);
    vec3 n = h * h * h * h * vec3(dot(a, hash22(i)), dot(b, hash22(i + o)), dot(c, hash22(i + 1.0)));
    return dot(vec3(70.0), n);
}

// ---------------- TAA jitter（对应春雷 lib/common/utils/stochastic.glsl 的 jitter 部分） ----------------
// 由 gbuffer 类 program 的 vsh 与通用全屏 vsh（program/fullscreen_vsh.glsl，其 vJitter 即
// taaJitterUV 的 vsh 侧一次算好）按需平铺引入

// 当前帧抖动相位（像素域 [-0.5, 0.5] × TAA_JITTER_SCALE，Halton(2,3) 32 相位查表）。
// SR 超分接管时（SR_UPSCALE，constants.glsl）换用 SR mod 的 SRJitterOffset（mod 生成的相位
// 序列、渲染分辨率像素域 = 本函数的像素域约定）——下游 applyTAAJitter / applyJitter / vJitter
// 全链自动跟进；算法不支持 jitter 时该 uniform 恒 0 = 不抖（本包 TAA 已旁路，自抖无解析端）
vec2 taaJitterSample() {
#ifdef SR_UPSCALE
    return SRJitterOffset;
#else
    return TAA_JITTER_SAMPLES[frameCounter & 31] * TAA_JITTER_SCALE;
#endif
}

// 当前帧抖动（uv 域）
vec2 taaJitterUV() {
    return taaJitterSample() / vec2(viewWidth, viewHeight);
}

// vsh 注入：clip 空间平移（1 px = 2/res NDC，乘 w 保透视）。TAAU / SR_UPSCALE：先缩放进左下
// [0,S]² 子区域再叠 jitter——注意 jitter 在子区域缩放**之后**的 NDC 域注入，NDC→viewport 换算按整块 buffer，
// 有效位移 = ±0.5 **渲染纹素**（buffer 纹素 = 子区域内渲染纹素，与 S 无关；c13 / Kappa / Photon
// 三家同语义；SR 接管时 S = SR_RENDER_SCALE_FACTOR、jitter = SRJitterOffset，同一注入式）。
// 解析端（composite_taa）的去抖补偿须在同一 buffer 纹素域等量施加，见 taa.glsl
vec4 applyTAAJitter(vec4 clipPos) {
#if defined(TAAU) || defined(SR_UPSCALE)
    clipPos.xy = clipPos.xy * EFFECTIVE_RENDER_SCALE + (EFFECTIVE_RENDER_SCALE - 1.0) * clipPos.w;
#endif
    clipPos.xy += taaJitterSample() * (2.0 / vec2(viewWidth, viewHeight)) * clipPos.w;
    return clipPos;
}

// uv 域补偿对：无抖动全视场 uv <-> buffer uv 互转（几何已 +jitter；屏幕空间追踪阴影 / 未来 SSR /
// SSAO 等的采样一致性用，春雷同款 + TAAU 补全）。TAAU / SR_UPSCALE：几何先缩进左下 [0,S]² 子区域
// 再叠 jitter，buffer uv = 全视场 uv·S + jitter——与 deferred_init 去抖基底 (像素uv − vJitter)/S
// 严格互逆；不补 ×S 时补偿随 S 缩水（S=0.5 只剩 1/4）、采样错位 ~0.375 渲染纹素（TAAU 糊/闪同因）。
// applyJitter 消费方 = 屏幕空间追踪阴影〔仿射系数探针反解〕+ 水面 SSR〔2D SSPT 端点折叠，
// 2026-10 起〕；applyInverseJitter 的 jitter 参数版 = 各 pass 位置重建基底（见函数注）
vec2 applyJitter(vec2 uv) {
#if defined(TAAU) || defined(SR_UPSCALE)
    uv *= EFFECTIVE_RENDER_SCALE;
#endif
    return uv + taaJitterUV();
}

// 去抖重载（jitter 参数版 = 在树热路径）：入参 jitterUv 为调用方已持值——通用全屏 vsh 的 vJitter
// varying / 前向 program vsh 的同名 varying / 调用点局部 jitter，免 taaJitterUV 的每像素 Halton 表
// 动态索引 + 除法重算（2026-09 性能纪律，原各 pass 内联手抄本式、2026-10 收敛回本函数）。
// 消费方：deferred_init / composite_fog 的位置重建基底、lib/water/surface.glsl 的去抖 / 折射 /
// 命中点换算、lib/post/taa.glsl 的重投影锚点——「buffer uv → 无抖动全视场 uv」全树单真源
//（SR 接管时 S / jitter 两源均由 SR 供给，本函数域约定不变）
vec2 applyInverseJitter(vec2 uv, vec2 jitterUv) {
#if defined(TAAU) || defined(SR_UPSCALE)
    return (uv - jitterUv) / EFFECTIVE_RENDER_SCALE;
#else
    return uv - jitterUv;
#endif
}

// 便捷版（自算 jitter）：非热路径 / 无 varying 可持时用；与参数版同一实现
vec2 applyInverseJitter(vec2 uv) {
    return applyInverseJitter(uv, taaJitterUV());
}

// ---------------- TAAU 渲染子区域外片元剔除（仅片段阶段；SR_UPSCALE 复用同一机制、S = SR 比例） ----------------
// GPU 多边形裁剪按全屏 NDC、不知子区域边界——视锥外近带（NDC xy ∈ [1, 2/S−1]，S=0.75 时
// [1, 1.67]：缩放式 NDC' = NDC·S + S−1 在裁剪立方 NDC' = 1 处反解的上限；负侧贴齐 −1、无对应带）
// 几何缩放后落进子区域外、白跑 fsh（正确性由读端钳边免疫，纯性能剔除；kappa / photon / FSR2 同款）。调用纪律：
// **置于集中屏幕导数之后、一切纹理采样之前**（discard 后幸存像素导数未定义，与 cutout discard
// 同一纪律）。ceil + 1 texel 容差吸收非整渲染分辨率的半像素边界、宁可少剔不误杀；TAAU 关闭时
// 恒 false 零成本。#ifdef STAGE_FRAGMENT 守卫——gl_FragCoord 为片段专属输入而本文件亦被 vsh 编译
#ifdef STAGE_FRAGMENT
bool outsideRenderRegion() {
#if defined(TAAU) || defined(SR_UPSCALE)
    vec2 limit = ceil(vec2(viewWidth, viewHeight) * EFFECTIVE_RENDER_SCALE) + 1.0;
    return any(greaterThan(gl_FragCoord.xy, limit)) || any(lessThan(gl_FragCoord.xy, vec2(-1.0)));
#else
    return false;
#endif
}
#endif

#endif
