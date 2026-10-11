// 帧数据取值实现（skyAmbientColor / frameDirectIrradiance / observerHorizonGeometry）+ 前向简单
// 光照（forwardLightmapShade / forwardEntityShade，含单 tap 硬阴影读取端 shadowTex1HardVisibility）
// ——skyAmbientColor 由通用全屏 vsh（fullscreen_vsh）与前向 program（gbuffers_translucent_simple）
// 各自的 vsh 共用：colortex7 天空 LUT 两半区天顶行探针 fetch 双重职责——rgb = 各光源天顶色精确值
//（球对称大气下天顶色与方位无关）、alpha = 有效性标记；有效取 (太阳 + 月亮) × SKY_AMBIENT_BRIGHTNESS
//（与 getSkyColor 天顶采样同式、非活动半区写黑自动零贡献，色调 / 幅度随 LUT 自动跟进：昼夜 / 曙暮光 /
// 海拔 / MS，与渲染天空同源同帧滞后），无效回退常量昼夜 mix；雨天去饱和最后并入。lutValid out 参数即
// vSkyLutValid 的判定源（不消费的调用方丢弃）。frameDirectIrradiance / observerHorizonGeometry 是
// vDirectIrradiance / vHorizon 两帧数据的取值实现——通用全屏 vsh 与「自带 vsh 输出同名 varying」的
// 前向 program（gbuffers_translucent / gbuffers_opaque_entities）及 composite12 的 LUT 生成端 /
// 云烘焙帧数据此前在各 vsh 手抄同式（「同名同式」靠人肉成对维护），2026-10 收敛为单真源、由共用
// 结构性保证
// 依赖先行 include：lib/common/globals/uniforms.glsl（colortex7 / frameCounter / sunAngle /
//   rainStrength / cameraPosition——observerHorizonGeometry；shadowTex1HardVisibility 另消费
//   shadowtex1；forwardEntityShade 另消费 shadowDistance）+ lib/common/globals/constants.glsl
//   （TAU / SKYVIEW_* / SKYVIEW_LUT_VALID_MARKER / SKY_AMBIENT_BRIGHTNESS / 昼夜回退常量 /
//   TORCHLIGHT_* / MIN_AMBIENT / FORWARD_LIGHTMAP_BRIGHTNESS（forwardLightmapShade 亮度倍率）/
//   PI / EARTH_RADIUS / TIME_NOON_RAMP / TIME_NIGHT_RAMP /
//   SOLAR_IRRADIANCE / MOON_IRRADIANCE——帧数据两函数；末地另需 END_SKY_AMBIENT（skyAmbientColor
//   的 END 早退）；forwardEntityShade / shadowTex1HardVisibility 另需 SHADOW_BIAS_* /
//   shadowMapResolution）+ utils/space.glsl（relativeWorldToShadowScreen——shadowTex1HardVisibility /
//   forwardEntityShade；viewToWorldDirection / viewToRelativeWorld 仅 forwardEntityShade）
//   ——现有全部消费方（含通用全屏 vsh 与 lib/water/surface.glsl 的接入方）的平铺顺序均已满足
#ifndef LIB_LIGHTING_AMBIENT_GLSL
#define LIB_LIGHTING_AMBIENT_GLSL

// 返回天空环境辐照度基色；lutValid = 探针判定的 LUT 有效性（0/1）
vec3 skyAmbientColor(out float lutValid) {
#ifdef END
    // 末地专用天光（2026-10）：末地 has_skylight = true（原版 skylight 15、开阔 lm.y ≈ 1），环境光项
    // vSkyAmbient × lm.y⁴ 在末地活着，而天空 LUT 本维度不生成——下方主路径会回退主世界白天天空色
    // DAY_SKY_AMBIENT（亮蓝）=「末地天光蓝蓝的、非常亮」的根因；改供 END_SKY_AMBIENT 常量（= 末地
    // 天色 × π、与天空亮度结构性同比例，见 constants.glsl 末地天光段），无 LUT / 探针依赖、首帧即
    // 正确。lutValid 恒 1：末地无 LUT 读者（deferred_init 天空分支 / composite_fog 编译剔除、water
    // 反射走 DIMENSION_SKY_COLOR 常量路径），值仅保 out 签名
    lutValid = 1.0;
    return END_SKY_AMBIENT;
#else
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
#endif
}

