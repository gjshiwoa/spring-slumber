// 天空颜色（线性 HDR）——Chapman 解析大气 + 环境场多次散射（atmosphere.glsl）的管线封装
// deferred_init 天空像素（depth >= 1）经 sky-view LUT 采样；同一物理核心供直射光着色 /
// 环境光 / 未来水面反射复用。当前太阳 + 月亮双光源、晴天（MC 日月恰好相对；月亮辐照度 = 太阳
// × 1/2000；雨天为扩展点）。日月盘 / 星盘为解析绘制（getSunDisk(World) / getMoonDisk(World) /
// getStars——世界系核心直入、视图薄壳供水反射路径，2026-10 天空分支世界方向单次化；LUT 纹素
// 角尺寸装不下这类高频内容），不进 LUT
//
// sky-view LUT（移植自春雷 Hillaire 非线性参数化，Sébastien Hillaire, EGSR 2020）：每帧在
// colortex7 左下角 200×200 重算（日 / 月半区各 200×100 ≈ 2% 屏幕成本），替代逐像素解析求值；
// 采样端只做一次双线性。球对称大气 + 单光源下天空色由 (视线天顶余弦, 视线-光源水平投影夹角
// 余弦) 完全决定——精确 2D 表示、每光源独占一个半区：
//   a ∈ [0,1] 方位角（sqrt 使纹素向光源侧集中，分辨率 SKYVIEW_LUT_W = 200）、
//   v ∈ [0,1] 天顶角（上 / 下半段各一段 sqrt 使纹素向地平线集中，分辨率 SKYVIEW_LUT_H = 100）、
//   参数域线性映射首末纹素中心（半纹素内缩）：采样不越区域边界、与相邻槽位不串色
// 依赖由接入的 program 先行 include：uniforms.glsl（sunPosition / moonPosition / colortex7 的
//   gaux4 别名——本文件采样一律走 gaux 名，gbuffers 阶段亦可同样采样 /
//   cameraPosition / rainStrength / frameTimeCounter——getStars 闪烁）、constants.glsl（TAU、
//   大气常量、SKYVIEW_*、SKYBOX_LUT_SIZE、SUN_DISK_* / MOON_DISK_* / STARS_*）、
//   utils/space.glsl（viewToWorldDirection）、utils/packing.glsl
//   （encode/decodeOctahedral——云层天空盒映射对）、utils/noise.glsl（hash13 / hash33——
//   getStars 立方体网格分格）、atmosphere.glsl（物理核心，仅解析路径与
//   LUT 生成端使用 + 日月盘 / 星盘的 planetHitDistance / opticalDepthToSpace）
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
// 云层天空盒右侧（SKYVIEW_LUT_ORIGIN_X）；composite12 的 vsh 光栅包围盒扩展与采样端共用
vec4 skyViewLutRegionRect() {
    vec2 texel = 1.0 / vec2(textureSize(gaux4, 0));
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
    return textureLod(gaux4, rect.xy + localUv * rect.zw, 0.0).rgb;
}

// LUT 尚未生成或缓冲重建时的轻量天空：只在首帧 / 无效槽位使用，不替代正常 Chapman 天空。
vec3 fallbackSkyColor(vec3 dirWorld, vec3 sunDirWorld) {
    float day = smoothstep(-0.10, 0.25, sunDirWorld.y);
    vec3 ambientRadiance = mix(NIGHT_SKY_AMBIENT, DAY_SKY_AMBIENT, day) / PI;
    float hemisphere = mix(0.18, 1.0, smoothstep(-0.15, 0.55, dirWorld.y));
    return ambientRadiance * (0.45 * SKY_BRIGHTNESS * hemisphere);
}

