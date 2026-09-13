// 2D 平面云——单层解析云，方案移植自春v2 的 clouds2D（2D 云原作者 Coldnight冷夜，见春v2
// clouds2D.glsl 头注；KN 相位函数原作者 Jessie / Luna）。本包适配点（各注释内详述）：
//   ① 光照经通用全屏 vsh 帧数据 varying 供光（春v2 的 sunColor / skyColor / isNight 减半不移植
//     ——昼夜切换黑过渡、雨天直射 ×0.25、环境去饱和由 varying 自动跟进）；
//   ② 云壳半径接本包 EARTH_RADIUS（与大气曲率一致）；直射透射率用 vCloudTransmittance
//     （云层海拔处求值，日落时云比地面晚变红）；
//   ③ 角坐标世界锚定（+ cameraPosition.xz，春v2 原版无此项——其云随相机水平平移，有体素云
//     底层兜底运动感；本包无底层，飞行会暴露该行为）；
//   ④ 雨天抬 coverage 成阴天 + 密度衰减（春v2 原版只减密度、阴天感由其体素云层承担）。
// 首版自研方案（弦长 Beer + 伪自阴影 + 银边 pow）实机观感不佳、按反馈整体替换，调研与
// 设计存档见 plans/平面云方案.md
//
// 性能（本包三次优化，相对春v2 原版）：KN 相位的 e 牛顿迭代常量折叠（g 与 e / ln(2e+1) 在
//   constants.glsl 成对维护，免每云像素 9 次超越函数）；地平线 alpha 上界早退（先验上界不可见
//   即全免噪声求值）；hash 族换无 sin 浮点 hash（noise.glsl，图案更换统计等价、待实机 A/B）；
//   warp 场 worley → simplex（9 hash → 3，开关宏 CLOUDS_2D_WARP_SIMPLEX、A/B 回退点）；
//   伪自阴影探针场化——cloudFieldShape / sampleCloudField（colortex1 云形状场槽位，deferred 槽
//   每帧生成 128²×9 hash、deferred1 同帧消费；云像素探针 9 hash 内联求值 → 2 次 bilinear fetch；
//   场 2 octave 为 4 km texel 的 Nyquist 上限，调制趋平滑由 SHADOW_GAIN 补偿）。
//   云像素噪声路径：~126 次 sin + 9 次 log（春v2 原版）→ 36 hash（二次优化后）→ 21 hash + 2 场
//   fetch（warp simplex 化 −6、探针场化 −9）；晴天空像素 27 → 21 hash
//
// 结构：云壳求交（云下仰视穿出 / 云上俯视云顶 / 行星遮挡统一处理）→ 角坐标（交点 xz ÷ 云壳
// 半径——数值域有界使 hash 输入坐标有界；远交点在角域自然压缩 = Kappa 距离压缩的解析等价，
// 地平线不闪）→ warp 微扰 + 6 octave simplex fbm（各 octave 差速演变）→ coverage 重映射 /
// smoothstep 二次锐化 → alpha = 密度 × 距离衰减 → KN 前向散射相位照明。画在 deferred_init 天空
// 分支（TAA 之前）、预乘合成 cloud.rgb + 天空 × cloud.a。
//
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：constants.glsl（CLOUDS_2D_* /
//   EARTH_RADIUS）、uniforms.glsl（cameraPosition / frameTimeCounter / rainStrength / colortex1——
//   云形状场采样）、lib/post/bloom.glsl（cloudFieldRect 场槽位矩形）、utils/space.glsl
//   （viewToWorldDirection）、utils/noise.glsl（rand2 / simplex2d）。
//   仅片段阶段（与 deferred_init / deferred_cloud_field 调用点约定一致）
#ifndef LIB_CLOUDS_GLSL
#define LIB_CLOUDS_GLSL

#ifdef STAGE_FRAGMENT

// 射线-球求交（球心 = 原点，即行星中心系），返回 (近根, 远根)、无交时近根 < 0
vec2 cloudRaySphere(vec3 origin, vec3 dir, float radius) {
    float b = dot(origin, dir);
    float c = dot(origin, origin) - radius * radius;
    float disc = b * b - c;
    if (disc < 0.0) return vec2(-1.0);
    float sq = sqrt(disc);
    return vec2(-b - sq, -b + sq);
}

