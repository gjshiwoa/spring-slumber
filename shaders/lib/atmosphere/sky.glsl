// 天空颜色（线性 HDR）——Chapman 解析大气 + 环境场多次散射（atmosphere.glsl）的管线封装
// deferred_init 天空像素（depth >= 1）经 sky-view LUT 采样；同一物理核心供雾 / 直射光着色 /
// 环境光 / 水面反射扩展复用。当前太阳 + 月亮双光源、晴天（MC 日月恰好相对；月亮辐照度 = 太阳
// × 1/2000；星星 / 雨天为扩展点）
//
// sky-view LUT（移植自春雷 Hillaire 非线性参数化，Sébastien Hillaire, EGSR 2020）：每帧在
// colortex7 左下角 200×200 重算（日 / 月半区各 200×100 ≈ 2% 屏幕成本），替代逐像素解析求值；
// 采样端只做一次双线性。球对称大气 + 单光源下天空色由 (视线天顶余弦, 视线-光源水平投影夹角
// 余弦) 完全决定——精确 2D 表示、每光源独占一个半区：
//   a ∈ [0,1] 方位角（sqrt 使纹素向光源侧集中，分辨率 SKYVIEW_LUT_W = 200）、
//   v ∈ [0,1] 天顶角（上 / 下半段各一段 sqrt 使纹素向地平线集中，分辨率 SKYVIEW_LUT_H = 100）、
//   参数域线性映射首末纹素中心（半纹素内缩）：采样不越区域边界、与相邻槽位不串色
// 依赖由接入的 program 先行 include：uniforms.glsl（sunPosition / moonPosition / colortex7 等）、
//   constants.glsl（TAU、大气常量、SKYVIEW_*）、utils/space.glsl（viewToWorldDirection）、
//   atmosphere.glsl（物理核心，仅解析路径与 LUT 生成端使用）
// sunDirectionWorld / moonDirectionWorld 供 composite12 LUT 生成端顶点阶段调用；
// 采样端 getSkyColor 的光源方向与地平线几何为显式参数（调用方从 vsh 帧数据 varying 传入）
#ifndef LIB_SKY_GLSL
#define LIB_SKY_GLSL

// 太阳方向（世界系 = 玩家对齐系，+Y 朝上）
vec3 sunDirectionWorld() {
    return normalize(viewToWorldDirection(sunPosition));
}

// 月亮方向（世界系；与太阳恰好相对——白天沉入地平线后，月亮半区按阈值写 0）
vec3 moonDirectionWorld() {
    return normalize(viewToWorldDirection(moonPosition));
}

// ---------- sky-view LUT 槽位几何（colortex7 左下角杂项簇） ----------

// LUT 全区域矩形（缓冲归一化坐标，xy = 原点、zw = 边长）：锚定缓冲底边（texel y ∈ [0, 200)）、
// 预留天空盒右侧（SKYVIEW_LUT_ORIGIN_X）；composite12 的 vsh 光栅包围盒扩展与采样端共用
vec4 skyViewLutRegionRect() {
    vec2 texel = 1.0 / vec2(textureSize(colortex7, 0));
    vec2 origin = vec2(float(SKYVIEW_LUT_ORIGIN_X), 0.0) * texel;
    vec2 size = vec2(float(SKYVIEW_LUT_W), float(2 * SKYVIEW_LUT_H)) * texel;
    return vec4(origin, size);
}

// 太阳半区矩形（区域上半 = uv y ∈ [100/H, 200/H] = 缓冲底边上方 100~200 texel 行，
// 即 fsh 判定 pixel.y ∈ [100, 200) 的那一段）
vec4 skyViewLutSunRect() {
    vec4 region = skyViewLutRegionRect();
    return vec4(region.xy + vec2(0.0, region.w * 0.5), vec2(region.z, region.w * 0.5));
}

// 月亮半区矩形（区域下半 = uv y ∈ [0, 100/H]，最贴缓冲底边，即 fsh 判定 pixel.y ∈ [0, 100) 的那一段）
vec4 skyViewLutMoonRect() {
    vec4 region = skyViewLutRegionRect();
    return vec4(region.xy, vec2(region.z, region.w * 0.5));
}

