// 反射取色与雾化（仅片段阶段；2026-10 自 lib/lighting/water.glsl 按功能拆分，git 历史含合并
// 形态）：水面反射的三件取色事务——`waterFresnel`（反射混合权重：水上 Schlick / 水下 Snell +
// 全内反射）、`waterReflectionHitFog`（SSR 命中段雾）、`waterSkyReflection`（未命中 / Fresnel 低值
// 免 march 的天空回退）。追踪本身在 lib/water/ssr.glsl（waterSSR）、混合与调用序在
// lib/water/surface.glsl（shadeWaterSurface 反射段）。
// **天空回退** = sky-view LUT + 解析太阳盘 / 月亮盘 + **烘焙云层天空盒**（2026-10 接入，此前不含
// 云）。云走 colortex7 八面体槽位（composite12 帧末逐 texel getPlanarCloudsWorld 全量重算、此处经
// sky.glsl 的 sampleCloudSkybox 单 fetch 消费）——反射路径不重算云（2026-09 按反馈移除实时求值，
// 本烘焙路线即其记录的替代路线）：反射天空「未命中 SSR」的像素数量级与天空像素同级，逐水像素
// 全额云求值（云壳球求交 + warp + 6 octave simplex fbm + 伪自阴影场双 fetch）不成比例；烘焙摊到
// 65k 天空盒纹素、每水像素只付 1 次 fetch。**星盘不进反射（2026-10 按反馈：水面只反射日 / 月盘，
// 星点经波面法线搅碎 + Fresnel 低透过率后不可辨，反而添噪）**。合成序与 deferred_init 天空分支一致
//（LUT 天空 → 日盘 → 月盘 → 云）——镜中日 / 月盘同被云遮挡；lutValid 门控 = 首帧 / 缓冲重建帧跳过
//（天空盒与 sky LUT 同 pass 写入、生命周期等价，内容滞后一帧同批）。**合成后经 applyBoundaryFog 施加
// 天空档边界雾（2026-10 按反馈接入）**：镜中地平线带与雾中的直接天空 / 地形溶进同一雾色族。**解析
// 日 / 月盘乘直射可见性（2026-10 直射门控）**：日 / 月盘是直射光的镜面像——反射方向朝光源 = 与
// shadow map 采样同一光路，被地形 / 建筑遮挡的水面（SSR miss 因遮挡者在屏外）盘面须熄灭。
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：**lib/water/fog.glsl**（waterFogLitColor /
// waterUwEnvLight——命中段雾两分支消费、须先行引入）、lib/atmosphere/sky.glsl（getSkyColorWorld /
// getSunDisk / getMoonDisk / sampleCloudSkybox——八面体编码间接依赖 utils/packing.glsl，由接入方于
// sky.glsl 之前引入）、lib/atmosphere/aerial.glsl（applyAerialPerspective——命中段雾的大气散射分支
// 消费，AERIAL_PERSPECTIVE 开启时须先行引入〔位于 sky.glsl 之后：方向参数化互逆组依赖〕）、
// lib/atmosphere/fog.glsl（applyBoundaryFog——命中段雾与天空回退两处消费、BOUNDARY_FOG 开启时须
// 先行引入）；另需 constants.glsl（WATER_F0 / WATER_REFRAT_IOR / WATER_FOG 宏分区 / WATER_FOG_* /
// WATER_UW_* / MOON_DISK / CLOUDS_2D / DIM_NO_ATMOSPHERE / DIMENSION_SKY_COLOR）、uniforms.glsl
//（isEyeInWater / cameraPosition / gbufferModelView）、utils/space.glsl（viewToRelativeWorld）
#ifndef LIB_WATER_REFLECTION_GLSL
#define LIB_WATER_REFLECTION_GLSL

#ifdef STAGE_FRAGMENT

// ---------------- Fresnel ----------------

// 水面 Fresnel（Schlick）：水上为标准式；水下入射介质为水（稠侧），经 Snell 换算折射角余弦，
// 超过全内反射临界角（sin ≥ 1/IOR，IOR 1.2 时约 56°）恒 1——水下仰视水面近掠射成镜面
// viewDirW 眼 → 表面的世界系方向（归一）；normalW 世界系波面法线（朝上）
float waterFresnel(vec3 viewDirW, vec3 normalW, bool underwater) {
    float cosView = dot(-viewDirW, normalW); // 表面 → 眼方向与法线夹角余弦（水上为正）
    if (!underwater)
        return WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - clamp(cosView, 0.0, 1.0), 5.0);
    float cosI = clamp(-cosView, 0.0, 1.0);
    float sinT2 = WATER_REFRAT_IOR * WATER_REFRAT_IOR * (1.0 - cosI * cosI);
    if (sinT2 >= 1.0) return 1.0;
    return WATER_F0 + (1.0 - WATER_F0) * pow(1.0 - sqrt(1.0 - sinT2), 5.0);
}

