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
//   vSunHeight        太阳世界高度 sin(sunAngle·TAU) ∈ [-1,1]（统一时间系统输入）
//   vMoonHeight       月亮世界高度 vMoonDirection.y（MC 日月恰好相对 ≈ -vSunHeight，取实际方向防假设耦合）
//   vNoonFactor       统一时间系统·太阳直射门 clamp(sunHeight×TIME_NOON_RAMP)（春v2 isNoon / 春雷 isDay）
//   vNightFactor      统一时间系统·月亮直射门 clamp(moonHeight×TIME_NIGHT_RAMP)（春v2 / 春雷 isNight）
//   vDayFactor        白天权重（慢族：黄昏 -0.10 ~ 0.25 过渡，环境光昼夜 mix 专用——过渡窗宽于直射门，
//                     不随直射门收紧；即春v2 NOON_DURATION_SLOW 慢族的对应物）
//   vDirectIrradiance 大气顶直射辐照度 = 太阳 / 月亮门控加权和 + 雨天 ×0.25 衰减——主光源切换瞬间
//                     两门同为 0、直射光为黑过渡（春v2 sunColor / 春雷 GetLightIrradianceAtSurface 同构，
//                     替代旧昼夜 mix：mix 在日出前混入太阳辐照度、被低角度透射率染红成「红色太阳光」）
//   vDirectTransmittance 相机高度近似的主光源大气透射率（仅 deferred_init 通过宏启用）
//   vSkyAmbient       天空环境辐照度基色 = 天顶色 × SKY_AMBIENT_BRIGHTNESS：直接复用下方 LUT 探针
//                     的 rgb（texel 恰为两半区天顶行首列、球对称大气下天顶色与方位无关），
//                     色调与幅度一并取自天顶大气结果——昼夜 / 曙暮光 / 相机海拔的量级变化随 LUT
//                     自动跟进，零新增 fetch / 零解析求值、与渲染天空同源同帧滞后；LUT 无效
//                     回退常量昼夜 mix（DAY / NIGHT_SKY_AMBIENT）；雨天去饱和最后并入（去饱和
//                     是 luma 混合，与 shadeSurface 逐像素的 lm/半球标量乘法可交换——dot 对
//                     标量乘满足分配律）
//   vHorizon          观察者地平线几何 (cosBeta, beta, zenithHorizon)——sky.glsl LUT 参数化共用，
//                     只随相机海拔变化（原逐像素 / 逐纹素 sqrt + acos 上移）
//   vSkyLutValid      colortex7 天空 view LUT 有效性（flat float 0/1，仅 deferred_init 消费；
//                     bool 型 varying 为补丁器 / 部分驱动所不容，故用 0/1 编码）——
//                     帧序 + 两半区角 texel 探针（marker / 有限性），原 fsh 逐像素校验上移；
//                     探针 rgb 另作 vSkyAmbient 的天顶色源（fetch 双重职责）
// 依赖先行 include（lib 文件不嵌套 include）：lib/common/globals/constants.glsl（TAU / PI /
// 大气与光照常量、SKYVIEW_*）、lib/common/globals/uniforms.glsl（光源位置 / sunAngle / rainStrength /
// cameraPosition / colortex7 / frameCounter，视口与 frameCounter 经 jitter）、
// lib/common/utils/space.glsl（viewToWorldDirection）、
// lib/common/utils/noise.glsl（taaJitterUV）、lib/post/exposure.glsl（readAdaptedExposure，
// 连带 bloom / color / filters 依赖链）；定义 FULLSCREEN_DIRECT_TRANSMITTANCE 时还需先行 include
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
    vJitter = taaJitterUV();

    float exposure = readAdaptedExposure();
    vExposure = (exposure > 1e-4 && exposure < 1e4) ? exposure : 1.0; // 首帧 / 重载后槽位可能无效，回退中性 1.0

    vSunDirection = normalize(viewToWorldDirection(sunPosition));
    vMoonDirection = normalize(viewToWorldDirection(moonPosition));
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));

    // ---- 统一时间系统（春v2 isNoon/isNight、春雷 isDay/isNight 同构，常量见 constants.glsl）----
    // 太阳 / 月亮各自世界高度的线性门：主光源切换瞬间（光源过地平线）两门同为 0，直射光经门控
    // 加权和为黑过渡。日月恰好相对（moonHeight ≈ -sunHeight），两门永不同时为正——加权和即
    // 「按光源选边 + 切换处淡黑」，无重叠期串扰。晨昏主光源切换的阴影跳变由本黑过渡吸收（辐照度乘 0）
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

    // 天空 view LUT 有效性探针：composite12 每帧对两半区全量写 alpha 标记，各取半区角
    // texel（太阳半区首行 = 天顶行 (260,100)、月亮半区首行 = 天顶行 (260,0)）判定整块
    // 有效性——无效内容（清零色 / 旧格式 / 分配垃圾）在整片区域同现，单 texel 探针足以
    // 拦截。原 fsh 逐像素 NaN / 范围 / marker 校验（~15 op / 天空像素）上移为每 pass
    // 3~4 次探针 + 一个 flat float varying（0/1——bool 型 varying 为补丁器 / 部分驱动
    // 所不容）；NaN 对比较返回 false，落入无效分支同样被拦截。残余风险仅「探针 texel
    // 有效而区域内个别 texel 异常」——生成端 float32 已全面加固，理论可能而已。
    // 有效性 varying 仅 deferred_init 声明消费，其余 pass 由链接器剔除
    vec4 skySunProbe  = texelFetch(colortex7, ivec2(SKYVIEW_LUT_ORIGIN_X, SKYVIEW_LUT_H), 0);
    vec4 skyMoonProbe = texelFetch(colortex7, ivec2(SKYVIEW_LUT_ORIGIN_X, 0), 0);
    bool skyLutValid = frameCounter > 0
                && abs(skySunProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && abs(skyMoonProbe.a - SKYVIEW_LUT_VALID_MARKER) < 1e-3
                && all(lessThan(abs(skySunProbe.rgb), vec3(65000.0)))
                && all(lessThan(abs(skyMoonProbe.rgb), vec3(65000.0)));
    vSkyLutValid = skyLutValid ? 1.0 : 0.0;

    // 天空环境辐照度基色 = 天顶色 × SKY_AMBIENT_BRIGHTNESS：直接复用上方探针的 rgb，色调与
    // 幅度一并取自天顶大气结果——昼 / 夜 / 曙暮光的幅度变化（含 MS 与相机海拔）随 LUT 自动
    // 跟进，免按昼夜 mix 拼装幅度。探针 texel 恰为两半区天顶行首列：球对称大气下天顶色与
    // 方位无关（生成端 skyViewLutTexel 的 vzSin = 0 使方位项从几何中消失，整行求值同一
    // 方向 (0,1,0) 与同一相函数 mu = szCos），探针 rgb 即各光源天顶色的精确值而非近似——
    // 零新增 fetch、零解析求值（解析路线需每光源 skyAmbientField 48 节点求积），且与渲染
    // 天空同源（同一 LUT、同帧滞后），环境光与画面天顶色不漂移、亮度亦随昼夜物理自适应。
    // 两半区和式与 getSkyColor 的天顶采样一致（非活动半区生成端整区写黑、rgb = 0 自动
    // 零贡献，免 SKY_LIGHT_MIN_HEIGHT 再门控），MC 日月恰好相对、任何时刻恰有一侧在
    // 地平线上；LUT 无效（首帧 / 缓冲重建）回退常量昼夜 mix。雨天去饱和最后并入
    //（与逐像素 lm / 半球标量乘法可交换）
    vec3 ambient = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, vDayFactor);
    if (skyLutValid) {
        ambient = (skySunProbe.rgb + skyMoonProbe.rgb) * SKY_AMBIENT_BRIGHTNESS;
    }
    vSkyAmbient = mix(ambient, vec3(dot(ambient, vec3(0.3333))) * vec3(0.90, 0.95, 1.05), rainStrength);
}

#endif

#endif
