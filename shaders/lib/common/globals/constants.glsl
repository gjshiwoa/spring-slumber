// 全部常量集中声明，程序与其他 lib 文件不再自行定义
// lib 文件之间不互相 include，本文件由 program 直接引入（须在 lib/common/pipeline/varying_io.glsl 之前，
// remapLightmap 依赖这里的常量）；OptiFine/Iris 扫描 include 展开后的内容
#ifndef LIB_CONSTANTS_GLSL
#define LIB_CONSTANTS_GLSL

// 颜色缓冲像素格式名称占位声明，供下方 colortexNFormat 常量指令引用
const int RGBA16  = 0;
const int RGBA16F = 0;

// ---- 通用 ----
const float TAU            = 6.28318530718;
const float ALPHA_CUTOUT   = 0.1;           // cutout 透贴裁剪阈值
const float ambientOcclusionLevel = 0.0;    // 引擎指令：关闭原版 AO（光照由光影接管，不叠原版顶点暗角）
const float LIGHTMAP_MIN   = 1.0 / 32.0;    // 原版光照图坐标下限
const float LIGHTMAP_SPAN  = 15.0 / 16.0;   // 原版光照图有效跨度（上限 = MIN + SPAN = 31/32）

// ---- 缓冲格式 ----
const int colortex0Format = RGBA16F; // 场景颜色
const int colortex1Format = RGBA16F; // bloom tile 图集（链式下采样金字塔，composite8~12 写入，composite_tonemap 合并）
const int colortex4Format = RGBA16;  // gbuffer: 打包 albedo + 打包高光贴图（位打包需无符号格式）
const int colortex5Format = RGBA16;  // gbuffer: 八面体观察空间法线 + 原始 lmcoord
const int colortex7Format = RGBA16F; // 杂项数据：右上角 1 texel = 自适应曝光，其余区域预留给天空盒纹理等
const bool colortex7Clear = false;   // 曝光值跨帧存活；colortex7 写入者须全屏透传不属于自己的区域（见 lib/post/exposure.glsl）

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
const float BLOOM_BLUR_STEP = 4.0; // 下采样 tap 步长（源纹素数）：每级 5×5 核覆盖 ±此值纹素，控制模糊半径（春雷用 2，4 即半径翻倍）
const float BLOOM_WEIGHTS[5] = float[5](1.0, 0.75, 0.55, 0.40, 0.30); // 各级权重（tile0 最锐 → tile4 最宽），getBloom 内除以权重和 3.0 归一

// ---- Tonemap（lib/post/tonemap.glsl，AgX，春雷同值）----
const float AGX_ADDITIVE = 0.6;       // AgX 曲线预缩放（与曝光系数各司其职：曝光在 tonemap 前整体乘）
const float min_ev       = -12.47393; // AgX log2 窗口下界
const float max_ev       = 4.026069;  // AgX log2 窗口上界

// ---- 自动曝光（lib/post/exposure.glsl，亮度算法春雷同值）----
const float AUTO_EXPOSURE_RATE          = 2.0;     // 适应速度（1/s）：mix 因子 1 - exp(-frameTime * RATE)，帧率无关
const float AUTO_EXPOSURE_KEY_VALUE     = 0.18;    // 目标亮度（18% 灰 key），targetExposure = KEY / avgLum
const float AUTO_EXPOSURE_MIN_LUMINANCE = 0.00025; // log 下限保护，兼把曝光上限约束到 KEY / 此值 = 720（半精度安全）

// ---- 光照（lib/lighting/lighting.glsl，暂未接入）----
const vec3 SUNLIGHT_COLOR    = vec3(1.00, 0.95, 0.86) * 1.40;
const vec3 MOONLIGHT_COLOR   = vec3(0.10, 0.14, 0.24) * 0.60;
const vec3 DAY_SKY_AMBIENT   = vec3(0.180, 0.260, 0.440);
const vec3 NIGHT_SKY_AMBIENT = vec3(0.008, 0.011, 0.020);
const vec3 TORCHLIGHT_COLOR  = vec3(1.00, 0.52, 0.20);
const vec3 MIN_AMBIENT       = vec3(0.0035, 0.0040, 0.0055); // 全黑环境兜底，避免纯黑不可见

#endif
