// 全部常量集中声明，程序与其他 lib 文件不再自行定义
// lib 文件之间不互相 include，本文件由 program 直接引入（须在 lib/common/pipeline/varying_io.glsl 之前，
// remapLightmap 依赖这里的常量）；OptiFine/Iris 扫描 include 展开后的内容
#ifndef LIB_CONSTANTS_GLSL
#define LIB_CONSTANTS_GLSL

// 颜色缓冲像素格式名称占位声明，供下方 colortexNFormat 常量指令引用
const int RGBA16  = 0;
const int RGBA16F = 0;
const int R11F_G11F_B10F = 0;

// ---- 通用 ----
const float TAU            = 6.28318530718;
const float PI             = TAU * 0.5;
const float GOLDEN_ANGLE    = 2.39996323;   // 黄金角（弧度）：黄金螺旋采样（阴影 PCF 等）
const float ALPHA_CUTOUT   = 0.5;           // cutout 透贴裁剪阈值
const float ambientOcclusionLevel = 0.0;    // 引擎指令：关闭原版 AO（光照由光影接管，不叠原版顶点暗角）
const float LIGHTMAP_MIN   = 1.0 / 32.0;    // 原版光照图坐标下限
const float LIGHTMAP_SPAN  = 15.0 / 16.0;   // 原版光照图有效跨度（上限 = MIN + SPAN = 31/32）

// ---- 缓冲格式 ----
const int colortex0Format = RGBA16F; // 场景颜色
const int colortex1Format = R11F_G11F_B10F; // bloom tile 图集（链式下采样 + 渐进上采样金字塔，composite4~12 写入，final 合成）：无符号浮点 11/11/10、无 alpha，较 RGBA16F 显存带宽减半；COD 下采样核的小负瓣写入时钳 0，bloom 视觉无损
const int  colortex3Format = RGBA16F; // TAA 历史缓冲：rgb = 上帧混合色（线性 HDR），a = 上帧最近片元线性深度（解遮挡置信）
const bool colortex3Clear  = false;   // 历史跨帧存活；仅 composite_taa（composite3）读写（单程序独占 ping-pong，不依赖 flip.*）
const int colortex4Format = RGBA16;  // gbuffer: 打包 albedo + 打包高光贴图（位打包需无符号格式）
const int colortex5Format = RGBA16;  // gbuffer: 八面体观察空间法线 + 原始 lmcoord
const int colortex7Format = RGBA16F; // 杂项数据（左下角杂项簇，布局见 SKYBOX_LUT_SIZE / SKYVIEW_LUT_* 常量）：预留天空盒 256×256 + 天空 view LUT 200×200（太阳半区 200×100 + 月亮半区 200×100）+ 曝光槽位 1 texel（exposure.glsl 的 exposureTexel）= 自适应曝光
const bool colortex7Clear = false;   // 曝光值跨帧存活；colortex7 写入者须透传其光栅化区域内非槽位像素（composite12 = 图集包围盒 ∪ 天空 LUT 区域的包围矩形整写，见 lib/post/exposure.glsl）

// ---- 天空 / 大气（lib/atmosphere/atmosphere.glsl + sky.glsl）----
const float SKY_TEXTURE_BRIGHTNESS = 4.0; // 太阳 / 月亮贴图发光补偿（日月贴图程序 gbuffers_sky_tex，暂未链接）

// colortex7 左下角杂项簇布局（texel 域，锚定 texel (0,0) 角 = 屏幕左下）：预留天空盒占最角上、
// 天空 view LUT 200×200 水平相邻、曝光槽位在二者 4 texel 间隔 gutter 内（exposure.glsl）；
// 固定 texel 布局假设缓冲 ≥ ~480×260（实际渲染分辨率下限远高于此）
const int SKYBOX_LUT_SIZE      = 256; // 预留：天空盒槽位边长（八面体世界方向 → 天空色，扩展点；春雷 begin19 skybox_lut 同尺寸）
const int SKYVIEW_LUT_W        = 200; // 天空 view LUT 半区宽 = 视线-光源方位角参数化分辨率（春雷 skyViewLutSize 同值）
const int SKYVIEW_LUT_H        = 100; // 天空 view LUT 半区高 = 天顶角参数化分辨率；太阳（上半区）/ 月亮（下半区）纵向堆叠 = 200×200
const int SKYVIEW_LUT_ORIGIN_X = SKYBOX_LUT_SIZE + 4; // LUT 区域原点 x（texel）= 260：预留天空盒右侧 4 texel 间隔，区域锚定缓冲底边

