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
const float GOLDEN_RATIO    = 0.61803398875; // 黄金比例共轭 1/φ（春v2 同值）：temporal 噪声帧间相位偏移（noise.glsl）
const float ALPHA_CUTOUT   = 0.5;           // cutout 透贴裁剪阈值
const float ambientOcclusionLevel = 0.0;    // 引擎指令：关闭原版 AO（光照由光影接管，不叠原版顶点暗角）
const float LIGHTMAP_MIN   = 1.0 / 32.0;    // 原版光照图坐标下限
const float LIGHTMAP_SPAN  = 15.0 / 16.0;   // 原版光照图有效跨度（上限 = MIN + SPAN = 31/32）

// ---- 缓冲格式 ----
const int colortex0Format = RGBA16F; // 场景颜色
const int colortex1Format = R11F_G11F_B10F; // bloom tile 图集（composite4~12 写）：无符号 11/11/10、无 alpha，较 RGBA16F 带宽减半；COD 核小负瓣写入钳 0 无损
const int  colortex3Format = RGBA16F; // TAA 历史缓冲：rgb = 上帧混合色（线性 HDR），a = 上帧最近片元线性深度（解遮挡置信）
const bool colortex3Clear  = false;   // 历史跨帧存活；仅 composite_taa（composite3）读写（单程序独占 ping-pong，不依赖 flip.*）
const int colortex4Format = RGBA16;  // gbuffer: 打包 albedo + 打包高光贴图（位打包需无符号格式）
const int colortex5Format = RGBA16;  // gbuffer: 八面体观察空间法线 + 原始 lmcoord
const int colortex7Format = RGBA16F; // 杂项数据（左下角杂项簇，布局见 SKYBOX_LUT_SIZE / SKYVIEW_LUT_*）：预留天空盒 256×256 + 天空 view LUT 200×200（日 / 月半区各 200×100）+ 曝光槽位 1 texel
const bool colortex7Clear = false;   // 槽位内容跨帧存活；composite12 唯一写入、光栅区域整写并透传非槽位像素（协议见 AGENTS.md / exposure.glsl）

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
// 臭氧系数按 Chappius 吸收带真实截面定形（光谱数据 https://www.iup.physik.uni-bremen.de/gruppen/molspec/databases/referencespectra/o3spectra2011/index.html ，
// 截面与浓度取法参考 Shadertoy『Scattering with Ozone』reinsteam 2017），锚定垂直 τ550 ≈ 0.04。
// WcdSW4 原系数光谱形状相反（R>G）：地平线长路径红衰减过快、日出天空发黄，故弃用重定
const vec3  OZONE_EXTINCTION_COEFFICIENTS = vec3(1.021e-6, 2.474e-6, 1.015e-7);
const vec3  SOLAR_IRRADIANCE = vec3(236.8, 206.4, 204.9);                     // 大气顶太阳辐照度（相对单位）
const vec3  MOON_IRRADIANCE  = SOLAR_IRRADIANCE * 5.0e-4; // 大气顶月亮辐照度（春雷同值 ~1/2000：真实满月 ~1/40万，游戏取值保夜景可见）
const float SKY_BRIGHTNESS   = 1.0;  // 天空色整体缩放：对齐 albedo 0~1 的画面量级（进游戏后校准）
// LUT 非活动半区阈值：光源低于此高度（约 -8.6°）后散射已衰减 7 个数量级不可见，生成端整半区写 0、
// 采样端以同一常量门控跳过 fetch——不变式「采样端跳过 ⊆ 生成端写黑」由共用本常量保证，勿在采样端写独立数值
const float SKY_LIGHT_MIN_HEIGHT = -0.15;
const float SKYVIEW_LUT_VALID_MARKER = 0.625; // LUT alpha 有效标记（RGBA16F 精确值），区别于清零 / 旧版 alpha=1 / 未初始化内容
// float32 数值防护：erfcx 负参量分支 exp(b²) 的 b 可达 r/H ~ 45 → 溢出 Inf（夜晚 / 下视 NaN 的根源）；
// airMass 上限刻意远高于 exp 归零所需——上限偏低时 energyIntegralRatio 的 ~1/tauS 残尾成为夜空亮度地板
//（1e9 时 ~2e-4 luma，经夜间自动曝光放大成可见辉光；1e15 压至曝光上限内不可见），白天主段 airMass < 1e6 不触及
const float SKY_ERFCX_EXP_MAX = 80.0; // erfcx 负支 exp 上限：2·e^80 ≈ 1.1e35 有限，对应光学深度早已全遮蔽、钳顶无损
const float SKY_AIRMASS_MAX   = 1e15; // airMass 钳制上限：τ = βmax·1e15 → exp(-τ) = 0；兼杀下视掠射闭式相消的负值 / NaN
// Mie 相函数 = HG(g1) 与 Draine(g2, a) 按权重 w 混合（Shadertoy 原调参，前向峰 + 适度后向）
const float MIE_PHASE_G1 = 0.862;              // HG 主叶前向强度
const float MIE_PHASE_G2 = 0.5069161813017329; // Draine 次叶
const float MIE_PHASE_A  = 250.0;              // Draine 各向异性因子
const float MIE_PHASE_W  = 0.24075857115188248; // 混合权重