// worley 单层（3x3 邻域最近特征点距离，春v2 cloud2DWorley 同款）——warp 的回退档
//（CLOUDS_2D_WARP_SIMPLEX 关闭时使用）。平方距离比较、循环外单次 sqrt：min 与单调函数可交换、
// 胜者同格、结果等价（省 8 次 sqrt / 天空像素，低配 GPU sqrt 非全速率）
float cloudWorley(vec2 p) {
    vec2 cell = floor(p);
    vec2 localPos = fract(p);
    float minDistSq = 2.0; // 初值 > 3×3 邻域最近距离上界 (√2)² 即可，结果由 clamp 收口
    for (int j = -1; j <= 1; j++) {
        for (int k = -1; k <= 1; k++) {
            vec2 offset = vec2(k, j);
            vec2 v = offset + rand2(cell + offset) - localPos;
            minDistSq = min(minDistSq, dot(v, v));
        }
    }
    return clamp(sqrt(minDistSq), 0.0, 1.0);
}

// fbm 前的微扰 warp（打碎 simplex 的均匀团块感），主采样与云形状场生成端共用同一实现——位移场
// 在两端的逐点值严格一致（确定性函数 + 同帧常量）。默认 simplex（3 hash）替春v2 的 worley
//（9 hash）：warp 职责只是平滑位移场、任何低频噪声都胜任；位移场从胞状距离变梯度场，云的破碎
// 纹理风格会变（统计等价，A/B 回退点——删 constants.glsl 的 CLOUDS_2D_WARP_SIMPLEX 即回 worley）
vec2 cloudWarp(vec2 p) {
#ifdef CLOUDS_2D_WARP_SIMPLEX
    float warp = simplex2d(p * CLOUDS_2D_SCALE) * 0.5 + 0.5;
#else
    float warp = cloudWorley(p * CLOUDS_2D_SCALE);
#endif
    return p - (1.0 - warp) * 0.001;
}

// 6 octave simplex fbm（lacunarity 2.5 / gain 0.5，春v2 sampleCloud2D 同款）；time 各 octave
// ×1.1 差速——低频层平移快、高频层慢，云形在漂移之外持续自演变。入参须为 warp 微扰后的坐标
//（cloudWarp 在调用方施加）
float cloudSimplexFbm(vec2 warpedP) {
    float frequency = CLOUDS_2D_SCALE;
    float weight = 1.0;
    float time = CLOUDS_2D_SPEED * frameTimeCounter;

    float noise = 0.0;
    float totalWeight = 0.0;
    for (int i = 0; i < 6; i++) {
        noise += (simplex2d(warpedP * frequency + time) * 0.5 + 0.5) * weight;
        totalWeight += weight;

        frequency *= 2.5;
        weight *= 0.5;
        time *= 1.1;
    }
    return noise / totalWeight;
}

// 噪声 → [0,1] 形状：coverage 重映射 + smoothstep 二次锐化（春v2 同款链路）。密度乘子
// （DENSITY / 雨天衰减）由调用方施加——主采样与伪自阴影差分共用本映射，逐帧一致的乘子在差中
// 相消
float cloudShape(float noise) {
    float coverage = mix(CLOUDS_2D_COVERAGE, CLOUDS_2D_COVERAGE_RAIN, rainStrength);
    float shape = clamp((noise - (1.0 - coverage)) / coverage, 0.0, 1.0);
    return smoothstep(0.0, 1.0, shape);
}