// Chapman 解析单次散射（移植自 Shadertoy WcdSW4，MIT，John Payne 2024，https://www.shadertoy.com/view/WcdSW4 ）
// 密度模型为 r² 高斯 exp(-(r²-R²)/H²)，H 是大数值参数化、不是物理尺度高度——
// 有效尺度高度 = H²/(2R) ≈ Rayleigh 8.05km / Mie 1.54km / 臭氧 16.3km，即地球真实量级
const float EARTH_RADIUS = 6360e3;    // 行星半径（米）
const float SKY_NO_HIT   = 1e30;      // 视线未命中行星的哨兵距离（替代 inf：编译期 1/0 在部分驱动上未定义）
const float RAYLEIGH_SCALE_HEIGHT = 320000.0;                                 // Rayleigh 参数 H（有效 8.05km）
const vec3  RAYLEIGH_SCATTERING_COEFFICIENTS = vec3(6.384e-6, 12.00e-6, 28.74e-6); // 散射 = 消光（瑞利无吸收）
const float MIE_SCALE_HEIGHT = 140000.0;                                      // Mie 参数 H（有效 1.54km）
const vec3  MIE_SCATTERING_COEFFICIENTS = vec3(1.252e-6, 1.689e-6, 2.530e-6);
const vec3  MIE_EXTINCTION_COEFFICIENTS = MIE_SCATTERING_COEFFICIENTS * 1.11; // 消光 = 散射 × 1.11（气溶胶吸收 ~10%）
const float OZONE_SCALE_HEIGHT = 455000.0;                                    // 臭氧参数 H（有效 16.3km），纯吸收、日落修色
// 臭氧系数按 Chappius 吸收带真实截面定形：680/550/440nm 截面 = 1.368/3.314/0.136 ×10⁻²⁵ m²（293K，绿重于红、峰值 ~575nm），
// 光谱数据 https://www.iup.physik.uni-bremen.de/gruppen/molspec/databases/referencespectra/o3spectra2011/index.html ；
// 截面值与 6ppm 浓度取法参考 Shadertoy『Scattering with Ozone』（reinsteam 2017，CC BY-NC-SA，
// https://www.shadertoy.com/user/reinsteam ，其层状臭氧等效垂直 τ = 0.018/0.044/0.002）。
// WcdSW4 原系数 (2.824, 1.683, 0)e-6 光谱形状相反（R>G）：地平线长路径上红衰减快于绿，日出天空整体发黄
// （数值验证：太阳 +2° 朝太阳地平线线性 R/G 1.74 → 3.86，即黄 → 橙）；本组锚定垂直 τ550 ≈ 0.04
// （真实大气 ~0.03 + 适量风格化对齐参考版 0.044；白天天空色数值验证基本不变）
const vec3  OZONE_EXTINCTION_COEFFICIENTS = vec3(1.021e-6, 2.474e-6, 1.015e-7);
const vec3  SOLAR_IRRADIANCE = vec3(236.8, 206.4, 204.9);                     // 大气顶太阳辐照度（相对单位）
const vec3  MOON_IRRADIANCE  = SOLAR_IRRADIANCE * 5.0e-4; // 大气顶月亮辐照度（春雷同值 2.5e-6×2e2：真实满月 ~1/40万，游戏取 ~1/2000 保夜景可见；天空 LUT 月亮半区光源）
const float SKY_BRIGHTNESS   = 1.0;  // 天空色整体缩放：对齐 albedo 0~1 的画面量级（进游戏后校准）
const float SKY_LIGHT_MIN_HEIGHT = -0.15; // LUT 光源低于地平线约 8.6° 后散射已不可见，整半区写 0 跳过 Chapman 求值；采样端 getSkyColor 以同一常量门控跳过该半区的参数化与 fetch——安全不变式「采样端跳过区域 ⊆ 生成端写黑区域」由两侧共用本常量结构性保证，绝不在采样端写独立数值。数值验证（海平面 ~ 山顶不变）：可见曙暮光弧的衰减悬崖在 -0.05 ~ -0.10（7 个数量级），本阈值深居死区（阈值处天空最大 luma ~5e-9，×720 曝光上限后仍低于 8bit LSB 三个数量级），隔帧光源移动 0.005° 的边界差不可见
const float SKYVIEW_LUT_VALID_MARKER = 0.625; // LUT alpha 有效标记（RGBA16F 精确值），区别于清零 / 旧版 alpha=1 / 未初始化内容
// float32 数值防护（夜晚 / 下视溢出的根源是 erfcx 负参量分支 exp(b²)、b 可达 r/H ~ 45 → b² ~ 2000 溢出 Inf）
const float SKY_ERFCX_EXP_MAX = 80.0; // erfcx 负支 exp 上限：2·e^80 ≈ 1.1e35 有限，对应光学深度早已全遮蔽、钳顶无损
const float SKY_AIRMASS_MAX   = 1e15; // airMass 钳制上限：τ = βmax·1e15 ≈ 2.9e10 → exp(-τ) = 0；兼杀下视掠射闭式相消的负值 / NaN 垃圾。
// 上限刻意远高于「exp 归零」所需：太阳沉入地平线后 sun 路 airMass 饱和于本值、tauS 停止增长，
// energyIntegralRatio 的 (e^-a - e^-b)/(b-a) 残留 ~e^-tauV/tauS 尾巴——上限偏低时夜空冻结成恒定亮度地板
// （1e9 时 ≈ 2e-4 luma，夜间自动曝光逼近 720× 上限后放大成可见辉光；月亮半区置黑也治不了，光在太阳半区）；
// 1e15 把地板压到 ~2e-10（曝光上限内不可见）。白天 / 曙暮光主段 airMass < 1e6 完全不触及钳制，数值不变
// Mie 相函数 = HG(g1) 与 Draine(g2, a) 按权重 w 混合（Shadertoy 原调参，前向峰 + 适度后向）
const float MIE_PHASE_G1 = 0.862;              // HG 主叶前向强度
const float MIE_PHASE_G2 = 0.5069161813017329; // Draine 次叶
const float MIE_PHASE_A  = 250.0;              // Draine 各向异性因子
const float MIE_PHASE_W  = 0.24075857115188248; // 混合权重

