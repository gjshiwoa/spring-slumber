// 边界雾（距离 / 天顶角双因子；雾色取 sky-view LUT）
// 混合系数 =（距离因子 × 天顶角因子）²：距离因子沿 far 的 BOUNDARY_FOG_START→END smoothstep 淡入
//（天空像素恒 1——天空无深度，雾带由天顶因子单独成形、地平线处天空与雾中地形溶成同一雾色）；
// 天顶角因子按视线世界 y 于 0→BOUNDARY_FOG_ZENITH 淡出（抬头雾散、地平线满雾）。雾色 = 天空 LUT
// 沿视线采样、仰角钳到**观察者地平线切线**（y = -horizon.x = -sin(dip)，h≈64 m 时约 -0.26°，与
// 生成端 SKY_CLAMP_TO_HORIZON 的饱和深度同一数值）：上半球〔含 y=0 与切线间的窄带〕统一取切线行
// 的地平线辉光色（日出上半球雾色不随仰角红蓝分异），下半球沿真实方向走 LUT 活曲线（Mie 前向光晕
// 随深度自然衰减，恒定色会拉成竖直白柱）。**钳制深度必须与 LUT 自身的饱和深度重合**（三代教训，
// 2026-09）：①锚 y=0（初版单侧 min）——y=0 与切线之间是亮度爬升约
// 5~10% 的解析辉光陡坡，压平段与陡坡段在 y=0 交界成 ~0.26° 宽亮唇、上沿即海平面浅硬边（「下半区
// 即地平线辉光、钳制幂等」的旧假设系误判——LUT 饱和在切线、不在 y=0）；②y 恒置 0——下半球被
// 压平、Mie 光晕成竖直白柱；③全放开——日出上下半球雾色红蓝分异。锚切线则钳平段在 LUT 自身的
// 饱和拐点（辉光峰）处与活曲线衔接、值连续且两侧斜率同为小量，边界结构性不可见
// 接入 = composite_fog 单 pass（composite2 槽、TAA 之前）：对 colortex6 就地雾化，距离 / 方向取
// depthtex0（全部几何含水 / 手 / 粒子 / 实体）——水面随其表面深度、以最终合成色单点被雾化，无需
// 前向逐路施加（首代形态 deferred_init 两分支 + 前向 after 路径已按反馈撤销，git 历史含完整形态）；
// 第二消费方 = water 反射命中段（lib/water/reflection.glsl 的 waterReflectionHitFog，2026-10：SSR 命中色取自
// 无雾快照，命中段（水面→命中点）以段向量入参施加同一边界雾——长度作距离、方向作视线）
// **下界统一雾档（FOG_UNIFIED_COLOR，2026-10）**：雾色 = NETHER_FOG_COLOR 统一常量（= 下界天色
// DIMENSION_SKY_COLOR 单真源，constants.glsl 边界雾分区的下界统一雾段）——无 LUT fetch、无仰角
// 钳制（钳制纪律是对齐 LUT 自身饱和深度，统一色无曲线可对齐）；**天顶角因子弃用**——那是主世界
// 为「抬头护天空」而设，下界封闭无天可护，天空像素本就是雾色常量、雾化幂等 ⇒ 任何仰角的融接
// 结构性无缝；混合系数退化为纯距离因子²（淡入带 shaping 与主世界同构）。入参签名两档一致
//（LUT 档帧数据参数在统一档为死参），消费点（composite_fog / waterReflectionHitFog）零改动
// 依赖由接入的 program 先行 include：constants.glsl（BOUNDARY_FOG_*；统一档另 NETHER_FOG_COLOR）
//   + uniforms.glsl（far / isEyeInWater / gbufferModelViewInverse）+ utils/space.glsl
//   （viewToWorldDirection，仅 LUT 档）+ atmosphere.glsl + sky.glsl（getSkyColorWorld，仅 LUT 档；
//   帧数据由消费方 composite_fog 的通用全屏 vsh varying 传入）
#ifndef LIB_ATMOSPHERE_FOG_GLSL
#define LIB_ATMOSPHERE_FOG_GLSL