// 各向同性环境场多次散射（skyAmbientField / atmosphericRadiance MS 项，机制见 atmosphere.glsl 头注释）：
// 正午 MS 增幅实测——天光辐照度 ×1.07/×1.12/×1.26（R/G/B）、天顶 ×1.10~1.17、反日侧暮光地平线 ×1.6~1.7；夜空地板不抬高
const float SKY_MS_STRENGTH     = 1.0; // MS 整体强度（0 = 退回纯单次散射）；嫌暮光弧 / 地平线抬升弱可上调，参考 1.0~2.0
const int   SKY_MS_QUAD_BANDS    = 8;   // 球面求积环带数（Δcosθ 等间距 = 等立体角；最内环带 θ ≈ 29° 避开 Mie 窄前向峰）
const int   SKY_MS_QUAD_AZIMUTHS = 6;   // 每环带方位节点数（带间黄金角错位防与光源几何对齐）；× BANDS = 48 节点
const float SKY_MS_CAPTURE_MAX   = 0.9; // 截获比 ρ 钳顶（海平面实测 ≤ ~0.30，防极端海拔撑爆几何级数分母）

// ---- 云（2D 平面云，lib/atmosphere/clouds.glsl；方案移植自春v2 clouds2D，2D 云原作者 Coldnight冷夜）----
// 单层解析云：云壳求交（与大气共用 EARTH_RADIUS）+ 角坐标 6 octave simplex fbm（各 octave 差速
// 演变）+ Klein-Nishina 前向散射相位照明，alpha = 密度 × 距离衰减；画在 deferred_init 天空分支
//（TAA 之前）。常量名对齐春v2 便于对照调参（多数同值，差异处注明「本包适配」）；光照全部来自
// 通用全屏 vsh 帧数据 varying——昼夜切换黑过渡 / 雨天直射 ×0.25 / 环境去饱和自动跟进。
// 开关宏与数值常量分离（预处理 #if 不支持浮点比较，TAAU 同款纪律）
#define CLOUDS_2D
#ifdef CLOUDS_2D
const float CLOUDS_2D_HEIGHT        = 8000.0;  // 云层海拔（米，春v2 同值）：高处大片层云观感 + 角坐标数值域有界；与 vCloudTransmittance 半径共用（同一常量）
const float CLOUDS_2D_COVERAGE      = 0.55;    // 覆盖率（春v2 0.45、按反馈上调）：coverage 重映射阈值，抬 = 云更多更整片
const float CLOUDS_2D_COVERAGE_RAIN = 0.85;    // 雨天覆盖率（本包适配：春v2 雨天只减密度、阴天感由其体素云层承担，本包无底层故抬 coverage 成阴天）
const float CLOUDS_2D_DENSITY       = 1.0;     // 密度直乘（春v2 同值）：alpha = 密度 × 距离衰减的不透明度主旋钮
const float CLOUDS_2D_RAIN_FADE     = 0.66;    // 雨天密度衰减（春v2 同值）：阴天变薄云
const float CLOUDS_2D_SCALE         = 300.0;   // 噪声角域频率（春v2 同值）：一个噪声周期 ≈ 云壳半径 / 300 ≈ 21 km，一团云 ≈ 半周期
const float CLOUDS_2D_SPEED         = 0.01;    // 噪声域时间速度（春v2 同值）：低频层平移 + 各 octave ×1.1 差速——云在漂移之外持续自演变
const float CLOUDS_2D_PHASE_G       = 0.25;    // KN 相位前向不对称度（春v2 同值）：银边强度与集中度的权衡
const float CLOUDS_2D_PHASE_E       = 1.879;   // KN 相位 e 参数（本包优化）：由 PHASE_G 经牛顿迭代离线解出（残差方程 1/e − 2/ln(2e+1) + 1 = g，g = 0.25 → e ≈ 1.879）——与 PHASE_G 成对维护、改 g 须重解；春v2 逐像素 8 次迭代运行时求解，折叠后免 9 次超越函数
const float CLOUDS_2D_PHASE_LOGTERM = 1.560;   // ln(2e+1)（本包优化）：同上离线解出、与 PHASE_E 成对
const float CLOUDS_2D_LIGHT_DRIFT   = 4000.0;  // 伪自阴影的光源侧偏移距离（米，本包扩展）：相对噪声周期（云壳半径 / SCALE ≈ 21 km）取数 km——偏移落在云边缘另一侧才有明暗差；sunPathRotation −30° 下正午仰角 ≈ 60°、水平投影 ≈ 0.5，调制减弱而非消失（仅太阳真正近天顶才趋零）
const float CLOUDS_2D_SHADOW_GAIN   = 3.5;     // 密度差 → 明暗映射增益（本包扩展）：大 = 边缘阴影更锐；差分降配到低频场后调制略趋平滑，嫌淡先抬此值
const float CLOUDS_2D_SHADOW_STRENGTH = 0.45;  // 伪自阴影幅度（本包扩展）：直射项 × [1−S, 1+S]——0.35 偏淡 / 0.6 偏重，0.45 折中档；0 = 关闭
const int   CLOUDS_2D_SHADOW_OCTAVES = 3;      // 伪自阴影偏移重采样的 octave 数（本包优化）：主采样 fbm 同循环累出同场低频 partial、偏移采样只求值前 N 个 octave + 复用主 worley warp 位移——两测同场差分无偏；6 = octave 与主采样同配（warp 仍为复用，与逐点独立 warp 不完全等价）
const float CLOUDS_2D_SKY_MIX       = 0.2;     // 光照的天空环境占比（春v2 同值；春v2 兼作层合成强度，本包无体素云底层、整层全强度合成，此常量只管光照混合）
const float CLOUDS_2D_FADE_DISTANCE = 24000.0; // 距离衰减 exp 尾长（米，春v2 同值）：地平线云溶进大气亮带的收口
const float CLOUDS_2D_BRIGHTNESS    = 1.25;    // 云亮度（春v2 取 3.5 按其 sunColor 量级；本包直射辐照度 ≈ 236、白地形 E/π ≈ 75，取 1.25 → 正午云 ≈ 100~150 略亮于白地形、AgX 滚落；进游戏按观感微调）
#endif