// 统一时间系统的门控加权和直射辐照度（vDirectIrradiance 的取值实现，任意阶段可用——vsh 意图）：
// 太阳 / 月亮各自世界高度的线性门（日月恰好相对、两门永不同时为正，门控加权和即「按光源选边 +
// 切换瞬间双 0 黑过渡」；晨昏主光源切换的阴影跳变由本黑过渡吸收）+ 雨天衰减。入参 = 两光源世界
// 高度（sunHeight 恒取 sin(sunAngle·TAU) 的时间门高度、moonHeight 取月亮世界方向 y——与
// fullscreen_vsh 的 vSunHeight / vMoonHeight 同源）。消费方：通用全屏 vsh、gbuffers_translucent /
// gbuffers_opaque_entities 的自带 vsh、composite12 云天空盒烘焙帧数据（此前四处手抄同式）
vec3 frameDirectIrradiance(float sunHeight, float moonHeight) {
    float noonFactor  = clamp(sunHeight  * TIME_NOON_RAMP,  0.0, 1.0);
    float nightFactor = clamp(moonHeight * TIME_NIGHT_RAMP, 0.0, 1.0);
    return (noonFactor * SOLAR_IRRADIANCE + nightFactor * MOON_IRRADIANCE)
         * (1.0 - 0.75 * rainStrength);
}

// 观察者地平线几何 (cosBeta, beta, zenithHorizon)：beta = 地平线到天底的角跨度、zenithHorizon =
// 天顶到地平线的角跨度（与 sky.glsl 生成端 skyViewLutTexel 同式——观察者半径取相机 / 玩家海拔
// 近似）。消费方：通用全屏 vsh（vHorizon）、gbuffers_translucent 的自带 vsh、composite12 LUT
// 生成端（vSkyHorizon——此前三处手抄同式）；采样端经帧数据 varying 透传，不重复求值
vec3 observerHorizonGeometry() {
    float r = EARTH_RADIUS + max(cameraPosition.y, 1.0);
    float altitudeTerm = max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0);
    float cosBeta = sqrt(altitudeTerm) / r;
    float beta = acos(cosBeta);
    return vec3(cosBeta, beta, PI - beta);
}

// 水下物体彩色吸收与独立亮度补偿（地形 / 前向实体 / 简单半透明共用单真源）。
// lmSky 为 remapLightmap 后的物体天光级，不是眼位 eyeBrightnessSmooth；
// 与焦散 pow2 天光门互补：满天光无额外吸收，深水低天光更偏蓝青。
// 只调物体最终着色，不调雾色；composite_fog 的眼到物体距离吸收保留，二者分工。
// 依赖 constants（WATER_FOG / WATER_FOG_COLOR / WATER_UW_SURFACE_ABSORPTION /
// WATER_UW_SURFACE_BRIGHTNESS），返回有效颜色倍率（含补偿，不是纯透射率）。
// 与 uniforms（isEyeInWater），均由 program 先行平铺 include。
vec3 underwaterSurfaceColorScale(float lmSky) {
#ifdef WATER_FOG
    if (isEyeInWater == 1) {
        float skyLight = clamp(lmSky, 0.0, 1.0);
        float absorption = (1.0 - skyLight * skyLight) * WATER_UW_SURFACE_ABSORPTION;
        return exp(-(vec3(1.0) - WATER_FOG_COLOR) * absorption) * WATER_UW_SURFACE_BRIGHTNESS;
    }
#endif
    return vec3(1.0);
}