// 各向同性环境场多次散射（atmosphere.glsl 的 skyAmbientField / atmosphericRadiance MS 项）：
// 二阶起近似为各向同性辐射场，量级 = 一阶散射天光球面方向平均（48 节点光源锚定环带求积，
// composite12 vsh 每帧每光源一次）× 几何级数 1/(1-ρ)；视线端 MS 项 = ambientCapture × 环境场，
// 路径量全部复用单次散射已算的 airMass。float32 数值验证（海平面、太阳 +60° 正午）：
// 余弦加权天光辐照度 ×1.069/×1.116/×1.260（R/G/B）、天顶 ×1.10~1.17、反日侧暮光地平线
// ×1.6~1.7、太阳侧 ×1.16~1.41；夜空地板不被抬高（太阳 -20° 最大 luma 5.1e-10，×720 曝光后不可见）
const float SKY_MS_STRENGTH     = 1.0; // MS 整体强度（0 = 退回纯单次散射）；偏好更强暮光弧 / 地平线抬升可上调，参考范围 1.0~2.0
const int   SKY_MS_QUAD_BANDS    = 8;   // 环境场球面求积环带数（Δcosθ 等间距 = 等立体角；最内环带节点 θ ≈ 29°，避开 Mie 窄前向峰）
const int   SKY_MS_QUAD_AZIMUTHS = 6;   // 每环带方位节点数（带间黄金角错位防与光源几何对齐）；× BANDS = 48 节点
const float SKY_MS_CAPTURE_MAX   = 0.9; // 截获比 ρ 钳顶（海平面实测 ≤ ~0.30，防御极端海拔 / 数值垃圾撑爆几何级数分母）

// ---- 信标光柱（gbuffers_beacon，春雷同值）----
const float ALPHA_BEACON_CORE    = 254.1 / 255.0; // 不透明核心判定阈值（a >= 此值整像素写 gbuffer）
const float BEACON_CORE_EMISSIVE = 240.0 / 255.0; // 核心自发光强度（写入 specular.a，labPBR emissive）