// ---- 信标光柱（gbuffers_beacon，春雷同值）----
const float ALPHA_BEACON_CORE    = 254.1 / 255.0; // 不透明核心判定阈值（a >= 此值整像素写 gbuffer）
const float BEACON_CORE_EMISSIVE = 240.0 / 255.0; // 核心自发光强度（写入 specular.a，labPBR emissive）

// ---- 物品标记（colortex4 打包 albedo 的 a 通道 8bit 槽位）----
// a 通道在 cutout 判定后职责已尽、复用为物品类型标记，随 pack4x8To2x16 一同压缩（读取端
// unpack2x16To4x8(...).a × 255 判定）；编号对齐春雷 objectMarker 系（251 起），253~255 预留显式标记扩展
const float MATERIAL_NONE       = 0.0;           // 无标记；texcolor 经半透明混合的程序（entityColor / 手动合成）混合只影响 rgb，a 整像素置空
const float MATERIAL_VEGETATION = 251.0 / 255.0; // 植被：gbuffers_opaque gsh 程序化判定（春雷 objectMarkerPlantGeometry 同位）
const float MATERIAL_SOLID      = 252.0 / 255.0; // 显式排除（block.properties → mc_Entity，vsh 写入）：gsh 见非空标记不再兜底、SSS 取 0（草方块染色顶面的 chroma 误报由本标记压制）
// 程序化判据阈值（春雷 isLikelyPlantTriangle 同值）：「垂直交叉面片」或「生物群系染色」取或
const float PLANT_PANEL_MAX_Y     = 0.2;  // 三角形几何法线竖直分量上限——面片垂直地面（草 / 花 / 苗的十字交叉模型）
const float PLANT_PANEL_DIAGONAL  = 0.55; // 法线 xz 分量 min/max 比下限——原版交叉面片两两正交再整体斜置 45°，法线落在对角方向；轴对齐墙面 / 门板达不到
const float PLANT_TINT_CHROMA_MIN = 0.06; // 三顶点平均顶点色 chroma（max−min 分量差）下限——草 / 树叶带生物群系绿染色，未染色几何顶点色近灰

// ---- block.properties 自定义方块 ID（mc_Entity.x；未定义方块 = -1）----
// ID 数值与 shaders/block.properties 成对维护（两文件无法互相引用，增改须两端同步）；
// 取值对齐 OptiFine 有符号 16 位，自定义段从 10001 起。
// **block.properties 恒纯 ASCII、零 # 注释行**：Iris 加载前先用 C 预处理器（JCPP）过一遍 properties，
// # 开头的行按预处理指令解析、非 ASCII 字节直接 Bad token 抛异常，整份 ID 图随加载一起丢失
//（mc_Entity 全 -1、显式标记静默失效——Iris 1.10.9 实测踩坑；GLSL 文件的中文注释在 // 注释内、不受影响）。
// 说明文字写在本注释与 AGENTS.md，不写进 properties 本体
const float BLOCK_GRASS_BLOCK = 10001.0; // 草方块 → MATERIAL_SOLID（退出植被 SSS：整方块无薄片透光，染色顶面系 chroma 误报）