// 前向简单光照（光照图轻量着色）：前向半透明的「deferred 之后」路径消费——各项与
// shadeSurface 的环境 / 方块光项逐项同源（辐照度形式），无直射 / 阴影 / 法线（阳光下略暗于
// 受光地形，春v2 同取舍；夜视项不接——shadeSurface 亦无、避免与地形观感分叉，接的话两侧成对
// 加）。lm 为 remapLightmap 后的值；半球项取 1 = 向上表面档（粒子 / 雨雪无法线，最亮参考档与受光
// 地面衔接）。整体 × FORWARD_LIGHTMAP_BRIGHTNESS（constants.glsl，2026-10 按反馈「玻璃 / 雨雾
// 有些暗」接入——无直射项路径的观感提亮旋钮，覆盖本函数全部调用方：玻璃等非水分支 + 简单半透明
// 两档；forwardEntityShade 不受影响）
vec3 forwardLightmapShade(vec3 albedoLinear, vec2 lm, vec3 skyAmbient) {
    vec2 lmPow4 = lm * lm; // 两分量平方再平方、免 pow 调用
    lmPow4 *= lmPow4;
    vec3 irradiance = skyAmbient * lmPow4.y
                    + TORCHLIGHT_COLOR * (lmPow4.x * TORCHLIGHT_NEAR_SCALE + lm.x * TORCHLIGHT_FLOOR_SCALE)
                    + MIN_AMBIENT;
    return (albedoLinear / PI) * irradiance * FORWARD_LIGHTMAP_BRIGHTNESS
         * underwaterSurfaceColorScale(lm.y);
}

#ifdef STAGE_FRAGMENT

// shadowtex1 单 tap 硬判定可见性（最简档，2026-10 自两处复制收敛为单真源）：水面直射门控
//（lib/water/surface.glsl 的 shadeWaterSurface）与实体前向直射（下方 forwardEntityShade）共用的
// 读取端——「同款最简档」由单真源结构性保证。shadowOrigin 为相对世界系采样起点（**已含调用方的
// normal offset**——两消费方的 offset 形式各异：水面按世界 up 固定小偏移、实体按坡度缩放，语义
// 差异留在调用方）；tex1 只含不透明几何（水面 / 玻璃等半透明遮挡不细究、按全亮放行），出屏 /
// 超距门控同样在调用方（本函数只管「shadow 屏幕坐标 → 精确纹素 step 比较」，出屏按全亮——贴图
// 覆盖外无内容）。不复用 sampleShadowVisibility（6~12 tap PCF + 彩色阴影 + SS trace 对前向逐像素
// 过重；软影 / 彩影为升级点，include shadow.glsl 换调用即得）。硬边无软化、交 TAA 时间累积
float shadowTex1HardVisibility(vec3 shadowOrigin) {
    float distortFactor;
    vec3 shadowPos = relativeWorldToShadowScreen(shadowOrigin, distortFactor);
    if (any(notEqual(clamp(shadowPos.xy, 0.0, 1.0), shadowPos.xy))) return 1.0; // 出屏：贴图外无内容
    ivec2 texel = clamp(ivec2(shadowPos.xy * float(shadowMapResolution)),
                        ivec2(0), ivec2(shadowMapResolution - 1));
    return step(shadowPos.z - SHADOW_BIAS_DEPTH, texelFetch(shadowtex1, texel, 0).r);
}