// ---- Bloom（lib/post/bloom.glsl，无阈值，整幅 HDR 直接进金字塔）----
const float BLOOM_STRENGTH = 0.15; // 泛光合成强度（tonemap 前线性域加法）
const float BLOOM_BLUR_STEP = 2.0; // 下采样 tap 步长（源纹素数，春雷同值）：最大 tap 偏移为 ±2×此值（当前 ±4 源纹素）；总模糊半径由上采样回卷逐级累积保证，单级无需大步长（步长 4 在高频画面上跨步混叠，反而给图集带入网格）
const float BLOOM_WEIGHTS[5] = float[5](1.0, 0.75, 0.55, 0.40, 0.30); // 各级权重（tile0 最锐 → tile4 最宽），上采样回卷相加时施加（bloomUpsampleTile）
const float BLOOM_WEIGHT_SUM = 3.0; // ΣBLOOM_WEIGHTS；getBloom 归一化，修改权重时同步更新

// ---- Tonemap（lib/post/tonemap.glsl，AgX，春雷同值）----
const float AGX_ADDITIVE = 0.6;       // AgX 曲线预缩放（与曝光系数各司其职：曝光在 tonemap 前整体乘）
const float min_ev       = -12.47393; // AgX log2 窗口下界
const float max_ev       = 4.026069;  // AgX log2 窗口上界

// ---- 自动曝光（lib/post/exposure.glsl，亮度算法春雷同值）----
const float AUTO_EXPOSURE_RATE          = 2.0;     // 适应速度（1/s）：mix 因子 1 - exp(-frameTime * RATE)，帧率无关
const float AUTO_EXPOSURE_KEY_VALUE     = 0.18;    // 目标亮度（18% 灰 key），targetExposure = KEY / avgLum
const float AUTO_EXPOSURE_MIN_LUMINANCE = 0.00025; // log 下限保护，兼把曝光上限约束到 KEY / 此值 = 720（半精度安全）
const int EXPOSURE_SAMPLE_COUNT = 16;              // 测光采样数：槽位 fragment 的测光成本与分辨率解耦（全遍历在 4K 下 2000+ fetch）
// 均匀随机采样核：4×4 抖动网格（每单元一个随机点），全域覆盖、无聚集，读取端映射回 tile4；固定核保证帧间稳定
const vec2 EXPOSURE_SAMPLE_KERNEL[16] = vec2[16](
    vec2(0.063, 0.061), vec2(0.302, 0.106), vec2(0.574, 0.038), vec2(0.811, 0.152),
    vec2(0.148, 0.306), vec2(0.421, 0.273), vec2(0.687, 0.342), vec2(0.934, 0.289),
    vec2(0.091, 0.537), vec2(0.356, 0.618), vec2(0.609, 0.555), vec2(0.873, 0.641),
    vec2(0.219, 0.766), vec2(0.473, 0.824), vec2(0.742, 0.779), vec2(0.951, 0.898)
);