// 云形状场求值（生成端，deferred 槽的 deferred_cloud_field 逐 texel 调用）：世界锚定的低频云
// 形状（warp + 前 CLOUDS_2D_FIELD_OCTAVES 个 octave 的 fbm + cloudShape），入参为角域坐标
// p（= 世界 xz ÷ 云壳半径）。frequency / weight / time 序列与 cloudSimplexFbm 严格一致（改动须
// 两处联动）；与主采样全频形状共享同一低频场——场与主形状的空间相关性由此保证。返回 [0,1]
float cloudFieldShape(vec2 p) {
    vec2 warpedP = cloudWarp(p);
    float frequency = CLOUDS_2D_SCALE;
    float weight = 1.0;
    float time = CLOUDS_2D_SPEED * frameTimeCounter;

    float noise = 0.0;
    float totalWeight = 0.0;
    for (int i = 0; i < CLOUDS_2D_FIELD_OCTAVES; i++) {
        noise += (simplex2d(warpedP * frequency + time) * 0.5 + 0.5) * weight;
        totalWeight += weight;

        frequency *= 2.5;
        weight *= 0.5;
        time *= 1.1;
    }
    return cloudShape(noise / totalWeight);
}

// 云形状场采样（消费端，deferred_init 探针 / 未来云影）：世界 xz → colortex1 场槽位 bilinear
//（矩形由 bloom.glsl 的 cloudFieldRect 与生成端共用——texel i 中心 ↔ local = (i + 0.5) / RES
// 严格互逆）。场由 deferred 槽（program/deferred_cloud_field）每帧生成、deferred1（本 pass）同帧
// 消费、零滞后；窗口跟相机（场内容为绝对世界坐标的确定函数，锚点只决定覆盖范围），生成与消费
// 同帧同 cameraPosition——无错位。采样点恒在窗口内：可见云域 ≤ fade 早退界 ~221 km < 半窗口
// 256 km，bilinear 不会读到槽位边缘外
float sampleCloudField(vec2 worldXz) {
    vec4 rect = cloudFieldRect();
    vec2 fieldSize = vec2(textureSize(colortex1, 0));
    vec2 local = (worldXz - cameraPosition.xz) / CLOUDS_2D_FIELD_WORLD + 0.5;
    vec2 fieldUv = (rect.xy + local * rect.zw) / fieldSize;
    return texture(colortex1, fieldUv).r;
}

// Klein-Nishina 前向散射相位 ×4π 并钳 [0,1]（春v2 phasefunc_KleinNishina 同式）。原版以 8 次
// 牛顿迭代逐像素自 g 反解 e——g 为编译期常量、e 与 ln(2e+1) 随之恒定，故离线解出常量折叠
//（g = 0.25 → e ≈ 1.879、ln(2e+1) ≈ 1.560，与 g 在 constants.glsl 成对维护；折叠后 ×4π / 2π
// 相消，一次 rcp + FMA）。前向峰 = 太阳方向薄云处的银边
float cloudPhase(float cosTheta) {
    return clamp(2.0 * CLOUDS_2D_PHASE_E /
                 ((CLOUDS_2D_PHASE_E * (1.0 - cosTheta) + 1.0) * CLOUDS_2D_PHASE_LOGTERM),
                 0.0, 1.0);
}

