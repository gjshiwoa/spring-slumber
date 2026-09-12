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
// 性能（本包二次优化，相对春v2 原版）：KN 相位的 e 牛顿迭代常量折叠（g 与 e / ln(2e+1) 在
//   constants.glsl 成对维护，免每云像素 9 次超越函数）；伪自阴影偏移重采样降配为同一低频场的
//   前 CLOUDS_2D_SHADOW_OCTAVES 个 octave + 复用主采样 worley warp 位移（两测同场差分无偏，
//   免第二个 worley 与高频 octave）；地平线 alpha 上界早退（先验上界不可见即全免噪声求值）；
//   hash 族换无 sin 浮点 hash（noise.glsl，图案更换统计等价、待实机 A/B）
//
// 结构：云壳求交（云下仰视穿出 / 云上俯视云顶 / 行星遮挡统一处理）→ 角坐标（交点 xz ÷ 云壳
// 半径——数值域有界使 hash 输入坐标有界；远交点在角域自然压缩 = Kappa 距离压缩的解析等价，
// 地平线不闪）→ worley 微扰 + 6 octave simplex fbm（各 octave 差速演变）→ coverage 重映射 /
// smoothstep 二次锐化 → alpha = 密度 × 距离衰减 → KN 前向散射相位照明。画在 deferred_init
// 天空分支（TAA 之前）、预乘合成 cloud.rgb + 天空 × cloud.a。
//
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：constants.glsl（CLOUDS_2D_* /
//   EARTH_RADIUS）、uniforms.glsl（cameraPosition / frameTimeCounter / rainStrength）、
//   utils/space.glsl（viewToWorldDirection）、utils/noise.glsl（rand2 / hash22 / simplex2d）。
//   仅片段阶段（与 deferred_init 调用点约定一致）
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

// worley 单层（3x3 邻域最近特征点距离，春v2 cloud2DWorley 同款）——fbm 前的微扰、打碎 simplex
// 的均匀团块感
float cloudWorley(vec2 p) {
    vec2 cell = floor(p);
    vec2 localPos = fract(p);
    float minDist = 1.0;
    for (int j = -1; j <= 1; j++) {
        for (int k = -1; k <= 1; k++) {
            vec2 offset = vec2(k, j);
            vec2 point = rand2(cell + offset);
            minDist = min(minDist, length(offset + point - localPos));
        }
    }
    return clamp(minDist, 0.0, 1.0);
}

// 6 octave simplex fbm（lacunarity 2.5 / gain 0.5，春v2 sampleCloud2D 同款）；time 各 octave
// ×1.1 差速——低频层平移快、高频层慢，云形在漂移之外持续自演变。入参须为 worley 微扰后的坐标
// （warp 在调用方施加、位移供伪自阴影的偏移采样复用）。返回 x = 全频噪声、y = 前
// CLOUDS_2D_SHADOW_OCTAVES 个 octave 的低频 partial（同循环累出、同权重归一——伪自阴影差分与
// 主形状共用同一低频场，两测同场保证差分无偏）
vec2 cloudSimplexFbm(vec2 warpedP) {
    float frequency = CLOUDS_2D_SCALE;
    float weight = 1.0;
    float time = CLOUDS_2D_SPEED * frameTimeCounter;

    float noise = 0.0;
    float lowNoise = 0.0;
    float totalWeight = 0.0;
    float lowWeight = 0.0;
    for (int i = 0; i < 6; i++) {
        float s = (simplex2d(warpedP * frequency + time) * 0.5 + 0.5) * weight;
        noise += s;
        totalWeight += weight;
        if (i < CLOUDS_2D_SHADOW_OCTAVES) {
            lowNoise += s;
            lowWeight += weight;
        }

        frequency *= 2.5;
        weight *= 0.5;
        time *= 1.1;
    }
    return vec2(noise / totalWeight, lowNoise / lowWeight);
}

// 降配 fbm：仅前 CLOUDS_2D_SHADOW_OCTAVES 个 octave，frequency / weight / time 序列与
// cloudSimplexFbm 严格一致（改动须两函数联动）——伪自阴影的偏移重采样专用（高频细节对逐像素
// 的低频明暗调制无益，满配求值纯属浪费）
float cloudSimplexFbmLow(vec2 warpedP) {
    float frequency = CLOUDS_2D_SCALE;
    float weight = 1.0;
    float time = CLOUDS_2D_SPEED * frameTimeCounter;

    float noise = 0.0;
    float totalWeight = 0.0;
    for (int i = 0; i < CLOUDS_2D_SHADOW_OCTAVES; i++) {
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

// Klein-Nishina 前向散射相位 ×4π 并钳 [0,1]（春v2 phasefunc_KleinNishina 同式）。原版以 8 次
// 牛顿迭代逐像素自 g 反解 e——g 为编译期常量、e 与 ln(2e+1) 随之恒定，故离线解出常量折叠
// （g = 0.25 → e ≈ 1.879、ln(2e+1) ≈ 1.560，与 g 在 constants.glsl 成对维护；折叠后 ×4π / 2π
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
    vec2 p = (cameraPosition.xz + dir.xz * lenToCloud) / cloudRadius;

    // 距离衰减（exp 尾长收口地平线带）；shape ≤ 1 且雨天衰减 ≤ 1，DENSITY × fade 即不透明度的
    // 先验上界——上界低于可见阈值（len ≳ 220 km 的地平线带）直接透明天，两次噪声求值全免
    float fade = exp(-lenToCloud / CLOUDS_2D_FADE_DISTANCE);
    if (CLOUDS_2D_DENSITY * fade < 1e-4) return vec4(0.0, 0.0, 0.0, 1.0);

    // 形状密度：worley 微扰 warp + fbm（x = 全频、y = 低频 partial）+ coverage 重映射 / 锐化
    // （cloudShape）；雨天密度衰减在乘子处施加。warp 位移由 warpedP 带出供阴影采样复用——
    // warp 场特征胞 ≈ 云壳半径 / SCALE ≈ 21 km，跨数 km 探针偏移的位移差是平滑小量、被 clamp
    // 与 ±STRENGTH 调制幅度吸收
    vec2 warpedP = p - (1.0 - cloudWorley(p * CLOUDS_2D_SCALE)) * 0.001;
    vec2 cloudNoise = cloudSimplexFbm(warpedP);
    float shape = cloudShape(cloudNoise.x);
    float density = shape * CLOUDS_2D_DENSITY * (1.0 - CLOUDS_2D_RAIN_FADE * rainStrength);
    if (density < 1e-5) return vec4(0.0, 0.0, 0.0, 1.0);

    // 不透明度 = 密度 × 距离衰减，散射与透射率预乘合成
    float alpha = clamp(density * fade, 0.0, 1.0);

    // 伪自阴影（本包扩展，SEUS 同思路、零 raymarch）：同一密度场朝光源水平方向偏移
    // LIGHT_DRIFT 米重采样求差——此处比太阳侧邻域稠密 = 朝阳边缘，更亮；反之处于邻域的
    // 阴影里，更暗。偏移为角域尺度（米 ÷ 云壳半径）；偏移采样走降配 fbm（与主采样的低频
    // partial 同场 + 复用主 warp 位移——差分无偏，免第二个 worley 与高频 octave）；无云像素
    // 已在上行早退、不付第二次求值
    vec2 lightOffset = lightDirWorld.xz * (CLOUDS_2D_LIGHT_DRIFT / cloudRadius);
    float sunlit = clamp(0.5 + (cloudShape(cloudNoise.y)
                              - cloudShape(cloudSimplexFbmLow(warpedP + lightOffset)))
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