// 天空色采样：世界系核心（dirWorld 须已归一化）——已持世界系归一方向的调用方（fog.glsl 的
// boundaryFogColor）直入本函数，免「世界→视图→世界」mat3 往返与重复 normalize（2026-09 拆出）；
// 机制注释见下方 getSkyColor 包装（两入口同一实现 = 采样链单真源）
vec3 getSkyColorWorld(vec3 dirWorld, vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
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

// 天空色采样入口（视图系方向的归一化薄壳，转世界系后委托 getSkyColorWorld）：现有消费方
//（deferred_init 天空分支 / fog 雾色 / water 反射）均持世界系方向直入核心（2026-10 天空分支
// 世界方向单次化），本壳留作未来视图系调用方的入口
// dirView 视图空间方向（不要求归一化）；光源方向 / horizon / lutValid 均由调用方从 vsh 帧数据
// 传入；返回线性 HDR，SKY_BRIGHTNESS 已在生成端乘入。日 / 月两半区和式（春雷同构），非活动半区
//（光源低于 SKY_LIGHT_MIN_HEIGHT、生成端整区写 0）以同一常量门控跳过参数化与 fetch——不变式
//「采样端跳过 ⊆ 生成端写黑」由两侧共用常量保证；LUT 内容滞后一帧（composite12 在 deferred 后执行）
vec3 getSkyColor(vec3 dirView, vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    return getSkyColorWorld(normalize(viewToWorldDirection(dirView)),
                            sunDirWorld, moonDirWorld, horizon, lutValid);
}

// ---------- 云层天空盒（八面体，CLOUDS_2D 门控；colortex7 [0,SKYBOX_LUT_SIZE)² 原点 (0,0)） ----------

// 反射路径的烘焙云层（2026-09「反射不硬算云」的替代路线落地，2026-10）：composite12 每 texel
// 全量 getPlanarCloudsWorld 求值写入（rgb = 预乘散射、a = 透射率），消费端（water 的
// waterSkyReflection）按反射方向单 fetch。天空本体不进烘焙（sky-view LUT 反射侧直采更清晰、
// 免八面体重采样），太阳盘不进烘焙（256² 纹素角尺寸 ~0.8° 装不下 ~2.2° 圆盘的解析锐度——
// 消费侧仍走 getSunDisk，云在其后合成、镜中日盘同被云遮挡）。映射对 = packing.glsl 的
// encode/decodeOctahedral（单真源）+ lutParamToTexelCenter 半纹素内缩（与 sky-view LUT 同纪律：
// bilinear 永不越出槽位区域）；生成端 cloudSkyboxDir 与采样端 sampleCloudSkybox 互逆、成对维护

#ifdef CLOUDS_2D

// 生成端逆映射：天空盒纹素 local ∈ [0,SIZE)² → 世界系方向（composite12 云天空盒分支逐 texel
// 调用，方向交 getPlanarCloudsWorld 求值）
vec3 cloudSkyboxDir(ivec2 local) {
    vec2 oct = (vec2(local) + 0.5) / float(SKYBOX_LUT_SIZE);
    return decodeOctahedral(oct);
}

// 采样端：世界系方向（归一化）→ 天空盒 bilinear fetch，返回 (预乘云散射 rgb, 透射率 a)。
// 内容为上帧 composite12 烘焙（滞后一帧与 sky-view LUT 同批）；八面体接缝处 bilinear 会混到
// 球面上相距甚远的两 texel（低频云不可分辨，gbuffer 八面体法线同款取舍）
vec4 sampleCloudSkybox(vec3 dirWorld) {
    vec2 texel = 1.0 / vec2(textureSize(gaux4, 0));
    vec2 oct = encodeOctahedral(dirWorld);
    vec2 localUv = vec2(lutParamToTexelCenter(oct.x, float(SKYBOX_LUT_SIZE)),
                        lutParamToTexelCenter(oct.y, float(SKYBOX_LUT_SIZE)));
    return textureLod(gaux4, localUv * vec2(float(SKYBOX_LUT_SIZE)) * texel, 0.0);
}
#endif

// 太阳盘（线性 HDR，deferred_init 天空分支在 getSkyColor 之后、云合成之前解析叠加——LUT 纹素
// 角尺寸远大于圆盘、只能解析绘制；先于云叠加 = 云 alpha 遮挡太阳）。颜色与地面直射光同源同式：
// SOLAR_IRRADIANCE × 沿视线大气透射率（视线对准太阳时与 vDirectTransmittance 同一条 opticalDepth-
// ToSpace 路径，日落红化与场景阳光色一致）× 雨天衰减（与 vDirectIrradiance 同系数）。origin 取
// 相机海拔近似（球对称大气下与水平位置无关，与通用全屏 vsh 的地平线几何同款 r 式）
// 地平线遮挡 = planetHitDistance：视线与地球相交即地表以下、无太阳——太阳沉没时圆盘下缘视线
// 陆续穿地被硬切，掠射带透射率已自然衰减到黑、切割处无亮度跳变；不乘 vNoonFactor 时间门（那是
// 光照切换黑过渡的语义，在高度 0→0.05 提前熄灭直射光——几何可见性交给本遮挡判定，红日出完整
// 呈现）。角距离在 1−cos 域度量（mu ≈ 0.99998 时 cos 域差仅 ~1e-5、逼近 float32 精度，1−cos 保
// 留相对精度）；远离圆盘的视线于角距离早退——绝大多数天空像素只付 1 dot（世界方向由调用方与
// LUT / 月盘 / 星盘 / 云共享一次归一，2026-10 天空分支世界方向单次化）
// dirWorld 世界系归一化视线；sunDirWorld 世界系归一化
vec3 getSunDiskWorld(vec3 dirWorld, vec3 sunDirWorld) {
    float mu = dot(dirWorld, sunDirWorld);

    // 1−cos 域边界：盘芯（全亮）与盘外（全黑），常数折叠一次
    float edgeInner = 1.0 - cos(SUN_DISK_RADIUS);
    float edgeOuter = 1.0 - cos(SUN_DISK_RADIUS + SUN_DISK_SOFTEN);
    float d = 1.0 - mu;
    if (d > edgeOuter)
        return vec3(0.0);

    float r = EARTH_RADIUS + max(cameraPosition.y, 1.0);
    if (planetHitDistance(r, dirWorld.y) < 1e29)
        return vec3(0.0); // 视线打到地面（含掠地平线下沿）——地表以下无太阳

    float disk = 1.0 - smoothstep(edgeInner, edgeOuter, d);
    vec3 transmittance = exp(-opticalDepthToSpace(r, dirWorld.y));
    return SOLAR_IRRADIANCE * transmittance * (SUN_DISK_BRIGHTNESS * disk)
         * (1.0 - SUN_DISK_RAIN_FADE * rainStrength);
}

// 视图系薄壳（消费方 = water 反射的 waterSkyReflection，持反射观察系方向）：归一化转世界系后
// 委托 getSunDiskWorld；dirView 不要求归一化
vec3 getSunDisk(vec3 dirView, vec3 sunDirWorld) {
    return getSunDiskWorld(normalize(viewToWorldDirection(dirView)), sunDirWorld);
}

#ifdef MOON_DISK
// 月亮盘（线性 HDR，满月圆盘、无月相 / 贴图）：与 getSunDisk 同构同纪律——太阳盘条目所述机制
// 全量适用（1−cos 域角距离 + 远盘早退、planetHitDistance 地平线硬切、沿视线透射率红化、雨衰）。
// 亮度 = MOON_IRRADIANCE × 透射率 × 视觉增益（MOON_DISK_BRIGHTNESS）：色度与地面月光同源——
// 月下场景直射色与月盘自动一致，月出红化物理呈现；不乘 nightFactor 时间门（几何可见性交给
// planetHitDistance，太阳盘同款——红月出完整呈现）。白天月亮在地平线下（日月恰好相对）、
// 被地平线遮挡整段早退，零成本。世界系核心（dirWorld 须已归一化——deferred_init 共享方向直入，
// 2026-10 天空分支世界方向单次化）+ 视图薄壳（消费方 = water 反射路径）
vec3 getMoonDiskWorld(vec3 dirWorld, vec3 moonDirWorld) {
    float mu = dot(dirWorld, moonDirWorld);

    float edgeInner = 1.0 - cos(MOON_DISK_RADIUS);
    float edgeOuter = 1.0 - cos(MOON_DISK_RADIUS + MOON_DISK_SOFTEN);
    float d = 1.0 - mu;
    if (d > edgeOuter)
        return vec3(0.0);

    float r = EARTH_RADIUS + max(cameraPosition.y, 1.0);
    if (planetHitDistance(r, dirWorld.y) < 1e29)
        return vec3(0.0); // 视线打到地面——地表以下无月亮

    float disk = 1.0 - smoothstep(edgeInner, edgeOuter, d);
    vec3 transmittance = exp(-opticalDepthToSpace(r, dirWorld.y));
    return MOON_IRRADIANCE * transmittance * (MOON_DISK_BRIGHTNESS * disk)
         * (1.0 - MOON_DISK_RAIN_FADE * rainStrength);
}

vec3 getMoonDisk(vec3 dirView, vec3 moonDirWorld) {
    return getMoonDiskWorld(normalize(viewToWorldDirection(dirView)), moonDirWorld);
}
#endif

#ifdef STARS
// 星盘（线性 HDR，立方体网格 hash 点星——零贴图资产 / 零新缓冲）：星图与月固连——视线方向绕
// 世界 Z 把月亮 xy 相位旋回 +X 后作 hash 输入（旋转由月亮方向 xy 归一构造、零超越函数），
// 任意天球姿态下「星-月夹角恒定」结构性成立：星星随月东升西落、相对位置不动（天球旋转相位由
// 月亮方向锚定推导，无须知道轨道倾角 / sunAngle；MC 日月恰好相对 ⇒ 亦与太阳同步）。夜门 =
// 太阳高度 smoothstep 渐显（白天 / 暮光前段于门处整段早退、只付 1 dot）；地平线以下视线打到
// 行星无星（日月盘同款判定，置于 hash 门之后——仅稀疏幸存格子付 planetHit）；雨天淡出。
// 星星不随主导光源阴影门控（恒星无对应遮蔽信息，桥影挡月光不挡星光）。仅 deferred_init 主天空
// 消费——世界系入参（dirWorld 由调用方与 LUT / 日月盘 / 云共享一次归一，2026-10 天空分支世界
// 方向单次化）；water 反射不渲染星盘（2026-10 按反馈：星点经波面法线搅碎 + Fresnel 低透过率后
// 不可辨）。
// 末地消费（2026-10 星盘接入末地）：deferred_init 极简档内 #if defined(END) && defined(STARS)
// 同源调用——夜门常开（末地 fixed_time 定格正午、太阳高度门恒关，而末地是无昼夜循环的暗夜虚空）
// + planetHit 切割剔除（虚空世界无地平线语义、星图覆盖全球——否则眼平面把虚空天空硬切成
// 有星 / 无星两半）；主世界档逐位不变，下界不接入（封闭洞窟无天）
// 早退链：夜门 → 旋转 → hash 门（1 − STARS_DENSITY 的格子直接 return）→
// planetHit → 点星；绝大多数夜空像素只付 1 dot + 4 mul + 1 hash
vec3 getStars(vec3 dirWorld, vec3 sunDirWorld, vec3 moonDirWorld) {
#ifdef END
    float nightGate = 1.0; // 末地永夜：门常开、星空恒显（sunDirWorld 本档无消费）
#else
    float nightGate = 1.0 - smoothstep(STARS_FADE_LOW, STARS_FADE_HIGH, sunDirWorld.y);
    if (nightGate <= 0.0)
        return vec3(0.0);
#endif

    // 星图方向：绕世界 Z 旋回月亮相位（R(−θ)，θ = atan2(m.y, m.x)——cosθ/sinθ 由归一 xy 直接
    // 给出，免 atan）；月轨倾角 30° 下 |moon.xy| ≥ 0.5 恒远离退化，守卫仅防御性
    vec2 anchor = moonDirWorld.xy;
    float anchorLen = length(anchor);
    vec2 rot = anchorLen > 1e-4 ? anchor / anchorLen : vec2(1.0, 0.0);
    vec3 starDir = vec3(dirWorld.x * rot.x + dirWorld.y * rot.y,
                        -dirWorld.x * rot.y + dirWorld.y * rot.x,
                        dirWorld.z);

    // 立方体网格分格：格 hash 门稀疏化 + 格内随机偏移点星（偏移钳 [0.25,0.75] 星形完整不出格）
    vec3 sp = starDir * STARS_GRID_SCALE;
    vec3 cell = floor(sp);
    float cellRand = hash13(cell);
    if (cellRand > STARS_DENSITY)
        return vec3(0.0);

#ifndef END
    float r = EARTH_RADIUS + max(cameraPosition.y, 1.0);
    if (planetHitDistance(r, dirWorld.y) < 1e29)
        return vec3(0.0); // 地平线以下——地表背面无星
#endif

    vec3 h3 = hash33(cell);
    float d = length(sp - cell - (vec3(0.25) + 0.5 * h3));
    float point = clamp(1.0 - d * STARS_FALLOFF, 0.0, 1.0);
    point *= point; // 平方衰减：中心亮、边缘速灭（亚像素过渡交 TAA）

    // 亮度：幂分布（多数暗星少数亮星）+ 正弦闪烁（逐星相位 h3.y）
    float magnitude = 0.2 + 0.8 * h3.z * h3.z;
    float twinkle = 1.0 - STARS_TWINKLE_DEPTH
                  * (0.5 + 0.5 * sin(frameTimeCounter * STARS_TWINKLE_SPEED * TAU + h3.y * TAU));
    return vec3(STARS_BRIGHTNESS * magnitude * point * twinkle * nightGate
              * (1.0 - STARS_RAIN_FADE * rainStrength));
}
#endif

// ---------- 生成端（composite_bloom_upsample / composite12） ----------

// 解析天色（世界系方向直接求值 Chapman + 环境场 MS）：LUT 生成核心，也是解析路径的完整保留。
// observerRadius / lightOpticalDepth / ambientField（atmosphere.glsl 的 skyAmbientField）由
// composite12 vsh 每帧预计算，避免每个 LUT texel 重复相机半径、光源路径 Chapman 与 48 节点求积
// SKY_CLAMP_TO_HORIZON（春雷 GetSkyView 同位语义）：地平线以下方向的散射路径钳到与地球正好相切的
// 观察者地平线切线、钳后射线一律按未命中求值（机制与刀锋数值防护见 atmosphere.glsl 的
// clampDirectionToHorizon 头注）；相位透传未钳制的 dirWorld——Rayleigh / Mie 的 mu 保角向变化，
// 地平线以下的 LUT 行因此 = 地平线辉光 × 按真实方向的相位调制，采样端（getSkyColor）零改动
vec3 skyRadianceAnalytic(float observerRadius, vec3 dirWorld, vec3 lightWorld,
                         vec3 lightOpticalDepth, vec3 irradiance, vec3 ambientField) {
    vec3 origin = vec3(0.0, observerRadius, 0.0);
    vec3 rayDir = dirWorld;
    float t;
#ifdef SKY_CLAMP_TO_HORIZON
    bool clampedToHorizon;
    rayDir = clampDirectionToHorizon(observerRadius, dirWorld, clampedToHorizon);
    t = clampedToHorizon ? SKY_NO_HIT : planetHitDistance(observerRadius, rayDir.y);
#else
    t = planetHitDistance(observerRadius, rayDir.y);
#endif
    vec3 transmittance; // 视线路径透射率 out 占位（天空色只消费散射项）
    return atmosphericRadiance(origin, rayDir, dirWorld, lightWorld, lightOpticalDepth, t, irradiance,
                               ambientField, transmittance)
         * SKY_BRIGHTNESS;
}

// 生成端共用的局部系方向逆映射：纹素中心参数 (azimuthParam, zenithParam) → 局部系方向——
// 「光源水平投影 = +X、光源位于 XY 平面内」的局部系构造（球对称大气的散射只依赖 (vzc, szCos,
// mu)，与真实方位仅差绕天顶旋转、结果等价）。sky-view 半区（下方 skyViewLutTexel）与 aerial LUT
//（aerial.glsl 的 aerialLutTexel，须于本文件之后引入）共用本函数——逆映射公式单真源（曾两处
// 成对维护，2026-10 收敛）；与采样端 skyViewLutAzimuthParam / skyViewLutZenithParam 互逆
vec3 skyViewLutLocalDirection(float azimuthParam, float zenithParam, vec3 horizon) {
    float beta = horizon.y;
    float zenithHorizon = horizon.z;

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

    return vec3(vzSin * lvCos, vzc, vzSin * lvSin);
}

// 半区 texel → 天色：local.x ∈ [0, SKYVIEW_LUT_W)（a = 0 在光源侧）、local.y ∈ [0, SKYVIEW_LUT_H)
//（j = 0 为天顶行——半区靠缓冲底边的行，与采样端 y 映射互逆）；ambientField 为 vsh 预计算的
// 多次散射环境场（透传给 skyRadianceAnalytic）
vec3 skyViewLutTexel(ivec2 local, float observerRadius, vec3 horizon,
                     vec3 lightWorld, vec3 lightOpticalDepth, vec3 irradiance,
                     vec3 ambientField) {
    // 纹素中心参数（采样端 skyViewLutAzimuthParam / skyViewLutZenithParam 的逆映射）
    float azimuthParam = float(local.x) / float(SKYVIEW_LUT_W - 1);
    float zenithParam = float(local.y) / float(SKYVIEW_LUT_H - 1);

    float szCos = clamp(lightWorld.y, -1.0, 1.0);
    float szSin = sqrt(max(1.0 - szCos * szCos, 0.0));

    vec3 localLight = vec3(szSin, szCos, 0.0);
    return skyRadianceAnalytic(observerRadius,
                               skyViewLutLocalDirection(azimuthParam, zenithParam, horizon),
                               localLight, lightOpticalDepth, irradiance, ambientField);
}

#endif
