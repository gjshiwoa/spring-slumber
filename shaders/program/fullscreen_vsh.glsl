// 通用全屏 vsh——deferred_init / composite_fog / composite_taa / final 共用的顶点着色器（参考春v2
// 全屏 vsh 的
// 帧数据 varying 族）：凡「逐帧恒定、全屏一致」的量在 main 内一次算好、经 out varying 传入 fsh
//（全屏 quad 仅 3~4 顶点、透视矫正插值精确）。接入方式：program 平铺 include（内容 STAGE_VERTEX
// 自守卫、fsh 编译展开为空）；fsh 按需声明同名 in（未声明的由链接器剔除、零成本）；带自定义 vsh
// 的 pass（bloom 链 quad 压缩）不适用，需要帧数据时在自身 vsh 输出同名 varying
// 输出清单（详细语义见各 consuming 侧与 AGENTS.md「通用全屏 vsh」条）：
//   vTexCoord / vJitter / vExposure（无效值回退 1.0）
//   vSunDirection / vMoonDirection / vLightDirection（世界系归一化）
//   vSunHeight / vMoonHeight / vNoonFactor / vNightFactor（统一时间系统；环境回退的慢族昼夜
//                     权重随 vSkyAmbient 取值实现移入 lib/lighting/ambient.glsl，无独立 varying）
//   vDirectIrradiance  大气顶直射辐照度（门控加权和 + 雨天衰减，切换处黑过渡）
//   vDirectTransmittance 相机高度近似的主光源透射率（宏 FULLSCREEN_DIRECT_TRANSMITTANCE 门控）
//   vCloudTransmittance 云层海拔处的主光源透射率（宏 FULLSCREEN_CLOUD_TRANSMITTANCE 门控，
//                     CLOUDS_2D 时由 deferred_init 定义）：云的直射光着色用——相机无关（云受光
//                     由云自身海拔决定），日落时云比地面晚变红（高处光学深度小）
//   vSkyAmbient       天空环境辐照度基色 = LUT 探针 rgb（天顶色）× SKY_AMBIENT_BRIGHTNESS，
//                     无效回退常量昼夜 mix；雨天去饱和最后并入——取值实现 lib/lighting/ambient.glsl
//                     （skyAmbientColor，与前向 program〔简单半透明等〕的 vsh 共用同一实现）
//   vHorizon          观察者地平线几何 (cosBeta, beta, zenithHorizon)
//   vSkyLutValid      LUT 有效性（flat float 0/1——bool varying 为补丁器 / 部分驱动不容；
//                     探针 rgb 另作 vSkyAmbient 的天顶色源，fetch 双重职责）
// 依赖先行 include：constants.glsl（TAU / 大气与光照常量、SKYVIEW_*、CLOUDS_2D 开时的
//   CLOUDS_2D_HEIGHT）、uniforms.glsl（光源位置 / sunAngle / rainStrength / cameraPosition /
//   colortex7 / frameCounter / 视口）、utils/space.glsl、utils/noise.glsl（taaJitterUV）、
//   lib/lighting/ambient.glsl（skyAmbientColor / frameDirectIrradiance / observerHorizonGeometry——
//   vDirectIrradiance 与 vHorizon 的取值实现，各「自带 vsh 输出同名 varying」的 pass 共用单真源）、
//   lib/post/exposure.glsl（readAdaptedExposure
//   及其依赖链）；定义 FULLSCREEN_DIRECT_TRANSMITTANCE
//   或 FULLSCREEN_CLOUD_TRANSMITTANCE 时还需 lib/atmosphere/atmosphere.glsl（opticalDepthToSpace）
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
out vec3 vDirectIrradiance;
#ifdef FULLSCREEN_DIRECT_TRANSMITTANCE
out vec3 vDirectTransmittance;
#endif
#ifdef FULLSCREEN_CLOUD_TRANSMITTANCE
out vec3 vCloudTransmittance;
#endif
out vec3 vSkyAmbient;
out vec3 vHorizon;
flat out float vSkyLutValid;

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
#if defined(FULLSCREEN_RENDER_REGION) && (defined(TAAU) || defined(SR_UPSCALE))
    // TAAU / SR 超分：本 pass（deferred_init / composite_fog 边界雾）的 quad 缩进与 gbuffers 相同的左下
    // 子区域；vTexCoord 同步缩为子区域物理 uv（fsh 走 texelFetch(gl_FragCoord) 不消费 vTexCoord，缩放仅保持
    // 语义一致）。宏由 world0/deferred1 与 world0/composite2 入口定义；composite_taa / final 不定义、
    // quad 全屏（SR 接管时 composite3 透传 SR 已写回的全屏 upscaled 色彩，同样保持全屏 quad）
    vec2 regionScale = renderRegionScale();
    gl_Position.xy = gl_Position.xy * regionScale + (regionScale - 1.0) * gl_Position.w;
    vTexCoord *= regionScale;
