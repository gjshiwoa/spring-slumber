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
// 前向逐路施加（首代形态 deferred_init 两分支 + 前向 after 路径已按反馈撤销，git 历史含完整形态）
// 依赖由接入的 program 先行 include：constants.glsl（BOUNDARY_FOG_*）+ uniforms.glsl（far /
//   isEyeInWater / gbufferModelViewInverse）+ utils/space.glsl（viewToWorldDirection）+ atmosphere.glsl +
//   sky.glsl（getSkyColorWorld；帧数据由消费方 composite_fog 的通用全屏 vsh varying 传入）
#ifndef LIB_ATMOSPHERE_FOG_GLSL
#define LIB_ATMOSPHERE_FOG_GLSL

#ifdef BOUNDARY_FOG

// 雾色：**已归一化**的世界系方向 → 天空 LUT 色（唯一调用方 applyBoundaryFog 在世界重建处一次
// 归一后传入——归一必须先于钳制：钳阈值 -horizon.x 是单位向量分量，未归一向量的 raw y 与之比较
// 会随向量长度错标仰角——旧 min(y, 0) 的 0 阈值天然尺度不变、无此问题）。仰角钳到地平线切线
//（锚点选择的三代教训见头注）：钳制不改 xz 比例，归一后仰角恒 = min(原仰角, -sin(dip))、方位
// 不变；直入 getSkyColorWorld（getSkyColor 的世界系核心）——旧版经 mat3(gbufferModelView) 回
// 观察系再被 getSkyColor 转回世界系，一次 mat3 往返 + 两次重复 normalize 纯为接口形态所付
//（2026-09 优化：每雾带像素省 2×mat3 + 2×normalize）
vec3 boundaryFogColor(vec3 dirWorld, vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    dirWorld.y = min(dirWorld.y, -horizon.x);
    return getSkyColorWorld(dirWorld, sunDirWorld, moonDirWorld, horizon, lutValid);
}

// 总入口：color 就地雾化。viewPos 兼作距离与方向源（deferred_init 几何像素传去抖重建 viewPos、
// 天空像素与前向像素传视图空间方向）；skyPixel = true 时距离因子恒 1；帧数据参数与 getSkyColor
// 同族、由调用方从 vsh varying 传入。早退次序 = 水下 → 近距（几何像素最常见形态，天顶换算与
// LUT fetch 全免）→ 高仰角。世界方向在此一次归一（天顶因子与雾色采样共用——曾三处重复归一）
void applyBoundaryFog(inout vec3 color, vec3 viewPos, bool skyPixel,
                      vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    if (isEyeInWater != 0) return; // 水下 / 熔岩中不雾（水下雾为扩展点）

    float boundaryDistance = max(far, 1.0);
    float distanceFactor = skyPixel ? 1.0 : smoothstep(boundaryDistance * BOUNDARY_FOG_START,
                                                       boundaryDistance * BOUNDARY_FOG_END,
                                                       length(viewPos));
    if (distanceFactor <= 0.0) return;

    vec3 dirWorld = normalize(viewToWorldDirection(viewPos));
    float zenithFactor = 1.0 - smoothstep(0.0, BOUNDARY_FOG_ZENITH, dirWorld.y);
    float fogFactor = distanceFactor * zenithFactor;
    fogFactor *= fogFactor; // 积取平方：淡入带收窄、整体更轻
    if (fogFactor <= 0.0) return;

    color = mix(color, boundaryFogColor(dirWorld, sunDirWorld, moonDirWorld, horizon, lutValid), fogFactor);
}

#endif

#endif
