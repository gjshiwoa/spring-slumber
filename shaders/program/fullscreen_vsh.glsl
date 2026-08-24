// 通用全屏 vsh pass——标准 fullscreen quad 的 deferred / composite / final pass 共用的顶点着色器
//（参考春v2 各全屏 vsh 的 sunWorldDir / moonWorldDir / lightWorldDir / isNoon / isNight / sunColor /
// skyColor 一族 varying）：凡「逐帧恒定、全屏一致」的量在 main 内一次算好、经 out varying 传入 fsh，
// 替代 fsh 逐像素重复求值——全屏 quad 只有 3~4 个顶点、各顶点写同值，透视矫正插值精确还原，
// 原先 deferred_init 天空 / 光照分支逐像素的 normalize(mat3×) / sin / smoothstep / sqrt / acos
// 每帧数百万次收敛为每帧 3~4 次
// 接入方式：program 平铺 include 本文件（fsh 编译时 STAGE_VERTEX 未定义、展开为空），
// program 自身的 vsh 段删除；fsh 按需声明同名 in（vsh 输出、fsh 未声明的 varying 由链接器剔除，
// 零运行时成本）。带自定义 vsh 的 pass（bloom 链的 quad 压缩等）不适用本 pass，其 fsh 需要
// 帧数据时在自身 vsh 内输出同名 varying 即可
// 输出清单：
//   vTexCoord         全屏 uv
//   vJitter           当前帧 TAA jitter（uv 域）——deferred_init 去抖基底 / composite_taa 解析共用
//   vExposure         colortex7 曝光槽位的自适应曝光（无效值回退 1.0——首帧 / 重载后槽位可能为清零色）
//   vSunDirection     太阳方向（世界系 = 玩家对齐系，+Y 朝上，归一化）
//   vMoonDirection    月亮方向（世界系，与太阳恰好相对——白天沉于地平线下，月亮半区自然归零）
//   vLightDirection   阴影主光源方向（白天太阳 / 夜晚月亮，shadowLightPosition，世界系归一化）
//   vSunHeight        太阳世界高度 sin(sunAngle·TAU) ∈ [-1,1]
//   vDayFactor        白天权重（黄昏 -0.10 ~ 0.25 过渡）
//   vDirectIrradiance 大气顶直射辐照度 = mix 太阳 / 月亮辐照度 + 雨天 ×0.25 衰减
//   vDirectTransmittance 相机高度近似的主光源大气透射率（仅 deferred_init 通过宏启用）
//   vSkyAmbient       天空环境辐照度基色 = 昼夜 mix + 雨天去饱和预并入（去饱和是 luma 混合，与
//                     shadeSurface 逐像素的 lm/半球标量乘法可交换——dot 对标量乘满足分配律，
//                     先去饱和后乘 == 原先先乘后去饱和）
//   vHorizon          观察者地平线几何 (cosBeta, beta, zenithHorizon)——sky.glsl LUT 参数化共用，
//                     只随相机海拔变化（原逐像素 / 逐纹素 sqrt + acos 上移）
//   vSkyLutValid      colortex7 天空 view LUT 有效性（flat float 0/1，仅 deferred_init 消费；
//                     bool 型 varying 为 OpenGL 补丁器 / 部分驱动所不容，故用 0/1 编码）——
//                     帧序 + 两半区角 texel 探针（marker / 有限性），原 fsh 逐像素校验上移
// 依赖先行 include（lib 文件不嵌套 include）：lib/common/globals/constants.glsl（TAU / PI /
// 大气与光照常量、SKYVIEW_*）、lib/common/globals/uniforms.glsl（光源位置 / sunAngle / rainStrength /
// cameraPosition / colortex7 / frameCounter，视口与 frameCounter 经 jitter）、
// lib/common/utils/space.glsl（viewToWorldDirection）、
// lib/common/utils/jitter.glsl（taaJitterUV）、lib/post/exposure.glsl（readAdaptedExposure，连带
// bloom / color / filters 依赖链）；定义 FULLSCREEN_DIRECT_TRANSMITTANCE 时还需先行 include
// lib/atmosphere/atmosphere.glsl（opticalDepthToSpace）
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
    vJitter = taaJitterUV();

    float exposure = readAdaptedExposure();
    vExposure = (exposure > 1e-4 && exposure < 1e4) ? exposure : 1.0; // 首帧 / 重载后槽位可能无效，回退中性 1.0

    vSunDirection = normalize(viewToWorldDirection(sunPosition));
    vMoonDirection = normalize(viewToWorldDirection(moonPosition));
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));

    vSunHeight = sin(sunAngle * TAU);
    vDayFactor = smoothstep(-0.10, 0.25, vSunHeight);

    vDirectIrradiance = mix(MOON_IRRADIANCE, SOLAR_IRRADIANCE, vDayFactor) * (1.0 - 0.75 * rainStrength);

    vec3 ambient = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, vDayFactor);
    vSkyAmbient = mix(ambient, vec3(dot(ambient, vec3(0.3333))) * vec3(0.90, 0.95, 1.05), rainStrength);

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

    // 天空 view LUT 有效性探针：composite12 每帧对两半区全量写 alpha 标记，各取半区角
    // texel（太阳半区首行 (260,100)、月亮半区首行 (260,0)）判定整块有效性——无效内容
    //（清零色 / 旧格式 / 分配垃圾）在整片区域同现，单 texel 探针足以拦截。原 fsh 逐像素
    // NaN / 范围 / marker 校验（~15 op / 天空像素）上移为每 pass 3~4 次探针 + 一个 flat
    // float varying（0/1——bool 型 varying 为补丁器 / 部分驱动所不容）；NaN 对比较返回
    // false，落入无效分支同样被拦截。残余风险仅「探针 texel 有效而区域内个别 texel 异常」
    // ——生成端 float32 已全面加固，理论可能而已。
    // 仅 deferred_init 声明消费本 varying，其余 pass 由链接器剔除、探针成死代码
    vec4 skySunProbe  = texelFetch(colortex7, ivec2(SKYVIEW_LUT_ORIGIN_X, SKYVIEW_LUT_H), 0);
    vec4 skyMoonProbe = texelFetch(colortex7, ivec2(SKYVIEW_LUT_ORIGIN_X, 0), 0);
    bool skyLutValid = frameCounter > 0
                && abs(skySunProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && abs(skyMoonProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && all(lessThan(abs(skySunProbe.rgb), vec3(65000.0)))
                && all(lessThan(abs(skyMoonProbe.rgb), vec3(65000.0)));
    vSkyLutValid = skyLutValid ? 1.0 : 0.0;
}

#endif

#endif