// 参数域 [0,1] → 纹素中心域（首末纹素中心对齐的半纹素内缩，春雷 utils/math.glsl 同式）
float lutParamToTexelCenter(float p, float resolution) {
    return p * (resolution - 1.0) / resolution + 0.5 / resolution;
}

// ---------- 采样端 ----------

// 世界系方向（归一化）→ LUT 天顶参数 v ∈ [0,1]（0 = 天顶、0.5 = 地平线、1 = 天底），与生成端
// skyViewLutTexel 严格互逆；只依赖 dirWorld.y 与地平线几何——日 / 月两半区共用一次求值。
// horizon 为观察者地平线几何 (cosBeta, beta, zenithHorizon)，由 vsh 帧数据传入
float skyViewLutZenithParam(vec3 dirWorld, vec3 horizon) {
    float vzc = clamp(dirWorld.y, -1.0, 1.0);
    float vzcAngle = acos(vzc);
    if (vzc >= -horizon.x) {
        float t = 1.0 - vzcAngle / horizon.z;
        return (1.0 - sqrt(clamp(t, 0.0, 1.0))) * 0.5;
    } else {
        float t = (vzcAngle - horizon.z) / horizon.y;
        return sqrt(clamp(t, 0.0, 1.0)) * 0.5 + 0.5;
    }
}

// 世界系方向 → LUT 方位参数 a ∈ [0,1]：a = sqrt((1 - lvCos) / 2)，sqrt 使纹素向光源侧集中；
// 与生成端互逆；vzSin / szSin → 0 时方位退化（天顶色与方位无关，取 +X 基准无害）
float skyViewLutAzimuthParam(vec3 dirWorld, vec3 lightWorld) {
    float vzc = clamp(dirWorld.y, -1.0, 1.0);
    float vzSin = sqrt(max(1.0 - vzc * vzc, 0.0));
    float szCos = clamp(lightWorld.y, -1.0, 1.0);
    float szSin = sqrt(max(1.0 - szCos * szCos, 0.0));
    vec2 viewHoriz = vzSin > 1e-4 ? dirWorld.xz / vzSin : vec2(1.0, 0.0);
    vec2 lightHoriz = szSin > 1e-4 ? lightWorld.xz / szSin : vec2(1.0, 0.0);
    return sqrt(clamp((1.0 - dot(viewHoriz, lightHoriz)) * 0.5, 0.0, 1.0));
}

// 半区采样：参数 → 半纹素内缩局部 uv → 缓冲 uv 双线性（日 / 月半区共用）。textureLod 0 显式
// 指定（colortex7 无 mip，免隐式导数）；有效性校验已上移 vsh 探针，采样端不逐像素检查
vec3 sampleSkyViewLutHalf(vec4 rect, vec2 param) {
    vec2 localUv = vec2(lutParamToTexelCenter(param.x, float(SKYVIEW_LUT_W)),
                        lutParamToTexelCenter(param.y, float(SKYVIEW_LUT_H)));
    return textureLod(colortex7, rect.xy + localUv * rect.zw, 0.0).rgb;
}

// LUT 尚未生成或缓冲重建时的轻量天空：只在首帧 / 无效槽位使用，不替代正常 Chapman 天空。
vec3 fallbackSkyColor(vec3 dirWorld, vec3 sunDirWorld) {
    float day = smoothstep(-0.10, 0.25, sunDirWorld.y);
    vec3 ambientRadiance = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, day) / PI;
    float hemisphere = mix(0.18, 1.0, smoothstep(-0.15, 0.55, dirWorld.y));
    return ambientRadiance * (0.45 * SKY_BRIGHTNESS * hemisphere);
}

