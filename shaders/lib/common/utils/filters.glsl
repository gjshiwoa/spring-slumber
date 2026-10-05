// 通用采样 / 滤波工具库：函数全部显式传参、不引用 uniforms（唯一常量例外：rcasLobe 的去噪
// 分支由 constants.glsl 的 RCAS_DENOISE 宏门控，接入方须在 constants 之后 include 方可启用），
// 由 program 按需平铺 include（lib 之间不互相 include 的约定不变）
#ifndef LIB_SAMPLING_GLSL
#define LIB_SAMPLING_GLSL

// smoothstep 加权双线性（iq: Texture - Better Filtering，春雷同款）：
// 单次采样、仅多几个 ALU，把双线性的线性插值权重换成 3t²-2t³ 平滑曲线，观感接近 bicubic
// https://www.shadertoy.com/view/XsfGDn
//
// ---- 上游许可（该 shader 代码头自带的 MIT 声明，原样保留；依 MIT 条款：版权与许可声明须随
//      副本保留。lib/water/waves.glsl 的 waterNoiseTexel 与 lib/lighting/caustics.glsl 的
//      causticsNoiseTexel 为同一实现的就地镜像，同受本声明覆盖）----
//
// The MIT License
// Copyright © 2013 Inigo Quilez
// https://www.youtube.com/c/InigoQuilez
// https://iquilezles.org/
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
//
// 上游自述：This is the implementation for my article "improved texture interpolation"
// https://iquilezles.org/articles/texture
vec3 textureNice(sampler2D src, vec2 uv) {
    vec2 resolution = vec2(textureSize(src, 0));
    uv = uv * resolution + 0.5;
    vec2 iuv = floor(uv);
    vec2 fuv = fract(uv);
    uv = iuv + fuv * fuv * (3.0 - 2.0 * fuv);
    uv = (uv - 0.5) / resolution;
    return texture(src, uv).rgb;
}

// 4-tap 对角 tent 上采样核（下采样 13-tap 核的上采样对位工具）：center 处 4 个对角双线性 tap
// 平均——逐级 2 倍上采样无伪影、大倍率放大不出现菱形网格；center / tapStep 为源纹理归一化坐标，
// clampRect 同 downsample13Tap（tap 越界钳回边缘）
vec3 tentFilter4(sampler2D src, vec2 center, vec2 tapStep, vec4 clampRect) {
    vec3 result = vec3(0.0);
    result += texture(src, clamp(center + tapStep * vec2(-1.0, -1.0), clampRect.xy, clampRect.zw)).rgb;
    result += texture(src, clamp(center + tapStep * vec2( 1.0, -1.0), clampRect.xy, clampRect.zw)).rgb;
    result += texture(src, clamp(center + tapStep * vec2(-1.0,  1.0), clampRect.xy, clampRect.zw)).rgb;
    result += texture(src, clamp(center + tapStep * vec2( 1.0,  1.0), clampRect.xy, clampRect.zw)).rgb;
    return result * 0.25;
}

// 13-tap 下采样核（tap 布局：COD: Advanced Warfare；权重：春雷那套，见其 filters.glsl）：
// tap 步长由调用方给定（源纹素数 × 源纹素尺寸），配合双线性中点采样，每级覆盖 = ±2×步长纹素
// center / tapStep 为源纹理归一化坐标；clampRect = (min.xy, max.xy) 源区域半纹素内缩后的钳制范围，tap 越界钳回边缘
// https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/
// 权重与原版 COD 的 1/32、1/16、1/8 幂分数不同（角 / 边降、中心与对角抬，3×3 主体 0.52 / 对角 0.48，
// 分布略窄），十进制合计精确 = 1.000——消费端不做二次归一化，float 求和漂移 ~1e-7 对 bloom 不可见
const vec2  downsample13Offsets[13] = vec2[13](
    vec2(-2.0,  2.0), vec2(0.0,  2.0), vec2( 2.0,  2.0),
    vec2(-2.0,  0.0), vec2(0.0,  0.0), vec2( 2.0,  0.0),
    vec2(-2.0, -2.0), vec2(0.0, -2.0), vec2( 2.0, -2.0),
    vec2(-1.0,  1.0), vec2(1.0,  1.0), vec2(-1.0, -1.0), vec2(1.0, -1.0)
);
const float downsample13Weights[13] = float[13](
    0.010,  0.070, 0.010,
    0.070,  0.200, 0.070,
    0.010,  0.070, 0.010,
    0.120,  0.120, 0.120,  0.120
);

vec3 downsample13Tap(sampler2D src, vec2 center, vec2 tapStep, vec4 clampRect) {
    vec3 result = vec3(0.0);
    for (int i = 0; i < 13; i++) {
        vec2 uv = clamp(center + tapStep * downsample13Offsets[i], clampRect.xy, clampRect.zw);
        result += texture(src, uv).rgb * downsample13Weights[i];
    }
    return result;
}

