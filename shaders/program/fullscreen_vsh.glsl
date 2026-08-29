// 通用全屏 vsh——deferred_init / composite_taa / final 共用的顶点着色器（参考春v2 全屏 vsh 的
// 帧数据 varying 族）：凡「逐帧恒定、全屏一致」的量在 main 内一次算好、经 out varying 传入 fsh
//（全屏 quad 仅 3~4 顶点、透视矫正插值精确）。接入方式：program 平铺 include（内容 STAGE_VERTEX
// 自守卫、fsh 编译展开为空）；fsh 按需声明同名 in（未声明的由链接器剔除、零成本）；带自定义 vsh
// 的 pass（bloom 链 quad 压缩）不适用，需要帧数据时在自身 vsh 输出同名 varying
// 输出清单（详细语义见各 consuming 侧与 AGENTS.md「通用全屏 vsh」条）：
//   vTexCoord / vJitter / vExposure（无效值回退 1.0）
//   vSunDirection / vMoonDirection / vLightDirection（世界系归一化）
//   vSunHeight / vMoonHeight / vNoonFactor / vNightFactor / vDayFactor（统一时间系统）
//   vDirectIrradiance  大气顶直射辐照度（门控加权和 + 雨天衰减，切换处黑过渡）
//   vDirectTransmittance 相机高度近似的主光源透射率（宏 FULLSCREEN_DIRECT_TRANSMITTANCE 门控）
//   vSkyAmbient       天空环境辐照度基色 = LUT 探针 rgb（天顶色）× SKY_AMBIENT_BRIGHTNESS，
//                     无效回退常量昼夜 mix；雨天去饱和最后并入
//   vHorizon          观察者地平线几何 (cosBeta, beta, zenithHorizon)
//   vSkyLutValid      LUT 有效性（flat float 0/1——bool varying 为补丁器 / 部分驱动不容；
//                     探针 rgb 另作 vSkyAmbient 的天顶色源，fetch 双重职责）
// 依赖先行 include：constants.glsl（TAU / 大气与光照常量、SKYVIEW_*）、uniforms.glsl（光源位置 /
//   sunAngle / rainStrength / cameraPosition / colortex7 / frameCounter / 视口）、utils/space.glsl、
//   utils/noise.glsl（taaJitterUV）、lib/post/exposure.glsl（readAdaptedExposure 及其依赖链）；
//   定义 FULLSCREEN_DIRECT_TRANSMITTANCE 时还需 lib/atmosphere/atmosphere.glsl（opticalDepthToSpace）
#ifndef PROGRAM_FULLSCREEN_VSH_GLSL
#define PROGRAM_FULLSCREEN_VSH_GLSL

#ifdef STAGE_VERTEX

out vec2 vTexCoord;
out vec2 vJitter;
out float vExposure;
out vec3 vSunDirection;
out vec3 vMoonDirection;
out vec3 vLightDirection;
out float vSunHeight;
out float vMoonHeight;
out float vNoonFactor;
out float vNightFactor;
out float vDayFactor;
out vec3 vDirectIrradiance;
#ifdef FULLSCREEN_DIRECT_TRANSMITTANCE
out vec3 vDirectTransmittance;
#endif
out vec3 vSkyAmbient;
out vec3 vHorizon;
flat out float vSkyLutValid;

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
#if defined(FULLSCREEN_RENDER_REGION) && defined(TAAU)
    // TAAU：本 pass（deferred_init）的 quad 缩进与 gbuffers 相同的左下子区域；vTexCoord 同步缩为
    // 子区域物理 uv（fsh 走 texelFetch(gl_FragCoord) 不消费 vTexCoord，缩放仅保持语义一致）。
    // 宏由 world0/deferred 入口定义；composite_taa / final 不定义、quad 全屏
    gl_Position.xy = gl_Position.xy * RENDER_SCALE + (RENDER_SCALE - 1.0) * gl_Position.w;
    vTexCoord *= RENDER_SCALE;
