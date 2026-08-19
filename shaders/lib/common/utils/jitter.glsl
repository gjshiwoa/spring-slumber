// TAA 亚像素抖动注入（对应春雷 lib/common/utils/stochastic.glsl 的 jitter 部分），由 gbuffer 类
// program 的 vsh 与 composite_taa 的 vsh 按需平铺引入；依赖先行 include constants.glsl（TAA_JITTER_SAMPLES /
// TAA_JITTER_SCALE）与 uniforms.glsl（frameCounter / viewWidth / viewHeight），lib 之间不互相 include 的约定不变
#ifndef LIB_JITTER_GLSL
#define LIB_JITTER_GLSL

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
