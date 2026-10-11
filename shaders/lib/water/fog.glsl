// 水雾（仅片段阶段，`WATER_FOG` 宏门控；2026-10 自 lib/lighting/water.glsl 按功能拆分，git 历史
// 含合并形态；方案移植自春v2 waterFog / deferred21 同式）：两路同源——①水上视角 = 水面 fsh 内的
// 彩色吸收 + 满深 mix（lib/water/surface.glsl 的 shadeWaterSurface 水雾段消费本文件 waterFogLitColor）；
// ②水下视角 = composite_fog 的 applyUnderwaterFog 整屏吸收（isEyeInWater == 1 分支，按 depthtex0
// 表面距离结算——水面像素的水下观视〔折射 / Fresnel〕已在 gbuffers_water 处理，两路不重复计雾）。
// 物体入射光的水深代理吸收另在 lighting/ambient.glsl 的 underwaterSurfaceColorScale
// 按物体 lm.y 结算；本文件保留眼到物体的距离吸收，雾色不重复乘该天光吸收。
// 2026-10-08 水下雾亮度从 1/9 → 1/15 → 1/18；太阳项也独立调暗。
// 直接观视与反射命中段共用参数，水上亮度不变；共用基色按反馈略偏绿。
// 基色两路共用 `WATER_FOG_COLOR`、亮度与天空项系数按路径取常量（水上 WATER_FOG_BRIGHTNESS /
// WATER_FOG_SKY_SCALE，水下 WATER_UW_FOG_BRIGHTNESS / WATER_UW_SKY_SCALE，2026-10 分离——水下雾
// 偏白偏灰的调参：白太阳项主导时蓝项占比过低）。
// **水下雾环境光门（2026-10「无光水下雾依然很亮」修复）**：`waterUwEnvLight` = eyeBrightnessSmooth
// 的天光分量归一后经「幂 + 地板」整形（天光分量承载直射 / 天空两项的位置遮挡——洞窟 / 深水 / 桥影
// 下衰减到 0；时间维度不在此：天光级夜间不降，昼夜量级由 vDirectIrradiance / vSkyAmbient 帧级
// varying 自带；**方块光分量不参与**——火把 / 海晶灯的暖色雾照未建模，max 混入只会让光源旁雾色
// 凭空偏亮，方块光暖色贡献为扩展点、接入时单建一项），乘进 applyUnderwaterFog 与
// waterReflectionHitFog 水下分支的雾色——雾色光照的 vDirectIrradiance / vSkyAmbient 是帧级
// varying（海平面天空条件）、MIN_AMBIENT 是常数地板，对眼位实际有无光照一无所知 = 无光洞窟水下雾
// 恒亮的根源；机制见函数内段注与 constants.glsl 的 WATER_UW_ENV_*。
// 消费方：composite_fog（applyUnderwaterFog）+ lib/water/reflection.glsl（waterReflectionHitFog
// 水下分支）+ lib/water/surface.glsl（shadeWaterSurface 水上水雾段）。
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：constants.glsl（WATER_FOG 宏分区 /
// WATER_FOG_COLOR / WATER_UW_* / MIN_AMBIENT / DIM_NO_DIRECT_LIGHT）、uniforms.glsl
//（eyeBrightnessSmooth）、utils/color.glsl（rgbToLuma）
#ifndef LIB_WATER_FOG_GLSL
#define LIB_WATER_FOG_GLSL

#ifdef STAGE_FRAGMENT

#ifdef WATER_FOG

// 雾色光照（上 / 水下共用单真源）：直射辐照度半去饱调制 + 天空环境 + 兜底地板，乘归一化雾基色，
// 末乘亮度旋钮（三项之和统一缩放，相对比例不变、昼夜自动跟进）——基色两路共用 WATER_FOG_COLOR，
// 亮度、太阳项与天空项系数由路径传入：水上 WATER_FOG_*，水下 WATER_UW_*。
// 2026-10-08 水下太阳项独立压暗、雾色不随物体亮度补偿抬升；基色两路仍共用。
vec3 waterFogLitColor(vec3 fogBase, vec3 directIrradiance, vec3 skyAmbient, float sunScale, float skyScale, float brightness) {
    vec3 sunTint = mix(vec3(rgbToLuma(directIrradiance)), directIrradiance, 0.5);
    return fogBase * (sunTint * sunScale
                    + skyAmbient * skyScale
                    + MIN_AMBIENT) * brightness;
}

// 水下环境光门（2026-10「无光水下雾依然很亮」修复）：eyeBrightnessSmooth 的**天光分量**（眼位
// 光照级引擎平滑值，uniforms.glsl）归一后经「幂 + 地板」整形（首版「线性 × 无地板」按反馈两轮
// 调参——线性门下雾色〔HDR〕经 AgX 压缩后亮度骤变全挤在极低光照段、且环境光到最小值时雾彻底
// 消失像空气）：WATER_UW_ENV_POWER 把变化摊到全量程、WATER_UW_ENV_FLOOR 保住无光水下的最低
// 能见度暗雾。天光分量承载直射 / 天空两项的位置遮挡（洞窟 / 深水 / 桥影下衰减到 0；时间维度
// 不在此：天光级夜间不降，昼夜量级由 vDirectIrradiance / vSkyAmbient 帧级 varying 自带）；
// **方块光分量不参与**（2026-10 按反馈剔除——火把 / 海晶灯的暖色雾照未建模，max 混入只会让
// 光源旁雾色凭空偏亮；方块光暖色贡献为扩展点、接入时单建一项）。乘在 waterFogLitColor 整体
//（含 MIN_AMBIENT 地板项）；消费点 = applyUnderwaterFog 与 waterReflectionHitFog 水下分支
//（TIR 镜像雾与直接观视雾同门，避免镜中雾亮 / 眼前雾暗的错位）
float waterUwEnvLight() {
    float envL = float(eyeBrightnessSmooth.y) * WATER_UW_ENV_LIGHT_SCALE;
    return WATER_UW_ENV_FLOOR + (1.0 - WATER_UW_ENV_FLOOR) * pow(envL, WATER_UW_ENV_POWER);
}

// 相机在水中的整屏水雾（composite_fog 消费）：按 depthtex0 表面距离统一吸收 + 满距 mix 雾色；
// 水面像素自身的「水下观视」（折射背景不施水雾——雾按眼到水面的路径在雾 pass 结算）见
// shadeWaterSurface 的 underwater 分支，两层路径不重复计费
void applyUnderwaterFog(inout vec3 color, vec3 viewPos, bool skyPixel,
                        vec3 directIrradiance, vec3 skyAmbient) {
#ifdef DIM_NO_DIRECT_LIGHT
    directIrradiance = vec3(0.0); // 无天光维度（下界 / 末地，2026-10）：直射不进水下雾色——入参是未过天光门的原始 vDirectIrradiance（固定时间太阳值），shadeSurface 同纪律剔除
#endif
    float dist = skyPixel ? 1e6 : length(viewPos); // 天空像素（出水仰视的掠射带）按满雾
    vec3 fogLit = waterFogLitColor(WATER_FOG_COLOR, directIrradiance, skyAmbient, WATER_UW_SUN_SCALE, WATER_UW_SKY_SCALE,
                                   WATER_UW_FOG_BRIGHTNESS)
                * waterUwEnvLight();
    color *= exp(-(vec3(1.0) - WATER_FOG_COLOR) * dist * WATER_UW_TRANSMIT);
    color = mix(color, fogLit, 1.0 - exp(-dist / WATER_UW_VISIBILITY));
}
#endif

#endif

#endif