// ---- Bloom（lib/post/bloom.glsl，无阈值，整幅 HDR 直接进金字塔）----
const float BLOOM_STRENGTH = 0.075; // 泛光合成强度（tonemap 前线性域加法）
const float BLOOM_BLUR_STEP = 2.0; // 下采样 tap 步长（源纹素数，春雷同值）：总模糊半径由回卷链逐级累积，单级无需大步长（步长 4 会跨步混叠给图集带入网格）
const float BLOOM_WEIGHTS[5] = float[5](1.0, 0.75, 0.55, 0.40, 0.30); // 各级权重（tile0 最锐 → tile4 最宽），上采样回卷相加时施加（bloomUpsampleTile）
const float BLOOM_WEIGHT_SUM = 3.0; // ΣBLOOM_WEIGHTS；getBloom 归一化，修改权重时同步更新

// ---- Tonemap（lib/post/tonemap.glsl，AgX，春雷同值）----
const float AGX_ADDITIVE = 0.6;       // AgX 曲线预缩放（与曝光系数各司其职：曝光在 tonemap 前整体乘）
const float min_ev       = -12.47393; // AgX log2 窗口下界
const float max_ev       = 4.026069;  // AgX log2 窗口上界

// ---- 自动曝光（lib/post/exposure.glsl，亮度算法春雷同值）----
const float AUTO_EXPOSURE_RATE          = 2.0;     // 适应速度（1/s）：mix 因子 1 - exp(-frameTime * RATE)，帧率无关
const float AUTO_EXPOSURE_KEY_VALUE      = 0.18;    // 目标亮度（18% 灰 key），targetExposure = KEY / max(avgLum, BASE)
const float AUTO_EXPOSURE_BASE_LUMINANCE = 0.01;    // 基础亮度地板：avgLum 直除前先抬到此下限，曝光上限 = KEY / 此值 = 18——无地板时深夜对数平均低至 1e-3、曝光冲到 90~720 倍把夜晚拉成白天。亮场景不受影响；嫌夜亮调大本值、嫌夜黑调小（有效旋钮是它，不是 MIN_LUMINANCE）
const float AUTO_EXPOSURE_MIN_LUMINANCE  = 0.00025; // log(0) 防护；曝光上限已由 BASE 收口，本值仅作半精度绝对后备（KEY / 此值 = 720）
const int EXPOSURE_SAMPLE_COUNT = 16;              // 测光采样数：槽位 fragment 的测光成本与分辨率解耦（全遍历在 4K 下 2000+ fetch）
// 均匀随机采样核：4×4 抖动网格（每单元一个随机点），全域覆盖、无聚集，读取端映射回 tile4；固定核保证帧间稳定
const vec2 EXPOSURE_SAMPLE_KERNEL[16] = vec2[16](
    vec2(0.063, 0.061), vec2(0.302, 0.106), vec2(0.574, 0.038), vec2(0.811, 0.152),
    vec2(0.148, 0.306), vec2(0.421, 0.273), vec2(0.687, 0.342), vec2(0.934, 0.289),
    vec2(0.091, 0.537), vec2(0.356, 0.618), vec2(0.609, 0.555), vec2(0.873, 0.641),
    vec2(0.219, 0.766), vec2(0.473, 0.824), vec2(0.742, 0.779), vec2(0.951, 0.898)
);