// 2D 平面云主入口（仅片段阶段）。dirView 视图空间视线（不要求归一化，getSkyColor 同款）；
// 帧数据（主光源世界方向 / 直射辐照度 / 云高处透射率 / 天空环境基色）由调用方从 vsh 帧数据
// varying 传入。返回：rgb = 散射亮度（预乘合成域：最终 color = cloud.rgb + skyColor × cloud.a）、
// a = 透射率
vec4 getPlanarClouds(vec3 dirView, vec3 lightDirWorld, vec3 directIrradiance,
                     vec3 cloudTransmittance, vec3 skyAmbient) {
    vec3 dir = normalize(viewToWorldDirection(dirView));
    vec3 origin = vec3(0.0, EARTH_RADIUS + cameraPosition.y, 0.0); // 行星中心系相机位置（球心 = 原点）
    float cloudRadius = EARTH_RADIUS + CLOUDS_2D_HEIGHT;

    // 行星遮挡（春v2 同款双守卫）：云下相机前向命中地面 → 无云（掠地平线下沿的数学交点在
    // 地球背面）；一般情形地面命中点先于云交点同样无云（云上俯视时地面恒在云后、不触发）
    vec2 earthHit = cloudRaySphere(origin, dir, EARTH_RADIUS);
    if (origin.y < cloudRadius && earthHit.x > 0.0) return vec4(0.0, 0.0, 0.0, 1.0);

    // 云壳求交：云下取远根（相机在云壳球内、仰视穿出云底）、云上取近根（俯视云顶）——统一处理
    vec2 cloudHit = cloudRaySphere(origin, dir, cloudRadius);
    float lenToCloud = origin.y < cloudRadius ? cloudHit.y : cloudHit.x;
    if (lenToCloud < 0.0 || (earthHit.x > 0.0 && earthHit.x < lenToCloud))
        return vec4(0.0, 0.0, 0.0, 1.0);

    // 角坐标：交点 xz ÷ 云壳半径（世界锚定）。有界数值域使 hash 输入坐标有界；同一除法让
    // 远交点在角域自然压缩——地平线方向噪声频率自动降低、不闪（Kappa 显式距离压缩的解析等价）
    vec2 worldXz = cameraPosition.xz + dir.xz * lenToCloud;
    vec2 p = worldXz / cloudRadius;

    // 距离衰减（exp 尾长收口地平线带）；shape ≤ 1 且雨天衰减 ≤ 1，DENSITY × fade 即不透明度的
    // 先验上界——上界低于可见阈值（len ≳ 220 km 的地平线带）直接透明天，全部噪声求值与场采样免
    float fade = exp(-lenToCloud / CLOUDS_2D_FADE_DISTANCE);
    if (CLOUDS_2D_DENSITY * fade < 1e-4) return vec4(0.0, 0.0, 0.0, 1.0);

    // 形状密度：warp 微扰 + fbm + coverage 重映射 / 锐化（cloudShape）；雨天密度衰减在乘子处施加
    float shape = cloudShape(cloudSimplexFbm(cloudWarp(p)));
    float density = shape * CLOUDS_2D_DENSITY * (1.0 - CLOUDS_2D_RAIN_FADE * rainStrength);
    if (density < 1e-5) return vec4(0.0, 0.0, 0.0, 1.0);

    // 不透明度 = 密度 × 距离衰减，散射与透射率预乘合成
    float alpha = clamp(density * fade, 0.0, 1.0);

    // 伪自阴影（本包扩展，SEUS 同思路、零 raymarch）：同一低频场朝光源水平方向偏移 LIGHT_DRIFT
    // 米重采样求差——此处比太阳侧邻域稠密 = 朝阳边缘，更亮；反之处于邻域的阴影里，更暗。两端都
    // 从 colortex1 云形状场 bilinear 采样（差分同场天然无偏，替代原先逐像素 9 hash 内联降配求值
    // ——场由 deferred 槽每帧以 128²×9 hash 生成、本 pass 同帧消费，见 cloudFieldShape）；无云
    // 像素已在上行早退、不付场采样
    vec2 lightOffsetWorld = lightDirWorld.xz * CLOUDS_2D_LIGHT_DRIFT;
    float sunlit = clamp(0.5 + (sampleCloudField(worldXz)
                              - sampleCloudField(worldXz + lightOffsetWorld))
                              * CLOUDS_2D_SHADOW_GAIN,
                         0.0, 1.0);
    float shadowMod = 1.0 + (sunlit - 0.5) * 2.0 * CLOUDS_2D_SHADOW_STRENGTH;

    // 光照：直射（辐照度 × 云高处透射率 × KN 前向相位——太阳侧薄云银边 × 伪自阴影明暗）与
    // 天空环境按 SKY_MIX 混合（环境光各向同性、不吃阴影调制）；昼夜 / 雨天的幅度与色变全部
    // 由帧数据 varying 带来
    float phase = cloudPhase(dot(dir, lightDirWorld));
    vec3 lighting = mix(directIrradiance * cloudTransmittance * phase * shadowMod,
                        skyAmbient, CLOUDS_2D_SKY_MIX);
    vec3 scattering = lighting * alpha * CLOUDS_2D_BRIGHTNESS;
    return vec4(scattering, 1.0 - alpha);
}

#endif

#endif
