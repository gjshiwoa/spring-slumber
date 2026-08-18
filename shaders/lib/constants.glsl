// 全部常量集中声明，程序与其他 lib 文件不再自行定义
// lib 文件之间不互相 include，本文件由 program 直接引入（须在 lib/common.glsl 之前，
// remapLightmap 依赖这里的常量）；OptiFine/Iris 扫描 include 展开后的内容
#ifndef LIB_CONSTANTS_GLSL
#define LIB_CONSTANTS_GLSL

// 颜色缓冲像素格式名称占位声明，供下方 colortexNFormat 常量指令引用
const int RGBA16  = 0;
const int RGBA16F = 0;

// ---- 通用 ----
const float TAU            = 6.28318530718;
const float ALPHA_CUTOUT   = 0.1;           // cutout 透贴裁剪阈值
const float LIGHTMAP_MIN   = 1.0 / 32.0;    // 原版光照图坐标下限
const float LIGHTMAP_SPAN  = 15.0 / 16.0;   // 原版光照图有效跨度（上限 = MIN + SPAN = 31/32）

// ---- 缓冲格式 ----
const int colortex0Format = RGBA16F; // 场景颜色
const int colortex4Format = RGBA16;  // gbuffer: 打包 albedo + 打包高光贴图（位打包需无符号格式）
const int colortex5Format = RGBA16;  // gbuffer: 八面体观察空间法线 + 原始 lmcoord

// ---- 天空颜色（lib/sky.glsl，暂未接入）----
const vec3 DAY_ZENITH    = vec3(0.080, 0.220, 0.620);
const vec3 DAY_HORIZON   = vec3(0.460, 0.580, 0.780);
const vec3 NIGHT_ZENITH  = vec3(0.0012, 0.0026, 0.0070);
const vec3 NIGHT_HORIZON = vec3(0.007, 0.011, 0.022);
const vec3 DUSK_HORIZON  = vec3(0.850, 0.280, 0.070);
const float SKY_TEXTURE_BRIGHTNESS = 4.0; // 太阳 / 月亮贴图发光补偿（gbuffers_skytextured，暂未链接）

// ---- 光照（lib/lighting.glsl，暂未接入）----
const vec3 SUNLIGHT_COLOR    = vec3(1.00, 0.95, 0.86) * 1.40;
const vec3 MOONLIGHT_COLOR   = vec3(0.10, 0.14, 0.24) * 0.60;
const vec3 DAY_SKY_AMBIENT   = vec3(0.180, 0.260, 0.440);
const vec3 NIGHT_SKY_AMBIENT = vec3(0.008, 0.011, 0.020);
const vec3 TORCHLIGHT_COLOR  = vec3(1.00, 0.52, 0.20);
const vec3 MIN_AMBIENT       = vec3(0.0035, 0.0040, 0.0055); // 全黑环境兜底，避免纯黑不可见

#endif