// ---- TAA（lib/common/utils/noise.glsl + lib/post/taa.glsl）----
const float TAA_JITTER_SCALE = 1.0;  // jitter 幅度缩放（1.0 = 满幅 ±0.5 渲染纹素，即 1 纹素跨度；降低可换锐度）
// Halton(2,3) 32 相位序列，像素域 [-0.5, 0.5]（春雷同族、扩到 32 项）；查表纯 GLSL 实现，不依赖
// properties 自定义 uniform（旧版 OptiFine 兼容）。相位数是 TAAU 低渲染比的目标网格覆盖数：
// 16 相位在 S=0.5 下按 AGENTS 实测定档不足（FSR2 低比例换 72 相位同因），32 项查表零成本补齐；
// 原生档（S=1）16/32 观感无差，统一用本表
const vec2 TAA_JITTER_SAMPLES[32] = vec2[32](
    vec2( 0.0,    -0.16666667), vec2(-0.25,    0.16666667),
    vec2( 0.25,   -0.38888889), vec2(-0.375,  -0.05555556),
    vec2( 0.125,   0.27777778), vec2(-0.125,  -0.27777778),
    vec2( 0.375,   0.05555556), vec2(-0.4375,  0.38888889),
    vec2( 0.0625, -0.46296296), vec2(-0.1875, -0.12962963),
    vec2( 0.3125,  0.20370370), vec2(-0.3125, -0.35185185),
    vec2( 0.1875, -0.01851852), vec2(-0.0625,  0.31481481),
    vec2( 0.4375, -0.24074074), vec2(-0.46875,  0.09259259),
    vec2( 0.03125, 0.42592593), vec2(-0.21875, -0.42592593),
    vec2( 0.28125, -0.09259259), vec2(-0.34375,  0.24074074),
    vec2( 0.15625, -0.31481481), vec2(-0.09375,  0.01851852),
    vec2( 0.40625,  0.35185185), vec2(-0.40625, -0.20370370),
    vec2( 0.09375,  0.12962963), vec2(-0.15625,  0.46296296),
    vec2( 0.34375, -0.48765432), vec2(-0.28125, -0.15432099),
    vec2( 0.21875,  0.17901235), vec2(-0.03125, -0.37654321),
    vec2( 0.46875, -0.04320988), vec2(-0.484375, 0.29012346)
);
const float TAA_HISTORY_SHARPNESS   = 0.65; // 历史 Catmull-Rom 锐化系数（春雷 0.6 / 春v2 低配版 0.8 之间）
const float TAA_CLIP_GAMMA          = 1.75; // 方差钳制 γ 基础值（深度置信度高时用）：拉宽 μ±γσ 盒 = 提高历史通过率、少被截向当前邻域（输出更贴稳定的历史）；与样本极值盒交配合有天然上界——γ 放宽到超出双峰 σ 后 binding 侧落到极值盒、历史最多放宽到邻域真实样本，鬼影风险不随 γ 无限增长
const float TAA_CLIP_GAMMA_MAX      = 2.25; // 深度置信度低时的放宽上限（防鬼影，春雷自适应同思路）
const float TAA_CLIP_DISTANCE_GAIN  = 5.0;  // Karis 距离防闪增益（Kappa / Photon 同式同值）：历史稳居钳制盒内时把当前帧权重压向 0——恒定注入相位漂移的当前帧样本是静止细节闪烁的主源；工作域已含曝光归一化，距离不再乘曝光
const float TAA_OFFCENTER_REJECTION = 0.15; // 偏心拒绝强度（Zombye，Kappa / Photon / c13 同族取 0.25）：重投影落点偏离纹素中心（=有运动）时按比例抬高当前帧权重，削运动拖影 / 运动糊；自 0.25 下调——运动中的逐像素抬权幅度即逐像素注入方差，是移动 shimmer 的放大器，下调换边缘稳定（代价同 TAA_BLEND_MOTION）
const float TAA_BLEND_BASE          = 0.05; // 当前帧基础权重（历史权重 0.95；原生档专用，TAAU 见 TAAU_BLEND_BASE）
const float TAA_BLEND_MOTION        = 0.012; // 每像素速度的当前帧权重增量（运动收敛）；自 0.02 下调——移动时锯齿 / 抖动反馈：运动中当前帧注入越少、时间累积窗越长、边缘越稳；代价是无逐物体速度的动态实体拖影收敛变慢（方差钳制兜底），嫌拖影回抬
const float TAA_BLEND_DISOCCCLUSION = 0.4;  // 深度置信失效（解遮挡）时的当前帧权重增量
const float TAA_BLEND_MIN           = 0.02; // 当前帧权重下限（历史权重上限 0.98）；置信度 / Karis 防闪在其后施加、允许压破下限（下限防的是「无信息时不信任历史」，防闪是「有信息时明确信任历史」）
const float TAA_BLEND_HAND_MIN      = 0.1;  // 手部当前帧权重下限（防手部拖影）
const float TAA_HAND_DEPTH          = 0.56; // NDC 深度阈值：小于此值视为手（BSL / Photon 同值）：TAA 手部路径判定 + 屏幕空间追踪阴影的遮挡者排除（shadow.glsl）——两处消费者成对维护
const float TAA_DEPTH_SENTINEL      = 65504.0; // 半精度上限：历史 a 通道深度钳制与天空像素哨兵——天空↔天空 |Δ|=0 满置信、天空↔几何自然归零（置信公式免分支）
const float TAA_DEPTH_CONF_EDGE0    = 0.02; // 深度置信 smoothstep 下沿（重投影深度 vs 历史 a 通道的相对差）
const float TAA_DEPTH_CONF_EDGE1    = 0.10; // 上沿

