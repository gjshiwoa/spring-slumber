// 表面光照（线性空间，直接光物理化——春雷 shading.glsl 同构）
// 全部光项以辐照度（与大气同量级）汇总，最后统一乘 Lambert BRDF = albedo/π：
//   直射 E = vDirectIrradiance（通用全屏 vsh 算好的大气顶辐照度 mix + 雨天衰减）
//           × solarTransmittance(表面点 -> 光源)——大气顶辐照度与天空 LUT 共用同一常量
//           （sky:direct 亮度比物理一致），透射率取逐像素表面海拔，太阳/月亮贴地平线时
//           路径拉长自然泛红归零
//   天空环境光 / 方块光为辐照度形式常数（constants.glsl）；环境基色昼夜 mix 与雨天去饱和
//   已在 vsh 帧数据预并入（去饱和与逐像素标量乘法可交换）
// 阴影贴图范围外 / 晨昏光源切换时回退 skyLight 门控近似（洞内 skyLight 低，阳光进不来）
// 帧数据取用（春v2 模式——lib 函数直接读 program 声明的同名 in varying 全局）：
//   vLightDirection / vSunHeight / vDirectIrradiance / vSkyAmbient——由通用全屏 vsh
//   （program/fullscreen_vsh.glsl）输出，接入方 fsh 须在本文件 include 之前
//   声明同名 in（未来前向 program 如 water 共享本函数时，由其 vsh 输出同名 varying）
// 仅片段阶段（函数体引用阴影采样与大气换算）；依赖由接入的 program 先行 include（lib 文件不嵌套 include）：
//   lib/common/globals/uniforms.glsl、lib/common/globals/constants.glsl（大气常量 / 光照常量 / 阴影常量、PI）、
//   lib/common/utils/space.glsl（viewToWorldDirection / viewToRelativeWorld）、
//   lib/atmosphere/atmosphere.glsl（solarTransmittance）、lib/lighting/shadow.glsl（sampleShadowVisibility）
#ifndef LIB_LIGHTING_GLSL
#define LIB_LIGHTING_GLSL

#ifdef STAGE_FRAGMENT

// 表面光照主入口
// albedo     线性反照率
// normalView 观图空间法线（不要求归一化）
// lm         重映射后的光照图（x = 方块光，y = 天空光），见 common/pipeline/gbuffer_data.glsl remapLightmap
// viewPos    观察空间位置（deferred_init 由去抖 NDC + depthtex1 重建）——函数内部统一换算一次
//            relativeWorldPos（阴影采样 / 距离淡出 / 透射率海拔共用，免重复矩阵乘）
vec3 shadeSurface(vec3 albedo, vec3 normalView, vec2 lm, vec3 viewPos) {
    vec3 normalWorld = normalize(viewToWorldDirection(normalView));
    vec3 lightDirWorld = vLightDirection; // 世界系阴影主光源方向（vsh 帧数据）

    vec3 relativeWorldPos = viewToRelativeWorld(viewPos);
    float distWorld = length(relativeWorldPos);

    // 直射光可见性：阴影贴图 PCF（背光面 ndl <= 0 直接全影，免采样）
    float ndl = dot(normalWorld, lightDirWorld);
    vec3 shadowVis = ndl > 0.0 ? sampleShadowVisibility(relativeWorldPos, normalWorld, ndl, distWorld)
                               : vec3(0.0);

    // 回退门控：超 shadowDistance（贴图覆盖不到）或晨昏光源切换（|sunHeight| 小，太阳 / 月亮方向翻转、
    // 阴影会跳变）时退回 skyLight 门控近似
    float distFade = smoothstep(SHADOW_FADE_BEGIN * shadowDistance, shadowDistance, distWorld);
    float timeFade = 1.0 - smoothstep(0.0, 0.10, abs(vSunHeight));
    float directGate = smoothstep(0.50, 0.95, lm.y);
    vec3 visibility = mix(shadowVis, vec3(directGate), max(distFade, timeFade));

    // 直射辐照度：vsh 帧数据基色（大气顶辐照度 mix + 雨天衰减，全屏一次算好）× 表面点 ->
    // 光源方向的大气透过率。大气球对称，透过率只取决于海拔与方向——origin 取
    // (0, R + 表面海拔, 0)（逐像素：相机绝对海拔 + 相对世界 y），山巅比谷底少穿一层大气；
    // 光源贴地平线路径拉长自然泛红归零（月出月落同样修色，与天空 LUT 月亮半区同一物理）
    vec3 surfaceOrigin = vec3(0.0, EARTH_RADIUS + max(cameraPosition.y + relativeWorldPos.y, 1.0), 0.0);
    vec3 directIrradiance = vDirectIrradiance * solarTransmittance(surfaceOrigin, lightDirWorld);

    // 天空环境光：上半球亮、下半球暗的半球近似（辐照度形式）；昼夜 mix 与雨天去饱和
    // 已在 vsh 帧数据基色预并入（与逐像素标量乘法可交换，数学等价）
    float hemisphere = 0.6 + 0.4 * clamp(normalWorld.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyIrradiance = vSkyAmbient * (pow(lm.y, 1.5) * hemisphere);

    // 方块光（火把、萤石等），近距离衰减用幂曲线近似（辐照度形式）
    vec3 blockIrradiance = TORCHLIGHT_COLOR * (pow(lm.x, 2.2) * 1.30 + lm.x * 0.02);

    // Lambert BRDF = albedo/π，全部辐照度一次相乘
    return (albedo / PI) * (directIrradiance * (max(ndl, 0.0) * visibility)
                          + skyIrradiance + blockIrradiance + MIN_AMBIENT);
}

#endif

#endif