// ---- TAA（lib/common/utils/jitter.glsl + lib/post/taa.glsl）----
const float TAA_JITTER_SCALE = 1.0;  // jitter 幅度缩放（1.0 = 满幅 ±0.5 px，即 1 px 跨度；降低可换锐度）
// Halton(2,3) 16 相位序列，像素域 [-0.5, 0.5]（春雷同表）；查表纯 GLSL 实现，不依赖 properties 自定义 uniform（旧版 OptiFine 兼容）
const vec2 TAA_JITTER_SAMPLES[16] = vec2[16](
    vec2( 0.0,    -0.16666667), vec2(-0.25,    0.16666667),
    vec2( 0.25,   -0.38888889), vec2(-0.375,  -0.05555556),
    vec2( 0.125,   0.27777778), vec2(-0.125,  -0.27777778),
    vec2( 0.375,   0.05555556), vec2(-0.4375,  0.38888889),
    vec2( 0.0625, -0.46296296), vec2(-0.1875, -0.12962963),
    vec2( 0.3125,  0.20370370), vec2(-0.3125, -0.35185185),
    vec2( 0.1875, -0.01851852), vec2(-0.0625,  0.31481481),
    vec2( 0.4375, -0.24074074), vec2(-0.46875, 0.09259259)
);
const float TAA_HISTORY_SHARPNESS   = 0.65; // 历史 Catmull-Rom 锐化系数（春雷 0.6 / 春v2 低配版 0.8 之间）
const float TAA_CLIP_GAMMA          = 1.5;  // 方差钳制 γ 基础值（深度置信度高时用）；十字 5-tap 统计较 3×3 盒略粗，γ 抬一档补偿
const float TAA_CLIP_GAMMA_MAX      = 2.25; // 深度置信度低时的放宽上限（防鬼影，春雷自适应同思路）
const float TAA_TONEMAP_DOMAIN_MAX  = 0.995; // 钳制盒 Y 通道（tonemap 域 luma）上界帽：高对比边缘 μ+γσ 可越出 1，截到盒面会使 Y>1、逆变换分母变负被 1e-5 地板放大 1e5 倍（边缘极亮爆闪）；0.995 对应工作域 luma ~200，HDR 上限内无损
const float TAA_BLEND_BASE          = 0.05; // 当前帧基础权重（历史权重 0.95）
const float TAA_BLEND_MOTION        = 0.02; // 每像素速度的当前帧权重增量（运动收敛）
const float TAA_BLEND_DISOCCCLUSION = 0.4;  // 深度置信失效（解遮挡）时的当前帧权重增量
const float TAA_BLEND_MIN           = 0.02; // 当前帧权重下限（历史权重上限 0.98）
const float TAA_BLEND_HAND_MIN      = 0.1;  // 手部当前帧权重下限（防手部拖影）
const float TAA_HAND_DEPTH          = 0.56; // NDC 深度阈值：小于此值视为手（BSL / Photon 同值）
const float TAA_DEPTH_SENTINEL      = 65504.0; // 半精度上限：历史 a 通道深度钳制与天空像素的哨兵值
// 半精度上限：历史 a 通道深度钳制与天空像素（锚点 depth >= 1）的哨兵值——天空 ↔ 天空 |Δ|=0 满置信、天空 ↔ 几何相对差巨大自然归零（置信公式免分支，快速收敛）
const float TAA_DEPTH_CONF_EDGE0    = 0.02; // 深度置信 smoothstep 下沿（重投影深度 vs 历史 a 通道的相对差）
const float TAA_DEPTH_CONF_EDGE1    = 0.10; // 上沿

// ---- 光照（lib/lighting/lighting.glsl，已接入 deferred_init；直接光物理化，春雷 shading.glsl 同构）----
// 统一时间系统（program/fullscreen_vsh.glsl 一次算好经 varying 传入；春v2 isNoon/isNight、
// 春雷 isDay/isNight（shaders.properties 自定义 uniform）同构）：太阳 / 月亮各自世界高度的线性门
// clamp [0,1]。MC 日月恰好相对（moonHeight ≈ -sunHeight），两门永不同时为正——直射辐照度取门控
// 加权和，即「按光源选边 + 主光源切换瞬间（光源过地平线）两门同为 0、直射光为黑过渡」；
// 替代旧昼夜 mix（mix 在日出前就混入太阳辐照度，再被低角度透射率染红——晨昏直射光成了
// 「红色太阳光」而非黑色过渡）。月亮门斜率倍陡（春v2 NOON/NIGHT_DURATION 20/40 同值）：
// 月亮低角度时透射率已深红，门快速关闭把红月落压成暗过渡；太阳侧保留物理红化（红日出是预期）。
// 斜率 20 = 高度 0→0.05（约 2.9°）淡入。
const float TIME_NOON_RAMP  = 20.0; // 太阳直射门斜率（春v2 NOON_DURATION 同值）
const float TIME_NIGHT_RAMP = 40.0; // 月亮直射门斜率（春v2 NIGHT_DURATION 同值；斜率 40 = 0→0.025 约 1.4° 淡入）
// 直射 = albedo/π × (noon×SOLAR_IRRADIANCE + night×MOON_IRRADIANCE) × solarTransmittance(表面点 -> 光源) × NdotL × 阴影可见性；
// 大气顶辐照度直接复用大气常量（与天空 LUT 同源——sky:direct 亮度比物理一致，绝对量级随 SKY_BRIGHTNESS 与天空一起统调）；
// 环境光 / 方块光同为辐照度形式，与直射共用同一个 albedo/π
const float SKY_AMBIENT_BRIGHTNESS = 5.3; // 天空环境辐照度 = LUT 天顶色 × 本系数（fullscreen_vsh 的 vSkyAmbient 主路径）：天顶辐射率 → 半球环境辐照度换算 ≈ π × 1.7（π × 余弦加权天光平均 / 天顶的正午比值，含 MS），初值校准使正午幅度与旧 DAY_SKY_AMBIENT（luma ~9.0）一致——月夜同链缩放（月亮辐照度比 5e-4）恰近旧 NIGHT_SKY_AMBIENT；色调 / 幅度均取自天顶结果、昼夜 / 曙暮光 / 海拔自动跟进，进游戏统调天光亮度的主旋钮
const vec3 DAY_SKY_AMBIENT   = vec3(6.4, 8.9, 17.6);        // 白天天空环境辐照度回退值 ≈ π × 余弦加权天光平均辐射（由 sky LUT 正午量级推得：天顶 lum ~1.5 / 地平线 ~13；多次散射接入后按正午辐照度增幅 ×1.069/×1.116/×1.260 重定——见 SKY_MS_STRENGTH 注释）；vSkyAmbient 主路径已改为 LUT 天顶色 × SKY_AMBIENT_BRIGHTNESS（fullscreen_vsh.glsl），本常量仅在 LUT 无效的回退路径（vSkyAmbient 回退 / sky.glsl fallbackSkyColor）生效
const vec3 NIGHT_SKY_AMBIENT = DAY_SKY_AMBIENT * 5.0e-4;    // 夜晚回退值 = 月亮辐照度比（与 MOON_IRRADIANCE 同源，春雷 1/2000）；正常路径下天顶色随月亮辐照度同链缩放，夜晚过暗只抬 MOON_IRRADIANCE 单旋钮
const vec3 TORCHLIGHT_COLOR  = vec3(1.00, 0.52, 0.20) * PI; // 方块光辐照度（π × 旧 albedo 直乘时代的量级，行为不变）
const vec3 MIN_AMBIENT       = vec3(0.0035, 0.0040, 0.0055); // 全黑环境兜底（gameplay 地板，刻意低于物理夜天光），避免纯黑不可见