// 5-tap 锐化 Catmull-Rom 重采样（春v2 同款，Jimenez 快速重采样把 4×4 双三次压成 5 tap）：
// 4 角 + 十字中心共 5 次显式 Lod0 双线性 tap，返回 rgba 全通道（TAA 历史：a = 上帧深度随同一组
// 权重一趟带回，免独立采样）；sharpenAmount 为锐化强度（0 = 标准 Catmull-Rom，1 = 最锐），
// texSize 显式传入，函数保持无依赖
vec4 catmullRom5(sampler2D src, vec2 uv, vec2 texSize, float sharpenAmount) {
    vec2 position = uv * texSize;
    vec2 centerPosition = floor(position - 0.5) + 0.5;
    vec2 f = position - centerPosition;
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;

    float c = sharpenAmount; // 不能写成 const：参数初始化 const 违反 GLSL 规范，NVIDIA 前端在 vsh 解析时直接 C1059
    vec2 w0 =        -c  * f3 +  2.0 * c         * f2 - c * f;
    vec2 w1 =  (2.0 - c) * f3 - (3.0 - c)        * f2         + 1.0;
    vec2 w2 = -(2.0 - c) * f3 + (3.0 -  2.0 * c) * f2 + c * f;
    vec2 w3 =         c  * f3 -                 c * f2;

    vec2 w12 = w1 + w2;
    vec2 tc12 = (centerPosition + w2 / w12) / texSize;
    vec2 tc0 = (centerPosition - 1.0) / texSize;
    vec2 tc3 = (centerPosition + 2.0) / texSize;

    // rgb 与源 a 通道用同一组权重累计，末尾按权重和归一（负瓣可使个别通道轻微过冲，无碍）
    vec4 result = vec4(0.0);
    float weightSum = 0.0;

    result += textureLod(src, vec2(tc12.x, tc0.y), 0.0) * (w12.x * w0.y);
    weightSum += w12.x * w0.y;
    result += textureLod(src, vec2(tc0.x,  tc12.y), 0.0) * (w0.x * w12.y);
    weightSum += w0.x * w12.y;
    result += textureLod(src, vec2(tc12.x, tc12.y), 0.0) * (w12.x * w12.y);
    weightSum += w12.x * w12.y;
    result += textureLod(src, vec2(tc3.x,  tc12.y), 0.0) * (w3.x * w12.y);
    weightSum += w3.x * w12.y;
    result += textureLod(src, vec2(tc12.x, tc3.y), 0.0) * (w12.x * w3.y);
    weightSum += w12.x * w3.y;

    return result / weightSum;
}

// 上游许可（AMD FidelityFX FSR1，随所引 SDK 文件发布、依 MIT 条款原样保留于下；
// rcasLobe 为其实质部分的适配拆分）：
//
// MIT License
//
// Copyright (c) 2023 Advanced Micro Devices, Inc. All rights reserved.
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

// RCAS 锐化增益（AMD FidelityFX FSR1 Robust Contrast Adaptive Sharpening，移植自春雷
// filters.glsl 的 RcasFilter——FSR3 SDK fsr1 头版本、含 lowerLimiterMultiplier 稳健限幅：
// https://github.com/GPUOpen-LibrariesAndSDKs/FidelityFX-SDK/blob/main/Kits/FidelityFX/upscalers/fsr3/include/gpu/fsr1/ffx_fsr1.h）
// 本函数只返回自适应增益 lobe（春雷原式与输出组合的拆分：lobe 是线性组合系数，统计域与组合域
// 由此解耦——调用方可「感知域取增益、自身工作域做组合 + 单次 tonemap」，省去邻域逐 tap 过
// tonemap 的成本），输出组合 = (lobe·(b+d+f+h) + e) / (4·lobe + 1)，由调用方施加
// b / d / e / f / h = 十字邻域（上 / 左 / 中 / 右 / 下，FSR1 记法），须为单调压到 [0,1] 的
// 感知域值——限幅公式按该域设计（hitMax 以 1 为白点），HDR 线性直入时 >1 通道限幅失效、
// 亮区静默不锐化；sharpnessStops：0.0 最锐、每 +1.0 增益减半（exp2 衰减，强度常量
// RCAS_SHARPNESS 在 constants.glsl）
// RCAS_DENOISE（constants.glsl 可选宏、本文件唯一常量依赖）：邻域亮度波动大处压低增益，
// 不放大噪声 / 颗粒（春雷同款默认开）；未定义时分支编译剔除、回退纯 RCAS
float rcasLobe(vec3 b, vec3 d, vec3 e, vec3 f, vec3 h, float sharpnessStops) {
    const float rcasLimit = 0.25 - 1.0 / 16.0;
    float sharpness = exp2(-sharpnessStops);

    float bL = b.b * 0.5 + (b.r * 0.5 + b.g);
    float dL = d.b * 0.5 + (d.r * 0.5 + d.g);
    float eL = e.b * 0.5 + (e.r * 0.5 + e.g);
    float fL = f.b * 0.5 + (f.r * 0.5 + f.g);
    float hL = h.b * 0.5 + (h.r * 0.5 + h.g);

#ifdef RCAS_DENOISE
    float nz = 0.25 * (bL + dL + fL + hL) - eL;
    nz = clamp(abs(nz) / max(max(max(bL, dL), max(eL, fL)) - min(min(min(bL, dL), min(eL, fL)), hL), 1e-6), 0.0, 1.0);
    nz = -0.5 * nz + 1.0;
#endif

    vec3 mn4 = min(min(b, d), min(f, h));
    vec3 mx4 = max(max(b, d), max(f, h));

    float lowerLimiterMultiplier = clamp(eL / max(min(min(min(bL, dL), fL), hL), 1e-6), 0.0, 1.0);
    vec3 hitMin = mn4 / max(4.0 * mx4, vec3(1e-6)) * lowerLimiterMultiplier;
    vec3 hitMax = (vec3(1.0) - mx4) / min(4.0 * mn4 - vec3(4.0), vec3(-1e-6));

    vec3 lobeRgb = max(-hitMin, hitMax);
    float lobe = max(-rcasLimit, min(max(max(lobeRgb.r, lobeRgb.g), lobeRgb.b), 0.0)) * sharpness;

#ifdef RCAS_DENOISE
    lobe *= nz;
#endif

    return lobe;
}

#endif
