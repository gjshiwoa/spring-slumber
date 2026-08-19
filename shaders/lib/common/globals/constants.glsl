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
const float ALPHA_CUTOUT   = 0.1;           // cutout 透贴裁剪阈值
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
const int colortex7Format = RGBA16F; // 杂项数据：曝光槽位 1 texel（bloom 图集包围盒内 tile3/tile4 间隔，exposure.glsl 的 exposureTexel）= 自适应曝光，其余区域预留给天空盒纹理等
const bool colortex7Clear = false;   // 曝光值跨帧存活；colortex7 写入者须透传其光栅化区域内非槽位像素（composite12 = 图集包围盒整写，见 lib/post/exposure.glsl）

// ---- 天空颜色（lib/atmosphere/sky.glsl，暂未接入）----
const vec3 DAY_ZENITH    = vec3(0.080, 0.220, 0.620);
const vec3 DAY_HORIZON   = vec3(0.460, 0.580, 0.780);
const vec3 NIGHT_ZENITH  = vec3(0.0012, 0.0026, 0.0070);
const vec3 NIGHT_HORIZON = vec3(0.007, 0.011, 0.022);
const vec3 DUSK_HORIZON  = vec3(0.850, 0.280, 0.070);
const float SKY_TEXTURE_BRIGHTNESS = 4.0; // 太阳 / 月亮贴图发光补偿（日月贴图程序 gbuffers_sky_tex，暂未链接）

// ---- 信标光柱（gbuffers_beacon，春雷同值）----
const float ALPHA_BEACON_CORE    = 254.1 / 255.0; // 不透明核心判定阈值（a >= 此值整像素写 gbuffer）
const float BEACON_CORE_EMISSIVE = 240.0 / 255.0; // 核心自发光强度（写入 specular.a，labPBR emissive）

// ---- Bloom（lib/post/bloom.glsl，无阈值，整幅 HDR 直接进金字塔）----
const float BLOOM_STRENGTH = 0.15; // 泛光合成强度（tonemap 前线性域加法）
const float BLOOM_BLUR_STEP = 2.0; // 下采样 tap 步长（源纹素数，春雷同值）：每级 5×5 核覆盖 ±此值纹素；总模糊半径由上采样回卷逐级累积保证，单级无需大步长（步长 4 在高频画面上跨步混叠，反而给图集带入网格）
const float BLOOM_WEIGHTS[5] = float[5](1.0, 0.75, 0.55, 0.40, 0.30); // 各级权重（tile0 最锐 → tile4 最宽），上采样回卷相加时施加（bloomUpsampleTile），getBloom 除以权重和 3.0 归一

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
const float TAA_DEPTH_SENTINEL      = 65504.0; // 半精度上限：历史 a 通道深度钳制与纯天空像素的哨兵值（下帧变几何时深度置信自然归零、快速收敛）
const float TAA_DEPTH_CONF_EDGE0    = 0.02; // 深度置信 smoothstep 下沿（重投影深度 vs 历史 a 通道的相对差）
const float TAA_DEPTH_CONF_EDGE1    = 0.10; // 上沿

// ---- 光照（lib/lighting/lighting.glsl，暂未接入）----
const vec3 SUNLIGHT_COLOR    = vec3(1.00, 0.95, 0.86) * 1.40;
const vec3 MOONLIGHT_COLOR   = vec3(0.10, 0.14, 0.24) * 0.60;
const vec3 DAY_SKY_AMBIENT   = vec3(0.180, 0.260, 0.440);
const vec3 NIGHT_SKY_AMBIENT = vec3(0.008, 0.011, 0.020);
const vec3 TORCHLIGHT_COLOR  = vec3(1.00, 0.52, 0.20);
const vec3 MIN_AMBIENT       = vec3(0.0035, 0.0040, 0.0055); // 全黑环境兜底，避免纯黑不可见

#endif