// ---- TAAU 时域上采样（子区域渲染 + composite_taa 解析上采样；关闭即纯 TAA，编译期逐位退化）----
// 机制 = c13 / Bliss 子区域缩放 + Photon / Kappa「TAA pass 即上采样器」（全貌见 AGENTS.md）：
// 几何渲染进左下 [0,S]² 子区域、像素成本 ×S²，composite_taa 上采样恢复全屏——bloom 链及之后零适配。
// jitter 有效幅度恒为 ±0.5 渲染纹素（注入在子区域缩放之后的 NDC 域，c13 / Kappa / Photon 三家同语义），
// 解析端在 buffer 域做半抖去抖（补偿加在 uv·S 之后等量施加；c13 / Kappa / Photon 三家一致——全额去抖
// 每帧精确对齐的样本携带完整相位噪声，半抖把帧间相位变化减半、保留的半个相位差经时间累积解析成
// AA / 超分信息）。
// 预处理 #if 不支持浮点比较，开关宏与数值常量分离
#define TAAU
#ifdef TAAU
const float RENDER_SCALE = 0.7; // 渲染比例 S（像素成本 ×S²：0.75 → ×0.5625、0.7 → ×0.49、0.5 → ×0.25）；半抖去抖 + 置信度门控 + 32 相位修复后 0.5 可用，仍嫌软回 0.75；<0.5 不建议（目标像素网格更稀、上采样核欠采样）
const float TAAU_UPSAMPLE_SHARPNESS = 0.6; // 当前帧上采样核锐度（与历史采样的 TAA_HISTORY_SHARPNESS 解耦）；c13 / Bliss 公式 2.0−S−S：S=0.75 → 0.5、S=0.7 → 0.6、S=0.5 → 1.0，改 RENDER_SCALE 时按此式同步
const float TAAU_BLEND_BASE = 0.05; // TAAU 当前帧基础权重（Kappa 同值、与原生档一致）：当前帧样本是相位噪声的注入端、base 即注入下限——历史权重 0.95，静止细节更依赖时间累积（配合半抖 + 减抖，三重压噪声）；出现拖影 / 收敛慢回抬 0.08~0.12
const float TAAU_CONFIDENCE_POWER = 2.0; // 上采样置信度指数（UE 最大核权重法）：采样位靠近纹素中心 ~1、纹素角点 ~0.32，指数后角点注入趋零、把插值过渡交给时间累积；Kappa 取 1 / Photon 取 5，取中
#endif

// ---- 光照（lib/lighting/lighting.glsl，直接光物理化——春雷 shading.glsl 同构）----
// 统一时间系统（fullscreen_vsh 一次算好经 varying 传入；春v2 isNoon/isNight、春雷 isDay/isNight 同构）：
// 太阳 / 月亮各自世界高度的线性门。MC 日月恰好相对、两门永不同时为正——门控加权和即「按光源选边 +
// 切换瞬间（光源过地平线）双 0 黑过渡」，替代会提前混入太阳辐照度被透射率染红的旧昼夜 mix；
// 月亮门斜率倍陡：低角度月亮透射率已深红，门快速关闭把红月落压成暗过渡，太阳侧保留物理红化（红日出是预期）
const float TIME_NOON_RAMP  = 20.0; // 太阳直射门斜率（春v2 同值；20 = 高度 0→0.05 约 2.9° 淡入）
const float TIME_NIGHT_RAMP = 40.0; // 月亮直射门斜率（春v2 同值；40 = 0→0.025 约 1.4° 淡入）
// 直射 = albedo/π × (noon×SOLAR + night×MOON_IRRADIANCE) × solarTransmittance × NdotL × 阴影可见性；
// 大气顶辐照度与天空 LUT 同源（sky:direct 亮度比物理一致，量级随 SKY_BRIGHTNESS 统调）；环境 / 方块光同为辐照度形式
const float SKY_AMBIENT_BRIGHTNESS = 2.5; // 天空环境辐照度 = LUT 天顶色 × 本系数（vSkyAmbient 主路径）：半球换算 ≈ π × 1.7（余弦加权天光平均 / 天顶的正午比值），初值与旧 DAY_SKY_AMBIENT 同幅度；统调天光亮度的主旋钮
const vec3 DAY_SKY_AMBIENT   = vec3(6.4, 8.9, 17.6);     // 仅 LUT 无效回退路径生效（vSkyAmbient 回退 / sky.glsl fallbackSkyColor）；≈ π × 余弦加权天光平均
const vec3 NIGHT_SKY_AMBIENT = DAY_SKY_AMBIENT * 5.0e-4; // 夜晚回退值 = 月亮辐照度比；正常路径只抬 MOON_IRRADIANCE 单旋钮
const vec3 TORCHLIGHT_COLOR  = vec3(1.00, 0.52, 0.20) * PI; // 方块光辐照度（π × 旧 albedo 直乘时代的量级，行为不变）
const vec3 MIN_AMBIENT       = vec3(0.0035, 0.0040, 0.0055); // 全黑环境兜底（gameplay 地板，刻意低于物理夜天光），避免纯黑不可见

