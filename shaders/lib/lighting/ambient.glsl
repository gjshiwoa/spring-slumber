// 天空环境辐照度基色（vSkyAmbient 的取值实现）——通用全屏 vsh（fullscreen_vsh）与前向 program
// （gbuffers_translucent_simple）各自的 vsh 共用：colortex7 天空 LUT 两半区天顶行探针 fetch 双重
// 职责——rgb = 各光源天顶色精确值（球对称大气下天顶色与方位无关）、alpha = 有效性标记；有效取
// (太阳 + 月亮) × SKY_AMBIENT_BRIGHTNESS（与 getSkyColor 天顶采样同式、非活动半区写黑自动零贡献，
// 色调 / 幅度随 LUT 自动跟进：昼夜 / 曙暮光 / 海拔 / MS，与渲染天空同源同帧滞后），无效回退常量
// 昼夜 mix；雨天去饱和最后并入。lutValid out 参数即 vSkyLutValid 的判定源（不消费的调用方丢弃）
// 依赖先行 include：lib/common/globals/uniforms.glsl（colortex7 / frameCounter / sunAngle /
//   rainStrength）+ lib/common/globals/constants.glsl（TAU / SKYVIEW_* / SKYVIEW_LUT_VALID_MARKER /
//   SKY_AMBIENT_BRIGHTNESS / 昼夜回退常量 / TORCHLIGHT_* / MIN_AMBIENT / PI）
#ifndef LIB_LIGHTING_AMBIENT_GLSL
#define LIB_LIGHTING_AMBIENT_GLSL

// 返回天空环境辐照度基色；lutValid = 探针判定的 LUT 有效性（0/1）
vec3 skyAmbientColor(out float lutValid) {
    // 探针取各半区角 texel（太阳半区天顶行 (260,100)、月亮半区天顶行 (260,0)）——无效内容在整片
    // 区域同现、单 texel 探针足以拦截；NaN 对比较返回 false、同样落入无效分支。
    // gaux4 = colortex7 的采样别名——本函数的消费者含 gbuffers vsh（前向 program），gbuffers
    // 阶段读缓冲须用 gaux 名（deferred / composite 阶段两者同单元等价）
    vec4 skySunProbe  = texelFetch(gaux4, ivec2(SKYVIEW_LUT_ORIGIN_X, SKYVIEW_LUT_H), 0);
    vec4 skyMoonProbe = texelFetch(gaux4, ivec2(SKYVIEW_LUT_ORIGIN_X, 0), 0);
    bool skyLutValid = frameCounter > 0
                && abs(skySunProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && abs(skyMoonProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && all(lessThan(abs(skySunProbe.rgb), vec3(65000.0)))
                && all(lessThan(abs(skyMoonProbe.rgb), vec3(65000.0)));
    lutValid = skyLutValid ? 1.0 : 0.0;

    // 无效回退：常量昼夜 mix，权重 = 太阳高度慢族门（过渡窗比直射门宽、晨昏环境不断黑）
    float dayFactor = smoothstep(-0.10, 0.25, sin(sunAngle * TAU));
    vec3 ambient = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, dayFactor);
    if (skyLutValid) {
        ambient = (skySunProbe.rgb + skyMoonProbe.rgb) * SKY_AMBIENT_BRIGHTNESS;
    }
    // 雨天去饱和：向亮度单色略偏冷 mix（幂雨天空灰蓝）
    return mix(ambient, vec3(dot(ambient, vec3(0.3333))) * vec3(0.90, 0.95, 1.05), rainStrength);
}

// 前向简单光照（光照图轻量着色）：前向半透明与实体的「deferred 之后」路径共用——各项与
// shadeSurface 的环境 / 方块光项逐项同源（辐照度形式），无直射 / 阴影 / 法线（阳光下略暗于
// 受光地形，春v2 同取舍；夜视项不接——shadeSurface 亦无、避免与地形分叉）。lm 为 remapLightmap
// 后的值；半球项取 1 = 向上表面档（粒子 / 雨雪无法线，最亮参考档与受光地面衔接）
vec3 forwardLightmapShade(vec3 albedoLinear, vec2 lm, vec3 skyAmbient) {
    vec2 lmPow4 = lm * lm; // 两分量平方再平方、免 pow 调用
    lmPow4 *= lmPow4;
    vec3 irradiance = skyAmbient * lmPow4.y
                    + TORCHLIGHT_COLOR * (lmPow4.x * TORCHLIGHT_NEAR_SCALE + lm.x * TORCHLIGHT_FLOOR_SCALE)
                    + MIN_AMBIENT;
    return (albedoLinear / PI) * irradiance;
}

#endif