// 天空色采样入口（deferred_init 天空分支 / 未来雾、反射经此走 LUT）
// dirView 视图空间方向（不要求归一化）；光源方向 / horizon / lutValid 均由调用方从 vsh 帧数据
// 传入；返回线性 HDR，SKY_BRIGHTNESS 已在生成端乘入。日 / 月两半区和式（春雷同构），非活动半区
//（光源低于 SKY_LIGHT_MIN_HEIGHT、生成端整区写 0）以同一常量门控跳过参数化与 fetch——不变式
//「采样端跳过 ⊆ 生成端写黑」由两侧共用常量保证；LUT 内容滞后一帧（composite12 在 deferred 后执行）
vec3 getSkyColor(vec3 dirView, vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    vec3 dirWorld = normalize(viewToWorldDirection(dirView));
    float zenithParam = skyViewLutZenithParam(dirWorld, horizon);

    vec3 color = vec3(0.0);
    if (sunDirWorld.y > SKY_LIGHT_MIN_HEIGHT)
        color += sampleSkyViewLutHalf(skyViewLutSunRect(),
                                      vec2(skyViewLutAzimuthParam(dirWorld, sunDirWorld), zenithParam));
    if (moonDirWorld.y > SKY_LIGHT_MIN_HEIGHT)
        color += sampleSkyViewLutHalf(skyViewLutMoonRect(),
                                      vec2(skyViewLutAzimuthParam(dirWorld, moonDirWorld), zenithParam));
    return lutValid ? color : fallbackSkyColor(dirWorld, sunDirWorld);
}

// ---------- 生成端（composite_bloom_upsample / composite12） ----------

// 解析天色（世界系方向直接求值 Chapman + 环境场 MS）：LUT 生成核心，也是解析路径的完整保留。
// observerRadius / lightOpticalDepth / ambientField（atmosphere.glsl 的 skyAmbientField）由
// composite12 vsh 每帧预计算，避免每个 LUT texel 重复相机半径、光源路径 Chapman 与 48 节点求积
vec3 skyRadianceAnalytic(float observerRadius, vec3 dirWorld, vec3 lightWorld,
                         vec3 lightOpticalDepth, vec3 irradiance, vec3 ambientField) {
    vec3 origin = vec3(0.0, observerRadius, 0.0);
    float t = planetHitDistance(observerRadius, dirWorld.y);
    return atmosphericRadiance(origin, dirWorld, lightWorld, lightOpticalDepth, t, irradiance,
                               ambientField)
         * SKY_BRIGHTNESS;
}

// 半区 texel → 天色：local.x ∈ [0, SKYVIEW_LUT_W)（a = 0 在光源侧）、local.y ∈ [0, SKYVIEW_LUT_H)
//（j = 0 为天顶行——半区靠缓冲底边的行，与采样端 y 映射互逆）。在「光源水平投影 = +X、光源位于
// XY 平面内」的局部系构造几何：球对称大气的散射只依赖 (vzc, szCos, mu)，与真实方位仅差绕天顶
// 旋转、结果等价；ambientField 为 vsh 预计算的多次散射环境场（透传给 skyRadianceAnalytic）
vec3 skyViewLutTexel(ivec2 local, float observerRadius, vec3 horizon,
                     vec3 lightWorld, vec3 lightOpticalDepth, vec3 irradiance,
                     vec3 ambientField) {
    float beta = horizon.y;
    float zenithHorizon = horizon.z;

    // 纹素中心参数（采样端 skyViewLutAzimuthParam / skyViewLutZenithParam 的逆映射）
    float azimuthParam = float(local.x) / float(SKYVIEW_LUT_W - 1);
    float zenithParam = float(local.y) / float(SKYVIEW_LUT_H - 1);

    float vzc;
    if (zenithParam < 0.5) {
        float q = 1.0 - 2.0 * zenithParam;
        vzc = cos(zenithHorizon * (1.0 - q * q));
    } else {
        float q = 2.0 * zenithParam - 1.0;
        vzc = cos(zenithHorizon + beta * (q * q));
    }
    float vzSin = sqrt(max(1.0 - vzc * vzc, 0.0));

    float lvCos = 1.0 - 2.0 * azimuthParam * azimuthParam;
    float lvSin = sqrt(max(1.0 - lvCos * lvCos, 0.0));

    float szCos = clamp(lightWorld.y, -1.0, 1.0);
    float szSin = sqrt(max(1.0 - szCos * szCos, 0.0));

    vec3 localLight = vec3(szSin, szCos, 0.0);
    return skyRadianceAnalytic(observerRadius,
                               vec3(vzSin * lvCos, vzc, vzSin * lvSin),
                               localLight, lightOpticalDepth, irradiance, ambientField);
}

#endif