// ---- 次表面散射（SSS，lib/lighting/lighting.glsl + shadow.glsl，春v2 deferred5 同构）----
// 薄叶透光近似（wrap 漫反射）：归一化强度 [0,1] 线性缩放两处——cosTheta wrap 重映射量（把明暗界
// 拓宽到背光侧，植被整株近均匀受光、明暗只由阴影贴图区分）与阴影 PCF 软化半径（tap 越出叶片自身
// 阴影边界使背光薄叶漏光、阴影边变软）；同一强度驱动，两处 _MAX 为档位锚点非独立旋钮。
// 强度来源 colortex4 标记（gbuffer_data.glsl 的 materialSSSStrength）
const float VEGETATION_SSS_STRENGTH = 0.5;  // 植被 SSS 强度 [0,1]，唯一调效旋钮（0 = 关闭、退化为 max(ndl, 0)；1 = 全档）
const float SSS_WRAP_MAX            = 2.0;  // 强度 1.0 全档的 wrap 量：ndl = 0 → 2/3、ndl = -0.5 → 0.5（默认 0.5 档再减半——温和背光辉光；春v2 plants 的 20 为近全透光档，故取保守量级）
const float SSS_SOFT_RADIUS_MAX     = 1.0;  // 强度 1.0 全档的阴影软化半径（texel）——过大会沿墙缘漏光，进游戏按需微调

// ---- 阴影（program/shadow.glsl 写入端 + lib/lighting/shadow.glsl 采样端）----
// 引擎指令前五条（shadowMapResolution 系 / sunPathRotation / shadowHardwareFiltering0）由 OptiFine/Iris 扫描
const int   shadowMapResolution      = 2048;   // 阴影贴图边长（texel）；128m 距离下每米 8 texel，中心区经扭曲再放大约 6.7 倍
const float shadowDistance           = 128.0;  // 阴影覆盖半径（米）；采样端超出即返回 1 全亮（贴图覆盖外无阴影，lib/lighting/shadow.glsl）
const float shadowDistanceRenderMul  = 1.0;    // 超出 shadowDistance 的几何不进阴影渲染（省填充率——超距采样本就按全亮）
const float sunPathRotation          = -30.0;  // 太阳轨迹倾角（度，春雷同值）：正午太阳不过天顶、影子不退化；天空与光照方向自动一致
const bool  shadowHardwareFiltering0 = true;   // 仅 shadowtex0 开硬件深度比较（sampler2DShadow）；shadowtex1 保持 sampler2D 裸深度（仅不透明几何）——彩色阴影遮挡分离与未来 PCSS blocker search 共用的后路（春v2 同布置）
const float SHADOW_DISTORT_FACTOR = 0.85;  // 线性扭曲强度（春v2/BSL/Kappa 同族）：中心 factor = 0.15、纹素密度放大约 6.7 倍，边缘不缩放
const float SHADOW_DEPTH_SCALE    = 0.2;   // shadow clip z 压缩（BSL/Photon/Kappa 同值）：写读两侧对称，配合常数 bias 抑制痤疮
const int   SHADOW_PCF_SAMPLES         = 12;   // 黄金螺旋 tap 高档（硬件比较 2×2，等效 48 次深度比较）：大盘专用——半径超 SHADOW_PCF_LOW_TIER_TEXELS 的像素（SSS 软化 / 雨天 / 远距），密度不足会噪
const int   SHADOW_PCF_SAMPLES_LOW     = 6;    // 黄金螺旋 tap 低档（等效 24 次比较）：小盘专用——噪声取决于 tap 密度（tap 数 ÷ 盘面积），24 次对 π·2.5² ≈ 20 texel 的盘仍过采样、砍半无感；两档共用 SHADOW_PCF_DIRS 表，仅径向归一化分母随档变化
const float SHADOW_PCF_LOW_TIER_TEXELS = 2.5;  // 低档分界盘半径（texel）：多数像素（近处 / 晴天 / 非 SSS）落低档
// 黄金螺旋基准方向 (cos(i·GA), sin(i·GA))：采样端 sincos 外提后逐 tap 只剩 mat2 旋转乘查表
// （角度恒等 theta_i = i·GA + φ 与原式逐位相同）。以高档 SHADOW_PCF_SAMPLES 定长、两档共用
// （黄金螺旋前缀仍均匀）；改高档 tap 数须同步本表条目
const vec2 SHADOW_PCF_DIRS[SHADOW_PCF_SAMPLES] = vec2[SHADOW_PCF_SAMPLES](
    vec2( 1.000000000,  0.000000000),
    vec2(-0.737368878,  0.675490294),
    vec2( 0.087425725, -0.996171041),
    vec2( 0.608438860,  0.793600752),
    vec2(-0.984713485, -0.174181950),
    vec2( 0.843755295, -0.536728053),
    vec2(-0.259604305,  0.965715074),
    vec2(-0.460907025, -0.887448429),
    vec2( 0.939321296,  0.343038631),
    vec2(-0.924345556,  0.381556408),
    vec2( 0.423845995, -0.905734273),
    vec2( 0.299283864,  0.954164120)
);
const float SHADOW_RADIUS_BASE    = 0.25;   // 基础软半径（texel）
const float SHADOW_RADIUS_DIST    = 2.0;   // 随相机距离增长的半径上限（texel）
const float SHADOW_BIAS_NORMAL    = 0.05;  // normal offset 基数（世界单位，随距离 / 坡度放大，春v2 同思路）
const float SHADOW_BIAS_DEPTH     = 0.00005;// 压缩后深度域常数 bias（进游戏按痤疮 / 悬空影微调）

