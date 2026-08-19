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

#endif
