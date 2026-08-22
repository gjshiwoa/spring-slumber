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
//   vDirectIrradiance 大气顶直射辐照度 = mix 太阳 / 月亮辐照度 + 雨天 ×0.25 衰减（表面点海拔的
//                     solarTransmittance 仍逐像素——透射率依赖表面海拔，不可上移）
//   vSkyAmbient       天空环境辐照度基色 = 昼夜 mix + 雨天去饱和预并入（去饱和是 luma 混合，与
//                     shadeSurface 逐像素的 lm/半球标量乘法可交换——dot 对标量乘满足分配律，
//                     先去饱和后乘 == 原先先乘后去饱和）
//   vHorizon          观察者地平线几何 (cosBeta, beta, zenithHorizon)——sky.glsl LUT 参数化共用，
//                     只随相机海拔变化（原逐像素 / 逐纹素 sqrt + acos 上移）
// 依赖先行 include（lib 文件不嵌套 include）：lib/common/globals/constants.glsl（TAU / PI /
// 大气与光照常量）、lib/common/globals/uniforms.glsl（光源位置 / sunAngle / rainStrength /
// cameraPosition、视口与 frameCounter 经 jitter）、lib/common/utils/space.glsl（viewToWorldDirection）、
// lib/common/utils/jitter.glsl（taaJitterUV）、lib/post/exposure.glsl（readAdaptedExposure，连带
// bloom / color / filters 依赖链）
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
out vec3 vSkyAmbient;
out vec3 vHorizon;

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
    float altitudeTerm = max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0);
    float cosBeta = sqrt(altitudeTerm) / r;
    float beta = acos(cosBeta);
    vHorizon = vec3(cosBeta, beta, PI - beta);
}

#endif

#endif
