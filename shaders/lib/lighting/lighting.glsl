// 表面光照（线性空间）
// deferred 全屏阶段与前向程序共用同一份 shadeSurface，保证两条路线光照一致
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：lib/common/globals/uniforms.glsl、
// lib/common/globals/constants.glsl（光照颜色常量）、lib/atmosphere/sky.glsl（dayNightFactor）
#ifndef LIB_LIGHTING_GLSL
#define LIB_LIGHTING_GLSL

// 表面光照主入口
// albedo     线性反照率
// normalView 视图空间法线（不要求归一化）
// lm         重映射后的光照图（x = 方块光，y = 天空光），见 common/pipeline/gbuffer_data.glsl remapLightmap
vec3 shadeSurface(vec3 albedo, vec3 normalView, vec2 lm) {
    float day = dayNightFactor();

    vec3 normalWorld = normalize(mat3(gbufferModelViewInverse) * normalView);
    vec3 lightDirWorld = normalize(mat3(gbufferModelViewInverse) * normalize(shadowLightPosition));

    // 直射光：无阴影贴图，用天空光门控近似遮挡（洞内 skyLight 低，阳光进不来）
    float directGate = smoothstep(0.50, 0.95, lm.y);
    float ndl = max(dot(normalWorld, lightDirWorld), 0.0);
    vec3 direct = mix(MOONLIGHT_COLOR, SUNLIGHT_COLOR, day) * (ndl * directGate);
    direct *= 1.0 - 0.75 * rainStrength; // 雨天直射光衰减

    // 天空环境光：上半球亮、下半球暗的半球近似
    float hemisphere = 0.6 + 0.4 * clamp(normalWorld.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyAmbient = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, day) * (pow(lm.y, 1.5) * hemisphere);

    // 方块光（火把、萤石等），近距离衰减用幂曲线近似
    vec3 blockAmbient = TORCHLIGHT_COLOR * (pow(lm.x, 2.2) * 1.30 + lm.x * 0.02);

    // 雨天环境光去饱和
    float ambientGray = dot(skyAmbient, vec3(0.3333));
    skyAmbient = mix(skyAmbient, vec3(ambientGray) * vec3(0.90, 0.95, 1.05), rainStrength);

    return albedo * (direct + skyAmbient + blockAmbient + MIN_AMBIENT);
}

#endif