// ---- 屏幕空间追踪阴影（lib/lighting/shadow.glsl screenSpaceShadowVisibility + lighting.glsl 接入，方案见 plans/屏幕空间追踪阴影方案.md）----
// 沿主光源方向对 depthtex1 世界空间 ray march，一档追踪兼两职：近景补接触细节（normal offset /
// PCF 模糊吃掉的小影），远景接管（贴图 0.9D→D 淡出后为唯一阴影源，视距远超 shadowDistance）。
// 机制春v2 谱系（screenSpaceShadow.glsl + deferred5 调用点）、公式自研重写；与贴图可见性取 min
// 只加暗，temporalBayer64 抖动起点相位、composite_taa 时间累积收敛（与 PCF 同一收敛机制）。
// 适用范围：近景（< NEAR_BOUNDARY·D）只 trace 向光非 SSS（保薄叶透光）；远景向光或 SSS 均可，
// SSS 结果在 NEAR_BOUNDARY→HANDOVER 从 1.0 渐入全效——HANDOVER 同时是贴图淡出窗起点，
// 0.7 / 0.9 / 1.0 三锚点交接链。开关宏与数值常量分离（TAAU 同纪律）；命名不缩写 SSS
//（本包语境已被次表面散射占用）
#define SHADOW_SCREEN_SPACE
#ifdef SHADOW_SCREEN_SPACE
const int   SHADOW_SS_STEPS          = 8;    // 步数：temporalBayer64 64 相位 × TAA 补采样密度（Photon 10 / Bliss·Kappa 16 / 春v2 5，居中）；极低配降 6
const float SHADOW_SS_LENGTH_NEAR    = 0.4;  // 近距追踪长度（格，dist ≤ 5 格锚点）：接触阴影主尺度（楼梯棱 / 草根）
const float SHADOW_SS_LENGTH_FAR     = 10.0; // shadowDistance 处长度（格，D 外饱和）：远景接管的山体尺度；嫌远景噪声 / 肥影先降此值
const float SHADOW_SS_THICKNESS_NEAR = 0.1;  // 命中窗 3D 距离基数（格）：近中景紧窗防薄几何自命中
const float SHADOW_SS_THICKNESS_FAR  = 10.0; // D 处命中窗上限（格）：接管区容表面起伏 + 步距透视放大；自春v2 的 20 收紧——本包无雾，远场掠射退化（径向序对海拔二阶不敏感、命中退化为噪声翻转）直接可见，肥窗放大边界描黑
const float SHADOW_SS_EDGE_START     = 0.75; // 渲染边界淡出起点（×far，相机远平面 ≈ 渲染半径）：远边界掠射带的命中判定退化为噪声、经 TAA 平均成沿边界的渐变描黑——自此处向边界淡出（修复实测问题）
const float SHADOW_SS_EDGE_END       = 0.9;  // 渲染边界淡出终点（×far）：边界带回退无影（本效果接入前的原状态，优于描黑）；接管主体 0.9D → EDGE_START·far 不受影响，嫌边界仍有暗带先抬 START
const float SHADOW_SS_NEAR_BOUNDARY  = 0.7;  // 近/远景分界（×D）：近景不 trace SSS（保透光观感）、远景 trace（保接管，树冠在 0.9D 外必须有影）
const float SHADOW_SS_HANDOVER      = 0.9;  // 接管窗起点（×D）：SSS 渐入终点 = 贴图淡出起点，交接链三锚点（0.7 / 0.9 / 1.0）
const float SHADOW_SS_GATE          = 0.01; // 贴图可见性门（最大通道）：全影像素不 trace——最便宜的性能门（春v2 早退同款）；D 外贴图恒 1、门自然放行
const float SHADOW_SS_STRENGTH      = 1.0;  // 整体不透明度（0~1）：接触影 / 接管影轻重的第一调效位
const float SHADOW_SS_FAR_SCALE     = 1.0;  // D 外整体缩放（春v2 取 0.9 微减弱接管区噪声观感，默认不采纳）
#endif

#endif
