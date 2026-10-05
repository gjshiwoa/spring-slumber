// 雨天地表湿滑场（2026-10）：湿度 = 露天 lmcoord.y 门 × 水坑噪声 × 朝上度权重 × rainStrength——
// gbuffer 写入侧（gbuffers_opaque 的湿面法线压平）与 deferred2 消费侧（program/deferred_ssr 的
// SSR 可见度）同一函数、同一输入求值：绝对世界 xz（噪声锚定）、原始 lmcoord.y（gbuffer 侧
// vLmcoord.y = colortex5.a 存储域）、朝上度（世界法线 y）——两侧数值一致由共用单真源结构性保证
//（位置输入差 = gbuffer 顶点插值 vs deferred 去抖重建的亚纹素差，噪声连续 ⇒ 湿度差趋零）。
// 朝上度权重（2026-10 按反馈「方块侧面没有雨天湿滑效果」接入）：WET_TOP_NORMAL_LOW/HIGH 全域
// smoothstep 窗（[-1,1]）——顶面满档 / 侧面半档（反射可见度随世界法线朝上度单调增，用户规格
//「越朝上可见度越高」）/ 底面无湿（雨打不到朝下的面）；侧面照常采样同一水坑噪声（xz 投影锚定
// ⇒ 顶面水坑横跨到相邻侧面湿度连续，竖直面内沿高度恒定 = 整面均匀润湿感、无竖直条纹）。
// 噪声 = noisetex 双 octave 值噪声（REPEAT 寻址对大世界坐标鲁棒——程序化 hash 在 ~1e4 后精度
// 劣化，noise.glsl 头注同限；与水波 / 焦散同一纹理资产、零新资源）；不随时间演化——降雨渐变由
// rainStrength 乘子承载（无湿度持久化缓冲，雨停即随雨强同步收干 = 已知取舍，见 AGENTS）。
// 依赖先行 include（lib 文件不嵌套）：lib/common/globals/constants.glsl（WET_SURFACE 宏分区 /
//   WET_SKY_LM_* / WET_NOISE_* / WET_TOP_NORMAL_*）、lib/common/globals/uniforms.glsl
//   （noisetex / rainStrength）
#ifndef LIB_WETNESS_GLSL
#define LIB_WETNESS_GLSL

#ifdef WET_SURFACE

// 水坑形状噪声（两 octave 值噪声，≈[0,1]）：基 octave（WET_NOISE_SCALE）定团块尺度、次 octave
//（×WET_NOISE_OCTAVE2_SCALE、权重 1/3）破平铺感；bilinear + smoothstep 门（调用方）够用，
// 水波侧的 iq better-filtering 纹素采样对低频湿度场无必要
float wetnessPuddleNoise(vec2 worldXz) {
    vec2 p = worldXz * WET_NOISE_SCALE;
    return textureLod(noisetex, p, 0.0).r * (2.0 / 3.0)
         + textureLod(noisetex, p * WET_NOISE_OCTAVE2_SCALE + vec2(0.37), 0.0).r * (1.0 / 3.0);
}

// 便宜的门控独立暴露：调用方可在世界位置重建 / 噪声采样前排除无湿表面。
// 分离门控不改变乘法次序：最终仍为 (skyGate * upGate) * puddle * rainStrength。
float terrainWetnessSkyGate(float lmSkyRaw) {
    return smoothstep(WET_SKY_LM_LOW, WET_SKY_LM_HIGH, lmSkyRaw);
}

float terrainWetnessUpGate(float topUpness) {
    return smoothstep(WET_TOP_NORMAL_LOW, WET_TOP_NORMAL_HIGH, topUpness);
}

// gate = skyGate * upGate；SSR 可用 gate * rainStrength 作湿度上界（puddle <= 1）。
// MIN_WETNESS 门槛只由 SSR 消费，法线压平侧保留门槛下的微潮。
float terrainWetnessFromGate(vec2 worldXz, float gate) {
    if (gate <= 0.0 || rainStrength <= 0.0) return 0.0;
    // smoothstep 水坑门经 mix 抬到微潮地板，再 pow2 收紧边缘（连乘免 pow）。
    float puddle = mix(WET_NOISE_FLOOR, 1.0, smoothstep(WET_NOISE_LOW, WET_NOISE_HIGH, wetnessPuddleNoise(worldXz)));
    puddle *= puddle;
    return gate * puddle * rainStrength;
}

// 地表湿滑程度 [0,1]：
//   worldXz   绝对世界坐标 xz（噪声锚定——相机无关、两侧一致）
//   lmSkyRaw  原始 lmcoord.y（未 remapLightmap——露天判定 [WET_SKY_LM_LOW, HIGH] 映 0→1；
//             檐下 / 洞口经光照传播衰减不触窗，雨不可达处天然无湿）
//   topUpness 表面朝上程度（世界法线 y；gbuffer 侧传**导数几何法线**、deferred2 侧传**解包法线**
//             〔已含压平〕——无 normal 贴图时两者逐位一致）经 [WET_TOP_NORMAL_LOW, HIGH] 全域
//             smoothstep 窗作朝上度权重：顶面 1 / 侧面 0.5 / 底面 0——湿度与 SSR 反射可见度随
//             朝上度单调增（2026-10 侧面接入），顶面与旧窄窗逐位一致
// 返回已乘 rainStrength（降雨渐变承载），非雨天恒 0
// 三参便捷入口；热路径共享上面的 gate / FromGate，允许调用方更早过滤。
float terrainWetness(vec2 worldXz, float lmSkyRaw, float topUpness) {
    float skyGate = terrainWetnessSkyGate(lmSkyRaw);
    if (skyGate <= 0.0 || rainStrength <= 0.0) return 0.0;
    float gate = skyGate * terrainWetnessUpGate(topUpness);
    return terrainWetnessFromGate(worldXz, gate);
}

#endif // WET_SURFACE

#endif