#ifdef BOUNDARY_FOG

#ifndef FOG_UNIFIED_COLOR
// 雾色（LUT 档专用，统一雾档雾色 = NETHER_FOG_COLOR 常量直用、无独立函数）：**已归一化**的世界系
// 方向 → 天空 LUT 色（唯一调用方 applyBoundaryFog 在世界重建处一次归一后传入——归一必须先于钳制：
// 钳阈值 -horizon.x 是单位向量分量，未归一向量的 raw y 与之比较会随向量长度错标仰角——旧
// min(y, 0) 的 0 阈值天然尺度不变、无此问题）。仰角钳到地平线切线（锚点选择的三代教训见头注）：
// 钳制不改 xz 比例，归一后仰角恒 = min(原仰角, -sin(dip))、方位不变；直入 getSkyColorWorld
//（getSkyColor 的世界系核心）——旧版经 mat3(gbufferModelView) 回观察系再被 getSkyColor 转回
// 世界系，一次 mat3 往返 + 两次重复 normalize 纯为接口形态所付（2026-09 优化：每雾带像素省
// 2×mat3 + 2×normalize）
vec3 boundaryFogColor(vec3 dirWorld, vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    dirWorld.y = min(dirWorld.y, -horizon.x);
    return getSkyColorWorld(dirWorld, sunDirWorld, moonDirWorld, horizon, lutValid);
}
#endif

// 总入口：color 就地雾化。viewPos 兼作距离与方向源（deferred_init 几何像素传去抖重建 viewPos、
// 天空像素与前向像素传视图空间方向）；skyPixel = true 时距离因子恒 1；帧数据参数与 getSkyColor
// 同族、由调用方从 vsh varying 传入（统一雾档不消费、保留签名）。早退次序 = 水下 → 近距（几何
// 像素最常见形态，天顶换算与 LUT fetch 全免）→ 高仰角（LUT 档）。LUT 档世界方向在此一次归一
//（天顶因子与雾色采样共用——曾三处重复归一）；统一雾档纯距离、连世界重建都免（雾带像素只付
// smoothstep + mix）
void applyBoundaryFog(inout vec3 color, vec3 viewPos, bool skyPixel,
                      vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    if (isEyeInWater != 0) return; // 水下 / 熔岩中不雾（水下雾为扩展点）

    float boundaryDistance = max(far, 1.0);
    float distanceFactor = skyPixel ? 1.0 : smoothstep(boundaryDistance * BOUNDARY_FOG_START,
                                                       boundaryDistance * BOUNDARY_FOG_END,
                                                       length(viewPos));
    if (distanceFactor <= 0.0) return;

#ifdef FOG_UNIFIED_COLOR
    // 下界统一雾档（头注）：纯距离融接、雾色常量——天顶因子与 LUT fetch / 世界方向重建全免。
    // 天空像素（distanceFactor 1）整像素拉向雾色 = 天色常量，幂等无缝
    float fogFactor = distanceFactor * distanceFactor; // 积取平方：淡入带收窄，与 LUT 档同 shaping
    color = mix(color, NETHER_FOG_COLOR, fogFactor);
#else
    vec3 dirWorld = normalize(viewToWorldDirection(viewPos));
    float zenithFactor = 1.0 - smoothstep(0.0, BOUNDARY_FOG_ZENITH, dirWorld.y);
    float fogFactor = distanceFactor * zenithFactor;
    fogFactor *= fogFactor; // 积取平方：淡入带收窄、整体更轻
    if (fogFactor <= 0.0) return;

    color = mix(color, boundaryFogColor(dirWorld, sunDirWorld, moonDirWorld, horizon, lutValid), fogFactor);
#endif
}

#endif

#endif