// ---- 阴影（program/shadow.glsl 写入端 + lib/lighting/shadow.glsl 采样端）----
// 引擎指令前五条（shadowMapResolution 系 / sunPathRotation / shadowHardwareFiltering0）由 OptiFine/Iris 扫描
const int   shadowMapResolution      = 2048;   // 阴影贴图边长（texel）；128m 距离下每米 8 texel，中心区经扭曲再放大约 6.7 倍
const float shadowDistance           = 128.0;  // 阴影覆盖半径（米）；采样端超出即返回 1 全亮（贴图覆盖外无阴影，lib/lighting/shadow.glsl）
const float shadowDistanceRenderMul  = 1.0;    // 超出 shadowDistance 的几何不进阴影渲染（省填充率——超距采样本就按全亮）
const float sunPathRotation          = -30.0;  // 太阳轨迹倾角（度，春雷同值）：正午太阳不过天顶、影子不退化；天空与光照方向自动一致
const bool  shadowHardwareFiltering0 = true;   // 仅 shadowtex0 开硬件深度比较（声明为 sampler2DShadow）；
                                              // shadowtex1 不开、保持 sampler2D 裸深度（仅不透明几何）——彩色阴影遮挡分离与
                                              // 未来 PCSS blocker search 共用的后路（春v2 同布置，引擎配置零改动可升级）
const float SHADOW_DISTORT_FACTOR = 0.85;  // 线性扭曲强度（春v2/BSL/Kappa 同族）：中心 factor = 1-此值 = 0.15、纹素密度放大约 6.7 倍，边缘 factor = 1 不缩放
const float SHADOW_DEPTH_SCALE    = 0.2;   // shadow clip z 压缩（BSL/Photon/Kappa 同值）：写读两侧对称，配合常数 bias 抑制痤疮
const int   SHADOW_PCF_SAMPLES    = 4;     // 黄金螺旋 tap 数（硬件比较自带 2×2 双线性，等效 32 次深度比较；IGN 时域旋转 + TAA 累积收敛）
const float SHADOW_RADIUS_BASE    = 0.25;   // 基础软半径（texel）
const float SHADOW_RADIUS_DIST    = 2.0;   // 随相机距离增长的半径上限（texel）
const float SHADOW_BIAS_NORMAL    = 0.05;  // normal offset 基数（世界单位，随距离 / 坡度放大，春v2 同思路）
const float SHADOW_BIAS_DEPTH     = 0.00005;// 压缩后深度域常数 bias（进游戏按痤疮 / 悬空影微调）

#endif