// ---------------- SSR 命中段雾（2026-10 按反馈补充） ----------------

// 反射光路径 = 眼→水面（composite_fog 按水像素表面深度对最终合成色整像素结算）+ 水面→命中点
//（本函数）——两段折线近似。命中色取自背景快照（deferred_init 写入、无雾域），命中段的雾此前
// 缺失：水上视角的远岸反射不雾化（与直接可见的雾中地形刺眼不一致）、水下视角的 TIR 镜像过清。
// 分支：
//   水下视角            → 水下雾（applyUnderwaterFog 同式：吸收 + 满距 mix，距离 = 命中段长、
//                         水下亮度档 / 斜率——TIR 反射打到的是水下几何，命中段全程在水下）；
//   水上 + 命中点在水下 → 水雾吸收（折射路径同式；水平面的反射方向恒上行〔背向回退保底，见
//                         shadeWaterSurface〕、命中点常态不低于水面，本分支对水平面是掠射 bank
//                         命中重建的容差带；竖直流面（2026-10 几何面重定基）的反射合法向下——
//                         自上方俯看瀑布时命中瀑下水潭 / 水下几何是常态路径；水面判定带 0.2 格
//                         裕量盖波高〔±0.11〕与水线岸壁）；
//   水上 + 命中点在水上 → 大气散射雾 + 边界雾（composite_fog 几何分支同序，2026-10 第二轮反馈
//                         接入）：距离语义 = **折线全长**（眼→水面 + 水面→命中点）——反射光的
//                         真实光程、亦 ≈ 直接观看该景物的距离；只用段长时中远景命中（aerial 效果
//                         域 far/3~0.7far）几乎无雾、边界雾也只在打到渲染边缘（屏幕边缘雾带）的
//                         命中上出现——「碰撞远景几乎没有雾」的根源。实现 = 沿段方向构造该长度的
//                         虚拟视位置喂 applyAerialPerspective / applyBoundaryFog（两入口对入参只取
//                         length 与方向、单真源不改）；雾色沿**反射方向**取 LUT，远处反射的山与
//                         直接可见的雾中山溶进同一雾色族；近距命中在两入口早退链内零 LUT fetch。
// 三雾宏（WATER_FOG / AERIAL_PERSPECTIVE / BOUNDARY_FOG）全关时整段编译剔除（与 composite_fog
// 透传旁路同一纪律）。已知取舍：远处水面像素的 d1 段雾已由 composite_fog 对整像素结算过，命中段
// 再按全长施加 = 该段轻微重复计雾（同色族、幅度 ≤ fade(d1)，渐近同色不可辨）
void waterReflectionHitFog(inout vec3 color, vec3 surfaceViewPos, float surfaceWorldY,
                           vec3 hitViewPos, vec2 lm,
                           vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid,
                           vec3 directIrradiance, vec3 skyAmbient) {
#if defined(BOUNDARY_FOG) || defined(WATER_FOG) || defined(AERIAL_PERSPECTIVE)
    vec3 segView = hitViewPos - surfaceViewPos;
    float segDist = length(segView);
    if (isEyeInWater == 1) {
#ifdef WATER_FOG
        // 环境光门与 applyUnderwaterFog 同源（waterUwEnvLight）：TIR 镜像雾与直接观视的整屏水下雾
        // 同门调暗，无光洞窟中镜内 / 镜外亮度一致
        vec3 fogLit = waterFogLitColor(WATER_FOG_COLOR, directIrradiance, skyAmbient, WATER_UW_SKY_SCALE,
                                       WATER_UW_FOG_BRIGHTNESS)
                    * waterUwEnvLight();
        color *= exp(-(vec3(1.0) - WATER_FOG_COLOR) * segDist * WATER_UW_TRANSMIT);
        color = mix(color, fogLit, 1.0 - exp(-segDist / WATER_UW_VISIBILITY));
#endif
    } else {
        // 命中点绝对世界 y（水面判定）——绝对系比较与 cameraPosition 无关、逐点准确
        float hitWorldY = viewToRelativeWorld(hitViewPos).y + cameraPosition.y;
        if (hitWorldY < surfaceWorldY - 0.2) {
#ifdef WATER_FOG
            vec3 fogLit = waterFogLitColor(WATER_FOG_COLOR, directIrradiance, skyAmbient, WATER_FOG_SKY_SCALE,
                                           WATER_FOG_BRIGHTNESS)
                        * clamp(lm.y, 0.0, 1.0);
            color *= exp(-(vec3(1.0) - WATER_FOG_COLOR) * segDist * WATER_FOG_TRANSMIT);
            color = mix(color, fogLit, clamp(segDist / WATER_MIST_VISIBILITY, 0.0, 1.0));
#endif
        } else {
            // 虚拟视位置 = 段方向 × 折线全长（眼→水面 + 水面→命中点，见头注距离语义）；max 防
            // segDist → 0 除零（SSR 起点推离后实际到不了，纯数值防线）
            vec3 pathPosView = segView * ((length(surfaceViewPos) + segDist) / max(segDist, 1e-4));
#ifdef AERIAL_PERSPECTIVE
            applyAerialPerspective(color, pathPosView, sunDirWorld, moonDirWorld, horizon, lutValid);
#endif
#ifdef BOUNDARY_FOG
            applyBoundaryFog(color, pathPosView, false, sunDirWorld, moonDirWorld, horizon, lutValid);
#endif
        }
    }
#endif
}