#endif
    vJitter = taaJitterUV();

    float exposure = readAdaptedExposure();
    vExposure = (exposure > 1e-4 && exposure < 1e4) ? exposure : 1.0; // 首帧 / 重载后槽位可能无效，回退中性 1.0

    vSunDirection = normalize(viewToWorldDirection(sunPosition));
    vMoonDirection = normalize(viewToWorldDirection(moonPosition));
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));

    // ---- 统一时间系统（常量依据见 constants.glsl 光照分区）----
    // 太阳 / 月亮各自世界高度的线性门：日月恰好相对、两门永不同时为正，门控加权和即「按光源选边 +
    // 切换瞬间双 0 黑过渡」；晨昏主光源切换的阴影跳变由本黑过渡吸收
    vSunHeight  = sin(sunAngle * TAU);
    vMoonHeight = vMoonDirection.y;
    vNoonFactor  = clamp(vSunHeight  * TIME_NOON_RAMP,  0.0, 1.0);
    vNightFactor = clamp(vMoonHeight * TIME_NIGHT_RAMP, 0.0, 1.0);
    vDayFactor = smoothstep(-0.10, 0.25, vSunHeight); // 慢族：环境光昼夜权重，过渡窗保持原行为

    vDirectIrradiance = (vNoonFactor * SOLAR_IRRADIANCE + vNightFactor * MOON_IRRADIANCE)
                      * (1.0 - 0.75 * rainStrength);

    // 观察者地平线几何（与 sky.glsl 生成端 skyViewLutTexel 同式）：
    // beta = 地平线到天底的角跨度、zenithHorizon = 天顶到地平线的角跨度
    float r = EARTH_RADIUS + max(cameraPosition.y, 1.0);
#ifdef FULLSCREEN_DIRECT_TRANSMITTANCE
    // 用玩家 / 相机高度近似全部可见表面海拔；全屏顶点仅计算 3~4 次，deferred 直接插值复用。
    vDirectTransmittance = exp(-opticalDepthToSpace(r, vLightDirection.y));
#endif
    float altitudeTerm = max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0);
    float cosBeta = sqrt(altitudeTerm) / r;
    float beta = acos(cosBeta);
    vHorizon = vec3(cosBeta, beta, PI - beta);

    // 天空 view LUT 有效性探针：composite12 每帧全量写 alpha 标记，各取半区角 texel（太阳半区
    // 天顶行 (260,100)、月亮半区天顶行 (260,0)）判定整块有效性——无效内容在整片区域同现、单 texel
    // 探针足以拦截；NaN 对比较返回 false、同样落入无效分支。有效性 varying 仅 deferred_init 声明
    // 消费，其余 pass 由链接器剔除
    vec4 skySunProbe  = texelFetch(colortex7, ivec2(SKYVIEW_LUT_ORIGIN_X, SKYVIEW_LUT_H), 0);
    vec4 skyMoonProbe = texelFetch(colortex7, ivec2(SKYVIEW_LUT_ORIGIN_X, 0), 0);
    bool skyLutValid = frameCounter > 0
                && abs(skySunProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && abs(skyMoonProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && all(lessThan(abs(skySunProbe.rgb), vec3(65000.0)))
                && all(lessThan(abs(skyMoonProbe.rgb), vec3(65000.0)));
    vSkyLutValid = skyLutValid ? 1.0 : 0.0;

    // 天空环境基色 = 探针 rgb（两半区天顶行首列——球对称大气下天顶色与方位无关，探针 rgb 即各光源
    // 天顶色精确值）之和 × SKY_AMBIENT_BRIGHTNESS：色调 / 幅度随 LUT 自动跟进（昼夜 / 曙暮光 /
    // 海拔 / MS），与渲染天空同源同帧滞后；两半区和式与 getSkyColor 天顶采样一致（非活动半区写黑
    // 自动零贡献）；LUT 无效回退常量昼夜 mix；雨天去饱和最后并入
    vec3 ambient = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, vDayFactor);
    if (skyLutValid) {
        ambient = (skySunProbe.rgb + skyMoonProbe.rgb) * SKY_AMBIENT_BRIGHTNESS;
    }
    vSkyAmbient = mix(ambient, vec3(dot(ambient, vec3(0.3333))) * vec3(0.90, 0.95, 1.05), rainStrength);
}

#endif

#endif