// 前向简单光照（直射 + 天光档，2026-10 接入）：实体「deferred 之后」分支（gbuffers_opaque_entities）
// 专供——粒子 / 雨雪等无法线几何不适用（仍走 forwardLightmapShade 的半球 = 1 最亮档）。三项与
// shadeSurface 逐项同源（辐照度形式，实体无 SSS 标记〔半透明混合类纪律〕恒 max(ndl, 0)）：
//   直射 = directIrradiance × directTransmittance × NdotL × 阴影可见性（帧数据由接入方 vsh 输出，
//         与通用全屏 vsh 同名同式——Iris 拆分实体绘制时「前 deferred 实体（延迟光照）」与
//         「后 deferred 实体（本函数）」同屏，日落红化 / 量级一致才不穿帮）
//   天光 = skyAmbient × lm.y⁴ × 半球近似（shadeSurface 同式）；方块光 / 地板与 forwardLightmapShade 同式
// 阴影可见性 = **shadowtex1 单 tap 最简硬判定**（水面直射门控同款，lib/water/surface.glsl——
// 不复用 sampleShadowVisibility：6~12 tap PCF + 彩色阴影三分支 + SS trace 对前向逐像素过重；
// 软影 / 彩色阴影是升级点，include shadow.glsl 换调用即得）。tex1 只含不透明几何：半透明实体
// 多不在其中（水同款），在其中的实体由 normal offset（sampleShadowVisibility 同式斜率缩放）+
// SHADOW_BIAS_DEPTH 防自阴影痤疮；玻璃等透射遮挡不细究（按全亮放行）；超 shadowDistance / 出屏
// 按全亮。硬边无软化、交 TAA 时间累积。lm 为 remapLightmap 后的值；normalView 观察空间法线
//（gbufferViewNormal 出口——导数法线或 labPBR 贴图法线，未过 gbuffer 编解码往返故入口就地归一）
vec3 forwardEntityShade(vec3 albedoLinear, vec3 normalView, vec2 lm, vec3 viewPos,
                        vec3 lightDirWorld, vec3 directIrradiance, vec3 directTransmittance,
                        vec3 skyAmbient) {
    vec3 normalWorld = normalize(viewToWorldDirection(normalView)); // mat3 纯旋转，但入口未保证单位长

#ifndef DIM_NO_DIRECT_LIGHT
    vec3 relativeWorldPos = viewToRelativeWorld(viewPos);
    // 与延迟地形 / 水面一致：实际眼点距离，不是玩家相对原点距离。
    float distWorld = length(viewPos);

    // 直射可见性（单 tap；背光面 ndl ≤ 0 直射本就为 0、免 fetch）：normal offset 取
    // sampleShadowVisibility 同式斜率缩放（距离 + 背光坡度放大），起点构造后交单 tap 读取端
    float ndl = dot(normalWorld, lightDirWorld);
    float sunVis = 1.0;
#ifndef DIM_NO_SHADOW
    if (ndl > 0.0 && distWorld <= shadowDistance) {
        vec3 shadowOrigin = relativeWorldPos
                          + normalWorld * (SHADOW_BIAS_NORMAL * (1.0 + distWorld * 0.01)
                                           * (2.0 - clamp(ndl, 0.0, 1.0)));
        sunVis = shadowTex1HardVisibility(shadowOrigin);
    }
#endif
    // 无阴影贴图但保留直射（DIM_NO_SHADOW 单独成立时）：sunVis 恒 1——现无维度落在该组合
    //（下界 / 末地直射已被 DIM_NO_DIRECT_LIGHT 整段剔除，见下方 #else）

    // 天光门（shadeSurface 同窗同式含 pow4 整形，constants.glsl 直射天光门分区）：实体在洞穴 /
    // 深室内与地形同门不吃直射，Iris 拆分绘制时前后 deferred 实体行为一致
    float skyGate = smoothstep(DIRECT_SKYLIGHT_GATE_LOW, DIRECT_SKYLIGHT_GATE_HIGH, lm.y);
    skyGate *= skyGate;
    skyGate *= skyGate;
    vec3 directTerm = directIrradiance * directTransmittance * skyGate * (max(ndl, 0.0) * sunVis);
#else
    // 维度无天光（DIM_NO_DIRECT_LIGHT，下界 / 末地，2026-10）：直射项整段编译剔除（shadeSurface
    // 同纪律——此前只经天光门乘零，实机反馈下界疑似直射漏光后改结构性为零）；单 tap 阴影 / wrap
    // 余弦 / 天光门全免，lightDirWorld / directIrradiance / directTransmittance 入参成死参
    vec3 directTerm = vec3(0.0);
#endif

    vec2 lmPow4 = lm * lm;
    lmPow4 *= lmPow4;
    float hemisphere = 0.6 + 0.4 * clamp(normalWorld.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 irradiance = directTerm
                    + skyAmbient * (lmPow4.y * hemisphere)
                    + TORCHLIGHT_COLOR * (lmPow4.x * TORCHLIGHT_NEAR_SCALE + lm.x * TORCHLIGHT_FLOOR_SCALE)
                    + MIN_AMBIENT;
    return (albedoLinear / PI) * irradiance * underwaterSurfaceColorScale(lm.y);
}

#endif

#endif