// ---------------- 天空回退（deferred_init 天空分支的解析部分，取同一套单真源函数） ----------------

// 反射方向的天空色：sky-view LUT + 解析太阳盘 / 月亮盘 + 烘焙云层天空盒（头注）。合成序与
// deferred_init 天空分支一致（LUT 天空 → 日盘 → 月盘 → 云）；lutValid 门控 = 首帧 / 缓冲重建帧
// 跳过。合成后经 applyBoundaryFog 施加天空档边界雾：在采样侧合成后施加而非烘焙进天空盒生成端
//（天空盒只存云层预乘域、LUT 天空与解析日 / 月盘在采样侧合成，只雾云会成「雾中云浮在清亮天空
// 上」）。解析日 / 月盘乘直射可见性（头注）。LUT 的 Mie 前向辉光不门控——那是天空本身的散射
//（镜中有天空就有辉光），仅低频残余近似
vec3 waterSkyReflection(vec3 reflDirW, vec3 sunDirWorld, vec3 moonDirWorld,
                        vec3 horizon, bool skyLutValid, float sunVisibility) {
#ifdef DIM_NO_ATMOSPHERE
    // 维度极简档（下界 / 末地）：无天空 LUT / 云天空盒 / 镜中边界雾——回退 = 维度常量天色
    //（deferred_init 天空分支的 DIMENSION_SKY_COLOR 同源，镜内外一致）；sunVisibility 无视觉
    // 路径（直射经天光门归零）。两维度无自然水面，本分支为模组 / 指令造水的正确性保险
    return DIMENSION_SKY_COLOR;
#else
    vec3 reflDirView = mat3(gbufferModelView) * reflDirW;
    vec3 sky = getSkyColorWorld(reflDirW, sunDirWorld, moonDirWorld, horizon, skyLutValid);
    sky += getSunDisk(reflDirView, sunDirWorld) * sunVisibility;
#ifdef MOON_DISK
    // 镜中月盘（合成序与 deferred_init 天空分支一致：LUT 天空 → 日盘 → 月盘 → 云）：乘同一
    // sunVisibility（主导光源可见性——夜间即月光可见性，桥影 / 山影挡月光直射也挡镜中月盘视线，
    // 与解析日盘同一 shadowtex1 判定光路）
    sky += getMoonDisk(reflDirView, moonDirWorld) * sunVisibility;
#endif
#ifdef CLOUDS_2D
    if (skyLutValid) {
        // 标准 alpha 合成（与 deferred_init 天空分支同契约：rgb = 未预乘云色、a = 不透明度，
        // 2026-10 修复——云色暗时镜中呈暗剪影而非透明）
        vec4 cloud = sampleCloudSkybox(reflDirW);
        sky = mix(sky, cloud.rgb, cloud.a);
    }
#endif
#ifdef BOUNDARY_FOG
    // 反射内容不随水像素的表面距离被 composite_fog 雾化（水按表面深度结算、近水恒无雾），镜中地平
    // 线带不雾则与雾中的直接天空 / 地形刺眼不一致；与 composite_fog 的直接天空像素同语义（skyPixel
    // 档：距离因子恒 1、viewPos 兼作方向源、水下早退内置）。施加在合成后——LUT 天空 + 日盘 + 云
    // 一同溶进雾色（composite_fog 对直接天空「云与太阳盘一同溶进雾色」同款）、雾色沿反射方向取
    // LUT 切线钳制色（与命中段雾同一纪律）。aerial 不施：∞ 档 ≡ sky-view LUT（不变式②），
    // composite_fog 对直接天空像素同样跳过
    applyBoundaryFog(sky, reflDirView, true, sunDirWorld, moonDirWorld, horizon, skyLutValid);
#endif
    return sky;
#endif // DIM_NO_ATMOSPHERE
}

#endif

#endif