#endif
    vJitter = taaJitterUV();

    float exposure = readAdaptedExposure();
    vExposure = (exposure > 1e-4 && exposure < 1e4) ? exposure : 1.0; // 首帧 / 重载后槽位可能无效，回退中性 1.0

    vSunDirection = normalize(viewToWorldDirection(sunPosition));
    vMoonDirection = normalize(viewToWorldDirection(moonPosition));
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));

    // ---- 统一时间系统（常量依据见 constants.glsl 光照分区；门控加权和的取值实现 =
    // lib/lighting/ambient.glsl 的 frameDirectIrradiance，与前向 program / composite12 云烘焙
    // 的自带 vsh 单真源共用——「同名同式」由函数共用结构性保证）----
    vSunHeight  = sin(sunAngle * TAU);
    vMoonHeight = vMoonDirection.y;
    vNoonFactor  = clamp(vSunHeight  * TIME_NOON_RAMP,  0.0, 1.0);
    vNightFactor = clamp(vMoonHeight * TIME_NIGHT_RAMP, 0.0, 1.0);
    vDirectIrradiance = frameDirectIrradiance(vSunHeight, vMoonHeight);

    // 观察者地平线几何（与 sky.glsl 生成端 skyViewLutTexel 同式，取值实现 = ambient.glsl 的
    // observerHorizonGeometry——本 vsh / gbuffers_translucent 的自带 vsh / composite12 LUT 生成端
    // 三处共用单真源）：beta = 地平线到天底的角跨度、zenithHorizon = 天顶到地平线的角跨度
    float r = EARTH_RADIUS + max(cameraPosition.y, 1.0);
#ifdef FULLSCREEN_DIRECT_TRANSMITTANCE
    // 用玩家 / 相机高度近似全部可见表面海拔；全屏顶点仅计算 3~4 次，deferred 直接插值复用。
    vDirectTransmittance = exp(-opticalDepthToSpace(r, vLightDirection.y));
#endif
#ifdef FULLSCREEN_CLOUD_TRANSMITTANCE
    // 云层海拔处的主光源透射率：半径取云层而非相机——云受光由云自身海拔决定（相机再高也不变）；
    // 与 vDirectTransmittance 同式同源，日落时云比地面更晚变红（高处光学深度小）
    vCloudTransmittance = exp(-opticalDepthToSpace(EARTH_RADIUS + CLOUDS_2D_HEIGHT, vLightDirection.y));
#endif
    vHorizon = observerHorizonGeometry();

    // 天空 view LUT 有效性探针 + 天空环境基色（取值实现 lib/lighting/ambient.glsl 的 skyAmbientColor，
    // 与前向 program〔简单半透明〕的 vsh 共用同一实现）：探针 fetch 双重职责——rgb = 各光源天顶色作
    // vSkyAmbient 源、alpha 有效性标记作 vSkyLutValid（无效回退常量昼夜 mix、雨天去饱和在 lib 内并
    // 入）；有效性 varying 仅 deferred_init 声明消费，其余 pass 由链接器剔除
    float skyLutValid;
    vSkyAmbient = skyAmbientColor(skyLutValid);
    vSkyLutValid = skyLutValid;
}

#endif

#endif
