// 通用采样 / 滤波工具库：无依赖（函数全部显式传参，不引用 uniforms / 常量），
// 由 program 按需平铺 include（lib 之间不互相 include 的约定不变）
#ifndef LIB_SAMPLING_GLSL
#define LIB_SAMPLING_GLSL

// smoothstep 加权双线性（iq: Texture - Better Filtering，春雷同款）：
// 单次采样、仅多几个 ALU，把双线性的线性插值权重换成 3t²-2t³ 平滑曲线，观感接近 bicubic
// https://www.shadertoy.com/view/XsfGDn
vec3 textureNice(sampler2D src, vec2 uv) {
    vec2 resolution = vec2(textureSize(src, 0));
    uv = uv * resolution + 0.5;
    vec2 iuv = floor(uv);
    vec2 fuv = fract(uv);
    uv = iuv + fuv * fuv * (3.0 - 2.0 * fuv);
    uv = (uv - 0.5) / resolution;
    return texture(src, uv).rgb;
}

// 4-tap 对角 tent 上采样核（下采样 13-tap 核的上采样对位工具）：
// center 处 4 个对角双线性 tap（±tapStep），平均后有效覆盖 ≈3×3 源纹素的平滑邻域——
// 逐级 2 倍上采样无伪影，大倍率放大不再出现单双线性的菱形网格；
// center / tapStep 为源纹理归一化坐标，clampRect 同 downsample13Tap（tap 越界钳回边缘）
vec3 tentFilter4(sampler2D src, vec2 center, vec2 tapStep, vec4 clampRect) {
    vec3 result = vec3(0.0);
    result += texture(src, clamp(center + tapStep * vec2(-1.0, -1.0), clampRect.xy, clampRect.zw)).rgb;
    result += texture(src, clamp(center + tapStep * vec2( 1.0, -1.0), clampRect.xy, clampRect.zw)).rgb;
    result += texture(src, clamp(center + tapStep * vec2(-1.0,  1.0), clampRect.xy, clampRect.zw)).rgb;
    result += texture(src, clamp(center + tapStep * vec2( 1.0,  1.0), clampRect.xy, clampRect.zw)).rgb;
    return result * 0.25;
}

// 13-tap 下采样核（COD: Advanced Warfare，春雷快速路径同款）：
// tap 步长由调用方给定（源纹素数 × 源纹素尺寸），配合双线性中点采样，每级覆盖 = ±2×步长纹素
// center / tapStep 为源纹理归一化坐标；clampRect = (min.xy, max.xy) 源区域半纹素内缩后的钳制范围，tap 越界钳回边缘
// https://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare/
const vec2  downsample13Offsets[13] = vec2[13](
    vec2(-2.0,  2.0), vec2(0.0,  2.0), vec2( 2.0,  2.0),
    vec2(-2.0,  0.0), vec2(0.0,  0.0), vec2( 2.0,  0.0),
    vec2(-2.0, -2.0), vec2(0.0, -2.0), vec2( 2.0, -2.0),
    vec2(-1.0,  1.0), vec2(1.0,  1.0), vec2(-1.0, -1.0), vec2(1.0, -1.0)
);
const float downsample13Weights[13] = float[13](
    0.03125, 0.0625, 0.03125,
    0.0625,  0.125,  0.0625,
    0.03125, 0.0625, 0.03125,
    0.125,   0.125,  0.125,  0.125
);

vec3 downsample13Tap(sampler2D src, vec2 center, vec2 tapStep, vec4 clampRect) {
    vec3 result = vec3(0.0);
    for (int i = 0; i < 13; i++) {
        vec2 uv = clamp(center + tapStep * downsample13Offsets[i], clampRect.xy, clampRect.zw);
        result += texture(src, uv).rgb * downsample13Weights[i];
    }
    return result;
}

// 5-tap 锐化 Catmull-Rom 重采样（春v2 lib/camera/filter.glsl 的 catmullRom5 同款，SMAA 型锐化参数）：
// 4 角 + 十字中心共 5 次显式 Lod0 双线性 tap（Jimenez 快速重采样，把 4×4 双三次压成 5 tap），
// 返回 rgba 全通道重采样结果（TAA 历史：rgb = 颜色、a = 上帧深度随同一组权重一趟带回，免独立采样）；
// sharpenAmount 为锐化强度（0 = 标准 Catmull-Rom，1 = 最锐；春雷 0.6 / 春v2 低配版 0.8），
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

#endif
