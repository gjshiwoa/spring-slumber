// 天空颜色（线性空间）
// skybasic 前向调用；天空色也供后续雾 / 环境光扩展复用
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：lib/uniforms.glsl、
// lib/constants.glsl（TAU、天空颜色常量）
#ifndef LIB_SKY_GLSL
#define LIB_SKY_GLSL

// 太阳在世界系中的高度 [-1,1]
float sunHeight() {
    return sin(sunAngle * TAU);
}

// 白天权重，黄昏在 -0.10 ~ 0.25 之间过渡
float dayNightFactor() {
    return smoothstep(-0.10, 0.25, sunHeight());
}

// 黄昏权重，太阳贴近地平线时最大
float duskFactor() {
    return 1.0 - smoothstep(0.0, 0.35, abs(sunHeight()));
}

// 天空渐变色，dirView 为视图空间方向（不要求归一化）
vec3 getSkyColor(vec3 dirView) {
    vec3 dirWorld = normalize(mat3(gbufferModelViewInverse) * dirView);
    vec3 sunDirWorld = normalize(mat3(gbufferModelViewInverse) * normalize(sunPosition));

    float day = dayNightFactor();

    vec3 zenith  = mix(NIGHT_ZENITH, DAY_ZENITH, day);
    vec3 horizon = mix(NIGHT_HORIZON, DAY_HORIZON, day);

    // 黄昏时地平线一侧的暖色，朝太阳方向更浓
    float horizonWeight = pow(1.0 - clamp(dirWorld.y, 0.0, 1.0), 3.0);
    float sunFacing = pow(max(dot(dirWorld, sunDirWorld), 0.0), 3.0);
    horizon = mix(horizon, DUSK_HORIZON, duskFactor() * horizonWeight * (0.35 + 0.65 * sunFacing));

    float gradient = pow(clamp(dirWorld.y, 0.0, 1.0), 0.55);
    vec3 sky = mix(horizon, zenith, gradient);

    // 地平线以下向暗部过渡（虚空方向）
    sky = mix(sky, sky * 0.35, clamp(-dirWorld.y * 3.0, 0.0, 1.0));

    // 雨天：压暗并去饱和
    float gray = dot(sky, vec3(0.3333));
    sky = mix(sky, vec3(gray) * vec3(0.75, 0.80, 0.88), rainStrength * 0.9);

    return sky;
}

#endif
