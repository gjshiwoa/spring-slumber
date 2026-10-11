// 全部常量集中声明，程序与其他 lib 文件不再自行定义
// lib 文件之间不互相 include，本文件由 program 直接引入（须在 lib/common/pipeline/varying_io.glsl 之前，
// remapLightmap 依赖这里的常量）；OptiFine/Iris 扫描 include 展开后的内容
//
// ---- 游戏内设置（2026-10 接入；布局 = shaders.properties 的 screen.* 段、文案 = shaders/lang/*.lang）----
// 三种形态：①开关 = 裸 #define 行（引擎改设置即注释 / 取消注释该行，删宏回退语义天然成立）；
// ②数值 = `#define NAME 值 // [值表]`（引擎回写值表中的 token，值表必须是本行的行尾注释、其后不得再有
// 其他文字——引擎正则只认行尾 [..]，说明文字一律挪到上一行注释）；③游戏内置指令 = camelCase const
//（shadowMapResolution 系 / sunPathRotation / ambientOcclusionLevel）——**唯一可用 const 形态挂值表的
// 设置**，自定义数值选项必须用 #define：引擎 const/option 预理会移除 / 改写数值型 const 声明（见下方
// 缓冲格式分区注），宏则按行回写、结构性免疫。值域换算类 / 结构不变式类常量（LUT 布局、位打包阈值、
// TAAU_KERNEL_BIAS 的 [4/3,√2) 窗等）不开放——开放项以「玩家观感旋钮」为限。诊断 A/B 档
//（CLOUDS_2D_WARP_SIMPLEX / WATER_SSR_DIR_TRUST / SKY_CLAMP_TO_HORIZON）不列入设置屏、留在源码手动切换
#ifndef LIB_CONSTANTS_GLSL
#define LIB_CONSTANTS_GLSL

// ---- 通用 ----
const float TAU            = 6.28318530718;
const float PI             = TAU * 0.5;
const float GOLDEN_ANGLE    = 2.39996323;   // 黄金角（弧度）：黄金螺旋采样（阴影 PCF 等）
const float GOLDEN_RATIO    = 0.61803398875; // 黄金比例共轭 1/φ（春v2 同值）：temporal 噪声帧间相位偏移（noise.glsl）
const float ALPHA_CUTOUT   = 0.1;           // cutout 透贴裁剪阈值（引擎参考值不可用时的下限兜底）
const float ALPHA_TEST_REF_MAX = 1.0;       // 引擎参考值上限（防异常哨兵：Iris 实体 VERTEX_ALPHA 档参考值为
                                            // Float.MAX_VALUE 一类值，钳回 1.0 后只裁 a<1 像素而非整 draw 全灭）
// pass 侧 cutout 剔除的统一阈值（2026-10 全版本统一，BSL 式「properties 关引擎测试 + pass 消费
// alphaTestRef」）：引擎 uniform 钳到 [ALPHA_CUTOUT, ALPHA_TEST_REF_MAX]。两端兜底依据——Iris 在
// alphaTest.* = off 下 effective 测试 = ALWAYS、alphaTestRef 恒 0（override 取 ALWAYS 的 reference），
// 老 OptiFine（1.12-）不识别该 uniform 亦恒 0：均由下限回落 0.1 = 统一前行为；现代 OptiFine 的逐 draw
// 参考值（0.1 / cutout 0.5）原样生效 = 引擎语义。宏体引用 uniforms.glsl 的 alphaTestRef 声明（宏延迟
// 展开，各 program 的 constants 先于 uniforms 引入即满足）；shadow 阶段不消费本宏、恒 ALPHA_CUTOUT
#define CUTOUT_REF (clamp(alphaTestRef, ALPHA_CUTOUT, ALPHA_TEST_REF_MAX))
// 引擎指令：原版平滑光照 AO 强度（缩放引擎烙进顶点色 rgb 的暗角，随 albedo 打包进 colortex4；0 = 关闭）
const float ambientOcclusionLevel = 1.0; // [0.0 0.5 1.0]
const float LIGHTMAP_MIN   = 1.0 / 32.0;    // 原版光照图坐标下限
const float LIGHTMAP_SPAN  = 15.0 / 16.0;   // 原版光照图有效跨度（上限 = MIN + SPAN = 31/32）

// ---- 缓冲格式 ----
// colortexNFormat 指令收进下方 /* */ 注释块（BSL / Complementary 同款生态标准形态：OptiFine / Iris
// 均从注释扫描指令，格式名〔RGBA16 等〕不进编译器）。2026-10 实机修复：旧形态为真实 const +
// 「const int RGBA16 = 0;」占位声明——引擎 const/option 预理会改写 / 移除数值型 const 声明，
// 占位被吃掉后 colortexNFormat 行悬挂未定义格式名（undefined variable "RGBA16"，gbuffers_water
// 等程序编译失败）；注释块内指令不参与编译，结构性免疫。colortexNClear 为 bool 字面量、编译
// 无害，保持真实 const（引擎从代码扫描，实测有效）
/*
const int colortex1Format = R11F_G11F_B10F; // bloom tile 图集（composite4~12 写）+ 云形状场槽位（deferred 写、图集右侧 r 通道，布局见 bloom.glsl 的 cloudFieldRect）：无符号 11/11/10、无 alpha，较 RGBA16F 带宽减半；COD 核小负瓣写入钳 0 无损
const int colortex3Format = RGBA16F; // TAA 历史缓冲：rgb = 上帧混合色（线性 HDR），a = 上帧最近片元线性深度（解遮挡置信）
const int colortex4Format = RGBA16;  // gbuffer: 打包 albedo + 打包高光贴图（位打包需无符号格式）
const int colortex5Format = RGBA16;  // gbuffer: 八面体观察空间法线 + 原始 lmcoord
const int colortex6Format = RGBA16F; // 场景主颜色：放 colortex6（= gbuffers 别名 gaux3）而非惯例的 colortex0——前向半透明 after 路径的手动合成须在 gbuffers 阶段采样主颜色背景，而 colortex0~3 采样单元在该阶段被游戏纹理占用（colortex0 即几何纹理 tex、实测采样返回图集内容），colortex0 全程未使用、不声明格式。须浮点格式：半透明合成背景为线性 HDR，旧「colortex4 副本」方案受 gbuffer 位打包的 RGBA16 格式约束会 [0,1] 截断亮背景（阳光下水面背景偏暗），副本机制已删
const int colortex7Format = RGBA16F; // 杂项数据（左下角杂项簇，布局见 SKYBOX_LUT_SIZE / SKYVIEW_LUT_* / AERIAL_LUT_ORIGIN_X）：云层天空盒 256×256（八面体，反射路径烘焙云）+ 天空 view LUT 200×200（日 / 月半区各 200×100）+ 曝光槽位 1 texel + aerial 透视 LUT 64×192（(460,0) 起）
const int colortex31Format = RGBA16F; // SR 超分运动矢量（SR mod 注入宏门控引用、未装 SR 时零引用零分配）：rg = 本帧→上帧位移（渲染分辨率归一 uv 域、无抖动采样位）、b = 实体层标记（gbuffers_entities 写 1，deferred_init 读回保留 / 其余写 0）。浮点格式（位移 ∈ [-1,1] 带符号、8bit 量化不可用）；默认 clear = true（帧头清 0 = 标记复位，防上帧实体标记跨帧残留）
*/
const bool colortex3Clear  = false;   // 历史跨帧存活；仅 composite_taa（composite3）读写（单程序独占 ping-pong，不依赖 flip.*）
const bool colortex7Clear = false;   // 槽位内容跨帧存活；composite12 唯一写入、光栅区域整写并透传非槽位像素（协议见 AGENTS.md / exposure.glsl）

// ---- 维度（world-1 下界 / world1 末地，2026-10 接入；NETHER / END 宏由各维度入口文件定义、
//      world0 不定义——模组自定义维度走根目录〔无入口文件〕= 引擎内建管线）----
// 极简档基线：两维度入口均不创建 shadow（阴影贴图不渲染）/ deferred（云形状场）两槽，程序侧由
// DIM_NO_SHADOW / DIM_NO_ATMOSPHERE 派生宏编译剔除对应采样与生成——天空 view LUT / aerial LUT /
// 云天空盒的生成（composite12）与消费（deferred_init 天空分支 / water 反射）全部无读写，天空
// 像素 = DIMENSION_SKY_COLOR 常量（末地之上另叠加主世界默认星盘——getStars 的 END 分支夜门
// 常开 / 星图全球，2026-10；下界纯常量）。**下界另恢复雾 pass（composite2 入口已建，2026-10）**：经
// FOG_UNIFIED_COLOR 走「统一雾色」档（见边界雾分区）——边界雾 / 空气透视恢复、雾色 = 常量而非
// 大气散射 LUT（下界无天光大气，LUT 亦不生成），末地维持无雾极简档（composite2 入口不创建）。
// 下界 has_skylight = false（lm.y 恒 0）；**末地 has_skylight 实际为 true**（原版末地 skylight = 15、
// 开阔地表 lm.y ≈ 1——「两维度 lm.y 恒 0」旧假设只对下界成立，2026-10 末地天光三轮反馈修正）⇒ 直射经
// DIM_NO_DIRECT_LIGHT 整段编译剔除照旧（末地无日月光源，剔除与 lm 无关）；末地天空环境项
// vSkyAmbient × lm.y⁴ 一直活着、经 END_SKY_AMBIENT 专用色供给（见下方光照分区的末地天光段），
// 下界该路径 lm 恒零自然退化；fixed_time 定格下日月 uniform 虽有值、无任何消费路径
#if defined(NETHER) || defined(END)
#define DIM_NO_SHADOW       // 无阴影：shadowtex 采样（贴图 PCF / SS 追踪 / 前向与水面单 tap）全编译剔除，可见性恒 1
#define DIM_NO_ATMOSPHERE   // 无大气：CLOUDS_2D / 天空 view LUT / aerial LUT / 云天空盒全不生成与消费；雾宏在下界经 FOG_UNIFIED_COLOR 恢复（见下方雾分区门控）
#define DIM_NO_DIRECT_LIGHT // 无天光（has_skylight = false、lm.y 恒 0）：直射项整段编译剔除（shadeSurface / forwardEntityShade / shadeWaterSurface 三处，见各 lib）——2026-10 前只经天光门乘零（计算照跑、正确性押在加载器 lmcoord 语义上，实测反馈下界疑似直射漏光后改结构性为零）
#endif
#ifdef NETHER
#define FOG_UNIFIED_COLOR // 下界统一雾档（2026-10）：BOUNDARY_FOG / AERIAL_PERSPECTIVE 恢复定义但雾色 = NETHER_FOG_COLOR 统一常量（fog.glsl / aerial.glsl 内分支），aerial 走解析式不 fetch LUT；末地不定义（无雾极简档照旧）
const vec3 DIMENSION_SKY_COLOR = vec3(0.020, 0.0045, 0.0035); // 下界天色（线性域暗红棕，观感起点——自动曝光适应下呈深红昏暗，嫌亮 / 嫌暗调本值）；与 NETHER_FOG_COLOR 单真源成对（见边界雾分区）
#elif defined(END)
const vec3 DIMENSION_SKY_COLOR = vec3(0.003, 0.002, 0.005);  // 末地天色（线性域近黑深紫，观感起点）：2026-10 两轮调参——0.008 近黑紫 → 0.013 可辨暗紫 → 按反馈大幅回落 ×~1/4（自动曝光地板 AUTO_EXPOSURE_BASE_LUMINANCE 下各档均处曝光上限区、降幅足额透传不回弹），星点对比更锐；之上叠加主世界默认星盘（deferred_init 极简档 END 分支复用 getStars——夜门常开、星图覆盖全球，见 STARS 分区与 sky.glsl）；嫌亮 / 嫌暗调本值，偏红 / 偏蓝调 rg / b
#endif

// ---- 天空 / 大气（lib/atmosphere/atmosphere.glsl + sky.glsl）----
const float SKY_TEXTURE_BRIGHTNESS = 4.0; // 太阳 / 月亮贴图发光补偿（日月贴图程序 gbuffers_sky_tex，暂未链接）

// colortex7 左下角杂项簇布局（texel 域，锚定 texel (0,0) 角 = 屏幕左下）：云层天空盒占最角上
//（[0,256)² 整块，原 aerial 借住其左下角、2026-10 天空盒启用而迁走）、天空 view LUT 200×200
// 水平相邻、曝光 / 标记槽位在二者 4 texel 间隔 gutter 内（exposure.glsl）、aerial 透视 LUT 在
// sky-view 右侧水平续接（同锚缓冲底边）；固定 texel 布局假设缓冲 ≥ ~524×260（实际渲染分辨率
// 下限远高于此）
const int SKYBOX_LUT_SIZE      = 256; // 云层天空盒边长（八面体，写读 = sky.glsl 的 cloudSkyboxDir / sampleCloudSkybox；春雷 begin19 skybox_lut 同尺寸）：composite12 每 texel 全量 getPlanarCloudsWorld 重算（≈ 天空 LUT 同级成本，下行视线行星命中早退、只上半球付全额）、water 反射未命中 SSR 侧单 fetch 消费；烘焙成本嫌重减半本值（×1/4，布局常量自动跟随）
const int SKYVIEW_LUT_W        = 200; // 天空 view LUT 半区宽 = 视线-光源方位角参数化分辨率（春雷 skyViewLutSize 同值）
const int SKYVIEW_LUT_H        = 100; // 天空 view LUT 半区高 = 天顶角参数化分辨率；太阳（上半区）/ 月亮（下半区）纵向堆叠 = 200×200
const int SKYVIEW_LUT_ORIGIN_X = SKYBOX_LUT_SIZE + 4; // LUT 区域原点 x（texel）= 260：天空盒右侧 4 texel 间隔，区域锚定缓冲底边
const int AERIAL_LUT_ORIGIN_X  = SKYVIEW_LUT_ORIGIN_X + SKYVIEW_LUT_W; // aerial 透视 LUT 原点 x（texel）= 460：sky-view 右侧紧邻、同锚缓冲底边（原址 (0,0) = 天空盒预留区左下角，2026-10 天空盒启用迁此）
// 自适应曝光槽位（texel 域）：天空盒与 sky-view LUT 的 4 texel 间隔 gutter 内、缓冲底边。
// 写入端 composite12（exposure.glsl 的指数适应）；读取端 = composite_taa / final（直接乘）+
// deferred_init 背景快照编码 / water vsh 快照解码（成对消费、同帧读同一槽位值，见 lib/water/surface.glsl）；
// exposure.glsl 的 exposureTexel() 返回本常量（单一真源）
const ivec2 EXPOSURE_TEXEL = ivec2(SKYVIEW_LUT_ORIGIN_X - 2, 0);
// pass 顺序标记槽位（诊断，texel 域）：曝光槽右侧紧邻、LUT 左缘外 1 texel——gutter 内与现有槽位
// 结构性互斥、在 composite12 光栅矩形内（可被每帧复位）。机制见
// lib/common/pipeline/pass_order_marker.glsl
const ivec2 PASS_ORDER_MARKER_TEXEL = ivec2(SKYVIEW_LUT_ORIGIN_X - 1, 0);

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
// 地平线方向钳制（春雷 CLAMP_TO_HORIZON / ClampDirToHorizon 同款）：地平线以下的天空求值方向
//（LUT 下半区纹素；未来反射的向下采样）在散射路径上钳到与地球正好相切的观察者地平线切线、钳后
// 射线一律按未命中求值——不钳时这些方向是行星命中路径、天光趋黑，钳后取地平线辉光色（暮光带
// 向下延展）；相位函数仍按未钳制方向求值、角向明暗保留。机制与数值防护见 atmosphere.glsl 的
// clampDirectionToHorizon 头注。删除本宏 = 回退逐方向直达路径（地平线以下恢复行星命中求值）
#define SKY_CLAMP_TO_HORIZON
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

// ---- 太阳盘（sky.glsl getSunDisk，deferred_init 天空分支解析叠加）----
// LUT 半区 200×100 的纹素角尺寸远大于 ~1° 视角圆盘、装不下，太阳盘只能解析绘制；亮度与
// 地面直射光同源（SOLAR_IRRADIANCE × 沿视线透射率），日落红化 / 雨天衰减与场景阳光色自动一致。
// 遮挡 = planetHitDistance（与 LUT 生成端同一行星几何），太阳沉没即圆盘下缘被地平线硬切
// 视角半径（弧度）≈ 1.08°：约 4 倍真实太阳（0.267°），全角 ~2.2°，按反馈连续放大；嫌大回抬此值
#define SUN_DISK_RADIUS 0.0188 // [0.0094 0.0141 0.0188 0.0282]
const float SUN_DISK_SOFTEN     = 0.0015; // 边缘软化宽度（弧度）≈ 0.086°：约一渲染纹素（1080p/70°FOV 一像素 ~0.065°、TAAU S=0.7 渲染纹素 ~0.093°），抗锯齿过渡带交由 TAA 时间累积抹平
// 亮度定标：正午 E ≈ 237 × T ≈ 0.87 × 450 ≈ 9×10⁴ 已越过 RGBA16F 上限、盘心钳至 65504 纯白（AgX 本就滚落成白炽、视觉无损），bloom 泛光与日落红盘（未及钳、随本值线性）是主要观感来源；物理辐射亮度 E·T/Ω 会更高三个量级，故为视觉定标非能量定标；嫌亮 / 嫌暗调此值
#define SUN_DISK_BRIGHTNESS 450.0 // [150.0 300.0 450.0 700.0]
const float SUN_DISK_RAIN_FADE  = 0.75;   // 雨天辐照度衰减（与 vDirectIrradiance 的 (1 − 0.75·rain) 同系数）：阴天太阳随直射光一起淡出（云层遮挡由绘制顺序天然给出）

// ---- 月亮盘 / 星盘（sky.glsl getMoonDisk / getStars，deferred_init 天空分支在太阳盘之后、云合成
//      之前解析叠加；water 反射未命中 SSR 侧经 waterSkyReflection 同序消费）----
// 与太阳盘同纪律：LUT 纹素角尺寸装不下圆盘 / 星点的高频内容，只能解析绘制；先于云叠加 = 云遮挡。
// 开关宏与数值常量分离（TAAU 同纪律）
#define MOON_DISK
#ifdef MOON_DISK
// 月盘满月圆盘（无月相 / 贴图）：亮度 = MOON_IRRADIANCE × 沿视线透射率 × 增益——色度与地面月光
// 同源（月下场景直射色与月盘自动一致，月出红化物理呈现）；不乘 nightFactor 时间门（几何可见性
// 交给 planetHitDistance 地平线遮挡，太阳盘同款）；雨天随月光同系数淡出
const float MOON_DISK_RADIUS     = 0.0188; // 视角半径（弧度）≈ 1.08°：与 SUN_DISK_RADIUS 同值（vanilla 日月同视觉大小），独立常量留单独调径
const float MOON_DISK_SOFTEN     = 0.0015; // 边缘软化宽度（弧度）：与 SUN_DISK_SOFTEN 同值，约一渲染纹素、过渡带交 TAA
// 视觉增益定标：月盘 ≈ 0.118 × 透射率 × 本值 ≈ 线性域 ~25——物理满月辐射亮度比太阳暗 ~9 个数量级
//（MOON_IRRADIANCE 是为夜景可见的游戏取值），月盘亮度是视觉定标非能量定标（SUN_DISK_BRIGHTNESS 450
// 同思路）；25 经夜曝光适应（上限 18×）≈ AgX 白亮盘 + 温和 bloom，嫌亮 / 嫌暗调本值
#define MOON_DISK_BRIGHTNESS 250.0 // [125.0 250.0 500.0]
const float MOON_DISK_RAIN_FADE  = 0.75;   // 雨天衰减：与 SUN_DISK_RAIN_FADE / vDirectIrradiance 同系数
#endif

#define STARS
#ifdef STARS
// 星盘：立方体网格 hash 点星，星图与月固连（绕世界 Z 旋回月亮相位——星月同升落、相对位置恒定，
// 机制见 sky.glsl getStars 头注）；夜间按太阳高度渐显（日月相对 ⇒ 即月升门）、雨天淡出；星星不随
// 主导光源阴影门控（恒星无对应遮蔽信息，桥影挡月光不挡星光——water 反射侧同纪律）。末地（2026-10
// 星盘接入）：夜门经 END 分支常开、planetHit 切割剔除（星图覆盖全球虚空）、星点叠在 DIMENSION_SKY_COLOR
// 之上——星盘实现单真源、主世界档逐位不变
const float STARS_GRID_SCALE    = 60.0;  // 网格密度（星图坐标 × 本值取整分格）：单元角尺寸 ≈ 1/本值 rad ≈ 0.95°
// 占格率（hash 门）：天球 ~4π·N² ≈ 45000 格、半球可见 ≈ 22000 × 本值 ≈ 3300 颗（vanilla 星空 ~1500 颗量级）；抬密调本值
#define STARS_DENSITY 0.15 // [0.08 0.15 0.3]
const float STARS_FALLOFF       = 8.0;   // 点径衰减斜率（× 网格域距离）：星半径 ≈ 1/本值 单元 = 0.125 单元 ≈ 0.12° ≈ 1.3 渲染纹素（TAAU S=0.7 / 1080p）——2026-10 按反馈「星星太大」自 0.25 单元缩半；更小会亚像素闪烁（TAA 吸收一部分），再嫌大抬本值；星点格内偏移已钳 [0.25,0.75]，星形完整不出格
// 星点亮度定标（线性域峰值）：夜空 LUT ~1e-3~1e-2、被月光照亮的夜云 ~0.1 量级——本值使星点经夜曝光适应
//（上限 18×）后清晰可见、但透过云的预乘合成（star × cloud.a）后与云亮度同量级，云遮星观感成立。首版 1.6
// 被反馈「星星就好像覆盖了云」（透过薄云仍是白点）降至本档；嫌暗回抬、再现刺穿感回降
#define STARS_BRIGHTNESS 0.3 // [0.15 0.3 0.6 1.2]
const float STARS_TWINKLE_SPEED = 2.0;   // 闪烁速度（Hz）
const float STARS_TWINKLE_DEPTH = 0.5;   // 闪烁深度（亮度摆幅比例，0 = 不闪）
const float STARS_RAIN_FADE     = 1.0;   // 雨天淡出系数（云层遮星，1 = 雨夜全无星）
const float STARS_FADE_LOW      = -0.25; // 夜门下沿（太阳世界高度）：低于此（约 -14.5°，深暮光后）满星
const float STARS_FADE_HIGH     = -0.05; // 夜门上沿：高于此（日落线附近、天空尚亮）无星
#endif

// ---- 云（2D 平面云，lib/atmosphere/clouds.glsl；方案移植自春v2 clouds2D，2D 云原作者 Coldnight冷夜）----
// 单层解析云：云壳求交（与大气共用 EARTH_RADIUS）+ 角坐标 6 octave simplex fbm（各 octave 差速
// 演变）+ Klein-Nishina 前向散射相位照明，alpha = 密度 × 距离衰减；画在 deferred_init 天空分支
//（TAA 之前）。常量名对齐春v2 便于对照调参（多数同值，差异处注明「本包适配」）；光照全部来自
// 通用全屏 vsh 帧数据 varying——昼夜切换黑过渡 / 雨天直射 ×0.25 / 环境去饱和自动跟进。
// 开关宏与数值常量分离（预处理 #if 不支持浮点比较，TAAU 同款纪律）；下界 / 末地经
// DIM_NO_ATMOSPHERE 整体不定义（维度极简档无大气——云天空盒烘焙〔composite12〕与天空分支云
// 合成一并编译剔除，clouds.glsl 本体亦有同宏守卫）
#ifndef DIM_NO_ATMOSPHERE
#define CLOUDS_2D
#endif
#ifdef CLOUDS_2D
// fbm 前微扰 warp 场用 simplex（1 次 simplex = 3 hash）替代春v2 的 worley（3×3 邻域 = 9 hash）——
// warp 职责只是打碎团块感的平滑位移场、任何低频噪声都胜任；位移场从胞状距离变梯度场，云的破碎
// 纹理风格会变（统计等价）。A/B 回退点：删本宏定义即回 worley 版（cloudWarp 内 #else 分支，
// 已带平方距离比较 + 循环外单次 sqrt 的降耗版）
#define CLOUDS_2D_WARP_SIMPLEX
const float CLOUDS_2D_HEIGHT        = 8000.0;  // 云层海拔（米，春v2 同值）：高处大片层云观感 + 角坐标数值域有界；与 vCloudTransmittance 半径共用（同一常量）
// 覆盖率（春v2 0.45、按反馈上调）：coverage 重映射阈值，抬 = 云更多更整片
#define CLOUDS_2D_COVERAGE 0.55 // [0.35 0.45 0.55 0.65 0.75]
const float CLOUDS_2D_COVERAGE_RAIN = 0.85;    // 雨天覆盖率（本包适配：春v2 雨天只减密度、阴天感由其体素云层承担，本包无底层故抬 coverage 成阴天）
const float CLOUDS_2D_DENSITY       = 1.0;     // 密度直乘（春v2 同值）：不透明度 = 密度（云存在度遮挡，2026-10 去距离衰减——晨昏交接带云不可见修复，见 clouds.glsl）的主旋钮
const float CLOUDS_2D_RAIN_FADE     = 0.66;    // 雨天密度衰减（春v2 同值）：阴天变薄云
const float CLOUDS_2D_SCALE         = 300.0;   // 噪声角域频率（春v2 同值）：一个噪声周期 ≈ 云壳半径 / 300 ≈ 21 km，一团云 ≈ 半周期
const float CLOUDS_2D_SPEED         = 0.01;    // 噪声域时间速度（春v2 同值）：低频层平移 + 各 octave ×1.1 差速——云在漂移之外持续自演变
const float CLOUDS_2D_PHASE_G       = 0.25;    // KN 相位前向不对称度（春v2 同值）：银边强度与集中度的权衡
const float CLOUDS_2D_PHASE_E       = 1.879;   // KN 相位 e 参数（本包优化）：由 PHASE_G 经牛顿迭代离线解出（残差方程 1/e − 2/ln(2e+1) + 1 = g，g = 0.25 → e ≈ 1.879）——与 PHASE_G 成对维护、改 g 须重解；春v2 逐像素 8 次迭代运行时求解，折叠后免 9 次超越函数
const float CLOUDS_2D_PHASE_LOGTERM = 1.560;   // ln(2e+1)（本包优化）：同上离线解出、与 PHASE_E 成对
const float CLOUDS_2D_LIGHT_DRIFT   = 4000.0;  // 伪自阴影的光源侧偏移距离（米，本包扩展）：相对噪声周期（云壳半径 / SCALE ≈ 21 km）取数 km——偏移落在云边缘另一侧才有明暗差；sunPathRotation −30° 下正午仰角 ≈ 60°、水平投影 ≈ 0.5，调制减弱而非消失（仅太阳真正近天顶才趋零）
const float CLOUDS_2D_SHADOW_GAIN   = 3.5;     // 密度差 → 明暗映射增益（本包扩展）：大 = 边缘阴影更锐；探针场化到 2 octave + bilinear 后调制趋平滑，嫌淡先抬此值
const float CLOUDS_2D_SHADOW_STRENGTH = 0.45;  // 伪自阴影幅度（本包扩展）：直射项 × [1−S, 1+S]——0.35 偏淡 / 0.6 偏重，0.45 折中档；0 = 关闭
// 云形状场（colortex1 图集右侧槽位、布局矩形见 bloom.glsl 的 cloudFieldRect）：世界锚定的低频云
// 形状（warp + 前 FIELD_OCTAVES 个 octave 的 fbm 经 cloudShape），窗口跟相机、内容为绝对世界
// 坐标的确定函数。deferred 槽生成（program/deferred_cloud_field）、deferred1（deferred_init）同帧
// 消费、零滞后——引擎的缓冲 clear 在 gbuffers 后、deferred 链前，场的写入在 clear 后、消费在下一
// clear 前，时序天然自洽（colortex1Clear 无需置 false）；bloom 图集自 composite4 起每帧全量重写、
// 与场槽位区域互斥（布局由 cloudFieldRect 结构性保证）互不干扰
const int   CLOUDS_2D_FIELD_RES     = 128;     // 场边长（texel）：128² × 9 hash ≈ 0.15M/帧生成成本
const float CLOUDS_2D_FIELD_WORLD   = 524288.0; // 窗口边长（米，512 km）：texel 4096 m ≤ 场最高 octave（第 2 个，角频率 750）周期 8.48 km 的一半（Nyquist）；半窗口 256 km > 云远界 CLOUDS_2D_FAR_MELT_END + LIGHT_DRIFT（240 + 4 km，2026-10 自 fade 早退界 ~221 km 改锚）——伪自阴影探针域恒在窗口内、bilinear 边缘永不被触达
const int   CLOUDS_2D_FIELD_OCTAVES = 2;       // 场 octave 数：探针 / 云影只需低频明暗，2 octave 是 4 km texel 的 Nyquist 上限（第 3 个 octave 周期 3.4 km 需 ≤1.7 km texel）；frequency / weight / time 序列与 cloudSimplexFbm 严格一致（改动须两处联动）
const float CLOUDS_2D_SKY_MIX       = 0.2;     // 光照的天空环境占比（春v2 同值；春v2 兼作层合成强度，本包无体素云底层、整层全强度合成，此常量只管光照混合）
const float CLOUDS_2D_FAR_MELT_END  = 240000.0; // 云远界融边终点（米，本包扩展 2026-10）：不透明度在 [终点−32000, 终点] smoothstep 融到 0——保 colortex1 云形状场半窗口不变式（探针 ≤ 终点 + LIGHT_DRIFT = 244 km < 256 km）；对应仰角 ≲ 2° 的地平线带、边界雾满档接管（BOUNDARY_FOG 关闭时为柔和溶接）。曾为 CLOUDS_2D_FADE_DISTANCE 24000 的 exp 距离衰减（春v2 同值、中低仰角云随距离变薄）——晨昏交接带云不可见实测根因之一，按反馈移除
// 云亮度：实际 = CLOUDS_2D_BRIGHTNESS（玩家倍率，值表 1.0 缺省）× CLOUDS_2D_BRIGHTNESS_BASE（定标基值）。
// 基值承载 2026-10 按反馈的定档观感（两轮 1.0 → 0.8 → 0.6）：引擎按玩家保存档回写 #define 行，文件侧宏
// 默认值不可靠，定标收进引擎不回写的 const——玩家选项 1.0 × 基值 0.6 = 旧 0.6 档亮度。历史定标参考：春v2
// 3.5 按其 sunColor 量级；本包直射辐照度 ≈ 236、白地形 E/π ≈ 75，旧无基值 1.0 → 正午云与白地形同量级
#define CLOUDS_2D_BRIGHTNESS 1.0 // [0.6 0.8 1.0 1.25 1.5]
const float CLOUDS_2D_BRIGHTNESS_BASE = 0.6; // 定标基值（非玩家旋钮，不进值表 / screen）；嫌亮暗只调它，勿动玩家档位
// 云层天空盒（colortex7 [0,SKYBOX_LUT_SIZE)² 八面体、写读映射对 = sky.glsl 的 cloudSkyboxDir /
// sampleCloudSkybox）：composite12 帧末逐 texel getPlanarCloudsWorld 全量重算（与主天空同一
// 单真源，rgb = 未预乘云色 / a = 不透明度）、water 反射未命中 SSR 侧按反射方向单 fetch 标准
// alpha 合成（2026-10 契约）
//——2026-09「反射不硬算云」的烘焙路线落地。已知取舍：云纹角分辨率 ~0.8°/texel（远粗于主天空
// 逐像素，经水波扰动 + TAA 后可接受）、内容滞后一帧且相机锚定晚一帧（云纹尺度数百米、帧间
// 相机位移厘米级，不可见）、八面体接缝 bilinear 串色（低频云不可分辨）；天空色 / 太阳盘不进
// 烘焙——前者反射侧仍直采 sky-view LUT（免双重重采样），后者 256² 纹素装不下 ~2.2° 圆盘的解析
// 锐度、反射侧仍走 getSunDisk（云在其后合成、镜中日盘同被云遮挡）
#endif

// ---- 边界雾（lib/atmosphere/fog.glsl，接入 = composite_fog / composite2 槽；距离 / 天顶角双因子、雾色取天空 LUT）----
// 渲染边界处的融接雾：远处地形 / 水面 / 天空溶进地平线色、视距边缘无接缝；非物理雾（无光照
// 方向性 / 高度衰减，纯边界融接）。开关宏与数值常量分离（TAAU 同纪律）；删宏 = fog.glsl 编译为空 +
// composite_fog 整 pass 透传旁路（colortex6 同位置 fetch 原样写回——discard 会因引擎缓冲翻转
// 黑屏，见 composite_fog.glsl）；末地经 DIM_NO_ATMOSPHERE 不定义（无雾极简档、composite2 入口
// 不创建），**下界经 FOG_UNIFIED_COLOR 恢复定义并走统一雾色分支**（2026-10，见下方统一雾分区）
#if !defined(DIM_NO_ATMOSPHERE) || defined(FOG_UNIFIED_COLOR)
#define BOUNDARY_FOG
#endif
#ifdef BOUNDARY_FOG
const float BOUNDARY_FOG_START  = 0.70; // 雾起始距离（×far）：约 0.7 倍视距外起雾
const float BOUNDARY_FOG_END    = 0.90; // 雾满强距离（×far）：0.9·far 外距离因子饱和为 1
const float BOUNDARY_FOG_ZENITH = 0.40; // 天顶淡出上沿（视线世界 y = sin 仰角，初值 0.5）：0（地平线）满雾 → 0.4（仰角约 23.6°）零雾——雾带只贴地平线、抬头即散（2026-09 按反馈下调）；统一雾档不消费（见下）
#endif

// ---- 下界统一雾（FOG_UNIFIED_COLOR，2026-10；fog.glsl 边界雾 + aerial.glsl 空气透视的统一雾色分支）----
// 下界 has_skylight = false、无天光大气——雾不取大气散射 LUT（LUT 本维度不生成、无值可采），
// 两段雾统一 **mix 向单一雾色**（原版下界式融接）：边界雾 = 纯距离因子（天顶角因子弃用——那是
// 主世界为「抬头护天空」而设，下界封闭无天可护；天空像素本就是雾色常量、雾化幂等，任何仰角的
// 融接结构性无缝）；空气透视 = 均匀介质解析式 T = exp(−σ·d) / S = 雾色 × (1−T)，无 LUT、无方向
// 依赖、无 lutValid 依赖（首帧即正确）。雾色与 DIMENSION_SKY_COLOR 同值单真源：远处地形溶进
// 天色 = 渲染边界与天空缝隙结构性不可见；要分离观感时拆常量并同步评估「天色 ≠ 雾色」的天空缝
#ifdef FOG_UNIFIED_COLOR
const vec3  NETHER_FOG_COLOR        = DIMENSION_SKY_COLOR; // 统一雾色（线性域暗红棕，= 下界天色单真源，改天色雾色自动跟随）
const float NETHER_AERIAL_DENSITY   = 1.0 / 48.0; // 空气透视消光 σ（1/米）：T = exp(−σ·d)，特征距离 48 m（该距透过率 e⁻¹ ≈ 37%）——下界典型 8~12 chunk 视距（far 128~192）中程即半融、far 端近全融；嫌浓降 σ（1/64 起步）、嫌淡抬
const float NETHER_AERIAL_FOG_START = 1.0 / 12.0; // 空气透视起始距离（×far，下界浓雾档较主世界 far/6 更近）：门内无雾、效果域 C1 smoothstep 渐入至 NETHER_AERIAL_FOG_END 全强（起始环不可见纪律同 AERIAL_FOG_START）
const float NETHER_AERIAL_FOG_END   = 0.70;       // 空气透视渐满距离（×far）：与 BOUNDARY_FOG_START 同值的接力锚（aerial 渐满即 boundary 开始融接），改动须成对评估
#endif

// ---- 大气散射雾 / 空气透视（lib/atmosphere/aerial.glsl；生成端挂 composite12 天空 LUT 重算 pass、
//      消费端在 composite_fog（composite2）边界雾之前；设计全文见 plans/地表大气散射方案.md）----
// 「表面 × 路径透射率 + 路径内散射」的物理式空气透视（aerial perspective）：
//   finalColor = surface × T(viewDir, dist) + S(viewDir, dist)——S/T 由 Chapman 解析核心
//   （atmosphere.glsl 的 atmosphericRadiance 原生支持有限路径长度 t，透射率经 out 参数带回）按
//   「方向 × 距离档」小 LUT 供给，零新 pass / 缓冲 / 纹理资产。三条不变式：
//   ①放大距离、不放大密度（inscatter(∞) 渐近 = 天空色，密度域调制会造「浓版天空」≠ 屏幕 sky-view
//     LUT 值、地平线处地形与天空色差缝）——SCALE 是纯距离域旋钮、雨天加浓同样走距离域乘子；
//   ②∞ 档存 t = SKY_NO_HIT 的求值 = 同参数天空 LUT 值（地平线以上方向结构性融接）；
//   ③天空像素不施加（depth >= 1 跳过，渐近一致性只在几何侧成立）。与边界雾两段式分工：aerial 管
//   中近距物理空气感（方向性 / 色彩 / 曙暮光分层），boundary 兜 0.7~0.9·far 渲染边界硬融接。
//   MC 视距内真实大气几乎不可见（水平 500 m 路径 Rayleigh τ ≈ 0.006 → inscatter ~0.6% 天空亮度），
//   观感强度靠等效距离放大。近场起始门（AERIAL_FOG_START / END，2026-09 按反馈接入）：约 far/6
//   内无雾、效果域 smoothstep 自零渐入至 0.7·far（= BOUNDARY_FOG_START 接力锚）全强——近场空气感
//   弃用、远端强度不受影响。开关宏与数值常量分离（TAAU 同纪律）；末地经 DIM_NO_ATMOSPHERE 不定义
//（无雾极简档），**下界经 FOG_UNIFIED_COLOR 恢复并走统一雾色分支（2026-10）**：applyAerialPerspective
//   换解析式 T = exp(−σ·d) / S = NETHER_FOG_COLOR × (1−T)（常量见边界雾分区的下界统一雾段），
//   **aerial LUT 生成端（composite12 区域分支）在统一雾档不编译**——生成了也无采样端、白付
//   天空 LUT 一成半~三成成本
#if !defined(DIM_NO_ATMOSPHERE) || defined(FOG_UNIFIED_COLOR)
#define AERIAL_PERSPECTIVE
#endif
#ifdef AERIAL_PERSPECTIVE
// LUT 布局（texel 域）：colortex7 原点 (AERIAL_LUT_ORIGIN_X, 0) = (460, 0)——sky-view LUT 右侧
// 水平续接、同锚缓冲底边（原址 (0,0) = 天空盒预留区左下角，2026-10 八面体云层天空盒启用、
// [0,256)² 整块归还天空盒而迁此）；与天空盒 [0,256)² / 曝光 (258,0) / 标记 (259,0) / sky-view
//（x ∈ [260,460)）均不重叠
const int   AERIAL_LUT_W      = 64;  // 方位分辨率（texel）：aerial 是低频量、被距离维插值与 TAA 时间累积双重平滑，低于 sky-view 的 200；Mie 前向峰在 sqrt 参数化下光源侧 ~13 texel、bilinear + TAA 足够
const int   AERIAL_LUT_H      = 48;  // 天顶分辨率（texel）：方向参数化与 sky-view 互逆组共用（双段 sqrt 向地平线集中），分辨率独立
const int   AERIAL_LUT_SLICES = 4;   // 距离档数（y 向堆叠）：前 3 档有限等效距离 + 末档 ∞（天空渐近，不变式②）
const float AERIAL_DIST_SLICES[3] = float[3](1024.0, 4096.0, 16384.0); // 距离档位（等效米）：插值按线性距离权重（inscatter 未饱和段近似线性于 t，log 域 lerp 档间中点有 ~25% 系统性偏差）；**档 0 以下不设起始阈值、向相机线性归零**（短路径 inscatter ∝ t 的线性外推——整段早退跳过会在起始距离环留世界系固定的亮度阶，2026-09 实测可见后移除）；末段向 ∞ 档按 1 − S2/t 收尾（无穷远作线性端点 w 恒 0、直接跳档是档 2 距离环上的不连续）。SCALE = 64/9 下档位映射真距 144 / 576 / 2304 格（far 内到不了档 2、晴天不触末段）
// 观感强度主旋钮：等效距离放大倍数（真距 × 本值 = LUT 距离域）——中短距 inscatter ∝ t、缩放即强度
//（2026-09 两轮反馈自 64 连降至 64/9：64 时 far 端 ~70%+ 过浓、64/3 仍偏浓；64/9 后 144 格 ~2% / 576 格
// ~8% / far ~9%，远景边界由边界雾主导）。要中距离就明显可回抬（每 ×2 强度约翻倍）。改它不动档位表
//（档位是 LUT 的骨头、SCALE 只决定多远落哪档）。默认 7.111111 = 64/9 的十进制精确值（开放游戏内设置：
// 值表须单 token 可解析浮点，分数式 64.0/9.0 不能进值表——引擎滑杆定位按 float 解析；差 < 2e-5 逐位无感），
// 值表按 ÷2 / ×2 阶梯给档
#define AERIAL_DIST_SCALE 7.111111 // [3.556 7.111111 14.222 28.444]
const float AERIAL_RAIN_BOOST = 2.0;  // 雨天加浓：距离域乘子 (1 + 本值 × rainStrength)——保渐近不变式①（密度域调制禁用）
const float AERIAL_FOG_START  = 1.0 / 6.0; // 起始距离（×far，2026-09 按反馈接入；2026-10 按反馈自 far/3 拉近至 far/6——中近距看不出来雾）：约 far/6 内无雾——applyAerialPerspective 的**效果域** smoothstep 门（LUT 路径仍无阈值、档 0 以下线性归零见上条），fade 乘在「原表面 vs 雾化结果」的 mix 上；起点系数恒 0 且零斜率（C1）、环内外值同为 0，与首代「早退 = 0 / 环外立刻满档 LUT[S0]」的值阶环不同构，起始距离环结构性不可见；门内像素恒等早退、零 fetch
const float AERIAL_FOG_END    = 0.70;      // 渐满距离（×far）：此处起 aerial 全强（远端强度与门前逐位相同——SCALE 两轮反馈的调定不受门影响）；与 BOUNDARY_FOG_START 同值的接力锚（aerial 渐满即 boundary 开始融接），独立常量、改动须成对评估
#endif

// ---- 信标光柱（gbuffers_beacon，春雷同值）----
const float ALPHA_BEACON_CORE    = 254.1 / 255.0; // 不透明核心判定阈值（a >= 此值整像素写 gbuffer）
const float BEACON_CORE_EMISSIVE = 240.0 / 255.0; // 核心自发光强度（写入 specular.a，labPBR emissive）

// ---- 物品标记（colortex4 打包 albedo 的 a 通道 8bit 槽位）----
// a 通道在 cutout 判定后职责已尽、复用为物品类型标记，随 pack4x8To2x16 一同压缩（读取端
// unpack2x16To4x8(...).a × 255 判定）；编号对齐春雷 objectMarker 系（251 起），253~255 预留显式标记扩展
const float MATERIAL_NONE       = 0.0;           // 无标记；texcolor 经半透明混合的程序（entityColor / 手动合成）混合只影响 rgb，a 整像素置空
const float MATERIAL_VEGETATION = 251.0 / 255.0; // 植被：block.properties 显式列表 → mc_Entity → vsh 判定（春v2 IDMapping 同款五族，见 material.glsl 的 isVegetationId）；252 空缺、253~255 预留

// ---- block.properties 自定义方块 ID（mc_Entity.x；未定义方块 = -1）----
// ID 数值与 shaders/block.properties 成对维护（两文件无法互相引用，增改须两端同步）。
// **block.properties 恒纯 ASCII、零注释行**：Iris 加载前先用 C 预处理器（JCPP）过一遍 properties，
// # 开头的行按预处理指令解析、非 ASCII 字节直接 Bad token 抛异常，整份 ID 图随加载一起丢失
//（mc_Entity 全 -1、显式标记静默失效——Iris 1.10.9 实测踩坑；GLSL 文件的中文注释在 // 注释内、不受影响）。
// 说明文字写在本注释与 AGENTS.md，不写进 properties 本体。
// **方块名按版本分支 `#if MC_VERSION >= 11300`（春v2 同款列表照抄）**：1.13 扁平化改名（矮草 grass →
// 1.20.3 short_grass，两名并列同 ID、引擎忽略未知名）；双高植物上下半用 `name:half=lower/upper`
// blockstate 属性匹配拆开（不识别属性匹配的老加载器该行整体落空、高草回落空标记——SSS 缺失不破图）；
// 1.12− 双高植物共用 double_plant 一个 ID（整族含向日葵 / 丁香等花，老版本粒度限制）。老分支水双写
// 裸名 + 命名空间名：1.7 时代 properties 原生裸名，命名空间前缀为后加，老解析器二者择一命中、不认的
// 那个跳过，双写覆盖两种解析行为；GLSL 侧 ID 数值两分支一致、常量无分支
// 植被五族（春v2 materialIdMapper 的 IDMapping 同款，消费见 material.glsl 的 isVegetationId——
// switch case 字面量与本段说明成对维护）：
//   31 = 矮草 / 花 / 农作物（短植物）；10175 / 11175 = 双高植物下 / 上半（tall_grass 等，含上下两半
//   ——高矮草由此区分）；18 = 树叶 / 藤蔓 / 海草；10176 = 其他植物 / 片状物（苗 / 蘑菇 / 甘蔗 / 藻类等）
//   ——五族在春v2 各自驱动摇晃 / 阴影差异，本包统一映射 MATERIAL_VEGETATION（SSS 单档、无 waving）；
//   草方块 grass_block 不在列表（整方块无薄片透光，天然空标记无 SSS，勿加入）
const float BLOCK_WATER = 8.0; // 水 → shadow pass 焦散透射（春v2 同 ID：`water flowing_water`；消费在 program/shadow.glsl 的 shadowcolor0 写入侧，非 gbuffer a 通道标记——机制见「阴影贴图」水焦散条与 lib/lighting/caustics.glsl）

// ---- 植物晃动（lib/common/pipeline/waving.glsl，宏 WAVING_PLANTS；方案移植自春v2 lib/wavingPlants.glsl，
//      其头注归属：搜狐畅游引擎部「渲染TA实战：模型草美术效果分享」zhuanlan.zhihu.com/p/609035535）----
// 判定复用 block.properties 五族（与 isVegetationId 同一列表）：31 / 10175 / 11175 / 18 四族晃动
//（各族幅度与顶点覆盖见 plantWavingParams——矮草与双高植物下半仅上顶点〔根部钉地〕、双高植物上半全顶点、
// 树叶全顶点含竖直分量）、10176 其他植物不晃（只吃 SSS）；gbuffers_opaque〔terrain〕与 shadow 两侧
// 同一函数、同一世界锚定 → 贴图阴影随几何同步晃；删宏 = 两侧一起停晃、逐位回到静止几何
#define WAVING_PLANTS
const float WAVING_RATE             = 1.0;  // 晃动速率（时间轴倍率；春v2 默认档）
// 三族幅度倍率（游戏内设置）：矮草 / 花 / 苗（31 族，仅上顶点、仅水平）
#define WAVING_SHORT_AMPLITUDE 1.0 // [0.5 1.0 1.5 2.0]
// 双高植物（10175 仅上顶点 / 11175 全顶点，仅水平）幅度倍率
#define WAVING_TALL_AMPLITUDE 0.4 // [0.2 0.4 0.8 1.2]
// 树叶 / 藤蔓（18 族全顶点、含竖直）幅度倍率
#define WAVING_LEAVES_AMPLITUDE 0.4 // [0.2 0.4 0.8 1.2]
const float WAVING_NOISE_SCALE      = 1.0;  // 风场噪声尺度倍率（大 = 风团更大、空间相位更平滑）
const float WAVING_DISTANCE         = 60.0; // 晃动距离上限（格，春v2 同值——远处晃动亚像素化无意义且费顶点）
const float WAVING_FADE_RANGE       = 10.0; // 距离淡出带宽（本包平滑化；春v2 为硬门——按「距玩家世界距离」
                                            // 淡出，gbuffers / shadow 两侧同式同 cameraPosition、淡出同步无错位）
const mat2 WAVING_GUST_ROT = mat2(0.900447, -0.434966, 0.434966, 0.900447); // 阵风带朝向旋转（列主序，= 春v2 rotate2D(xz, +0.45) 逐位一致，与 CAUSTICS_ROT 互为转置〔角向相反〕）；三角值预算、编译期折叠（纪律同 CAUSTICS_ROT）
const float WAVING_GUST_SPEED = 12.0; // 阵风带平移速度（平移坐标 格/s——快摆幅度 mask 在世界中的推进速度；旋转系 x 经 ×3 拉伸，世界系沿旋转 x 的表观速度 = 值 ÷3。春v2 默认 32，调慢为缓行观感）

// ---- Bloom（lib/post/bloom.glsl，无阈值，整幅 HDR 直接进金字塔）----
// 泛光合成强度（tonemap 前线性域加法）
#define BLOOM_STRENGTH 0.075 // [0.0 0.04 0.075 0.12 0.18]
const float BLOOM_UW_STRENGTH_MULT = 10.0; // 水下泛光增益（2026-10 按反馈接入，final 消费）：isEyeInWater == 1 时 BLOOM_STRENGTH 整体乘本值——水下雾把高对比亮部（Snell 窗内的天空 / 日盘、焦散亮网）包进低亮介质、泛光观感偏弱，抬档补介质感。**1.5 → 2.5 → 4.0 三档实机无感**（bloom 是 tonemap 前线性域加法，水下画面无 HDR 峰、金字塔内容为低对比雾色场，+30% 量级的加法经 AgX 压缩后不可辨），10.0 起加法量 ≈ 0.75 × 模糊场、与画面同量级才有可见的乳白介质感；只乘水下、水上逐位不变，1.0 = 无增益，嫌过冲在 4~10 间回调
const float BLOOM_BLUR_STEP = 2.0; // 下采样 tap 步长（源纹素数，春雷同值）：总模糊半径由回卷链逐级累积，单级无需大步长（步长 4 会跨步混叠给图集带入网格）
const float BLOOM_WEIGHTS[5] = float[5](1.0, 0.75, 0.55, 0.40, 0.30); // 各级权重（tile0 最锐 → tile4 最宽），上采样回卷相加时施加（bloomUpsampleTile）
const float BLOOM_WEIGHT_SUM = 3.0; // ΣBLOOM_WEIGHTS；getBloom 归一化，修改权重时同步更新

// ---- Tonemap（lib/post/tonemap.glsl；算子族自春雷 lib/post/simple_tonemap.glsl 移植）----
// 算子选择（游戏内设置，2026-10）：0 = AgX（默认，接入史实与现状逐位一致）1 = Filmic 2 = ACES
// 3 = Hable（= Uncharted 2 filmic，John Hable）。分派在 tonemap.glsl 的 applyTonemap（#if 编译
// 期裁剪、单算子进产物），其余管线（曝光 / RCAS / bloom / linearToSrgb）不动。类目录形数值选项
// 不进 sliders——按钮形态逐档点名，滑杆的连续量语义不适用（本包数值选项全进 sliders 纪律的唯一
// 例外）。已知取舍：RCAS_SURROGATE_K 的代理曲线按 agx 灰阶定标，其他算子下 lobe 统计为近似
//（lobe 只依赖邻域单调统计量，代理域差仅轻微影响自适应增益）；调参史：三算子 ADDITIVE 预缩放
// 取春雷同值（其按自身曝光链定标，本包曝光链同源量级）
#define TONEMAP 0 // [0 1 2 3]
const float AGX_ADDITIVE = 0.6;       // AgX 曲线预缩放（与曝光系数各司其职：曝光在 tonemap 前整体乘；春雷同值）
const float min_ev       = -12.47393; // AgX log2 窗口下界
const float max_ev       = 4.026069;  // AgX log2 窗口上界
const float ACES_ADDITIVE    = 1.25;  // ACES 曲线预缩放（春雷同值）
const float FILMIC_ADDITIVE  = 0.2;   // Filmic 曲线预缩放（春雷同值）
const float HABLE_ADDITIVE   = 2.0;   // Hable 曲线预缩放（春雷 UNCHARTED2_ADDITIVE 同值）
const float HABLE_WHITE_POINT = 16.29; // Hable 白位点（whiteScale 归一，春雷同值）

// ---- 色彩滤镜（final，tonemap 前线性域：亮度增益 → 对比度 → 饱和度；2026-10 接入）----
// 施加点在曝光之后（自动曝光测光在 composite12、观感旋钮不被曝光反噬）、RCAS 之后（锐化统计
// 不吃滤镜），三值 1.0 = 逐位直通。饱和度向 Rec.709 luma 收放（weather 降饱和同式，>1 时低通道
// 负过冲由 applyTonemap 入口钳非负）；对比度绕线性域 18% 中灰枢轴（不挪自动曝光锚定的中间调，
// >1 时暗端同样经入口钳）。亮度是纯线性增益、与自动曝光量级解耦（曝光乘在滤镜之前）
#define COLOR_BRIGHTNESS 1.0 // [0.6 0.8 0.9 1.0 1.1 1.2 1.4]
#define COLOR_CONTRAST   1.0 // [0.6 0.8 0.9 1.0 1.1 1.2 1.4]
#define COLOR_SATURATION 1.0 // [0.0 0.4 0.6 0.8 1.0 1.2 1.4 1.6]
const float COLOR_CONTRAST_PIVOT = 0.18; // 对比度枢轴 = 线性域中灰（18%），不进设置

// ---- RCAS（lib/common/utils/filters.glsl rcasLobe + final 锐化，春雷同款：FSR1 Robust CAS）----
// 预处理 #if 不支持浮点比较，开关宏与数值常量分离（TAAU 同纪律）
// RCAS 总开关（游戏内设置）：删本行 = final 的 RCAS 段整体编译剔除（含 depth 与 4 次邻域 fetch）、
// 逐位回退接入前管线——调大 RCAS_SHARPNESS 只压增益不省采样，低配关闭用本开关
#define RCAS
#ifdef RCAS
// 锐化档位（stops）：0.0 最锐、每 +1.0 增益减半——TAA / TAAU 时间累积软感的末级补锐；
// 2026-10-11：按模糊反馈，默认由 1.0 降至 0.5（lobe 强度 ×sqrt(2)）；不提高历史采样锐度。
// 嫌锐度过强抬本值、嫌软降本值；TAAU 重建核由 TAAU_KERNEL_BIAS 控制
#define RCAS_SHARPNESS 0.5 // [0.0 0.5 1.0 1.5 2.0]
// 噪声抑制（春雷同款默认开，游戏内设置）：邻域亮度波动大处压低锐化增益、不放大噪声 / 颗粒；
// 删本行 = 分支编译剔除、回退纯 RCAS
#define RCAS_DENOISE
const float RCAS_SURROGATE_K = 1.0; // lobe 统计的感知域代理曲线锚点（Reinhard x/(x+k)）：按 agx 灰阶三点定标（输入 0.18 / 1 / 10 → agx ≈ 0.16 / 0.55 / ~1.0，k=1 时 surrogate ≈ 0.15 / 0.50 / 0.91，中暗部贴合最紧）——代理只喂限幅 / 去噪统计（lobe 只依赖邻域单调统计量），域差仅轻微影响自适应增益；final 消费
#endif

// ---- 自动曝光（lib/post/exposure.glsl，亮度算法春雷同值）----
const float AUTO_EXPOSURE_RATE          = 2.0;     // 适应速度（1/s）：mix 因子 1 - exp(-frameTime * RATE)，帧率无关
const float AUTO_EXPOSURE_KEY_VALUE      = 0.18;    // 目标亮度（18% 灰 key），targetExposure = KEY / max(avgLum, BASE)
// 基础亮度地板：avgLum 直除前先抬到此下限，曝光上限 = KEY / 此值 = 18——无地板时深夜对数平均低至
// 1e-3、曝光冲到 90~720 倍把夜晚拉成白天。亮场景不受影响；嫌夜亮调大本值、嫌夜黑调小（有效旋钮是它，
// 不是 MIN_LUMINANCE）
#define AUTO_EXPOSURE_BASE_LUMINANCE 0.01 // [0.005 0.01 0.02 0.04]
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
// 内置 TAA / TAAU 常量混合基线（2026-10-11）：有效历史固定注入 3% 当前帧。
// 深度仅供重投影 / 诊断，不调权也不改变颜色钳制；越界 / 首帧仍直接当前帧。
// 删除本宏恢复旧自适应档（速度 / 深度 / 相位 / Karis / 手部下限），便于实机 A/B。
#define TAA_FIXED_BLEND

// TAA 诊断 A/B 档：源码手动改值，不列入游戏菜单；SR 接管时自动旁路。
// 0 = 正常；1 = 深度置信（红拒绝 / 绿接受）；2 = 最终当前帧权重（白 = 1）；
// 3 = 历史钳制改变量（Reinhard-YCoCg 域 × TAA_DEBUG_CLIP_GAIN）。
// 诊断标量写 colortex6 闲置 alpha；RGB / 历史 / 测光保持正常，final 绕过后处理显示。
#define TAA_DEBUG_VIEW 0 // [0 1 2 3]
const float TAA_DEBUG_CLIP_GAIN = 16.0;

// TAAU 轻量重建与历史修正（2026-10）：不新增元数据缓冲。
// 下列速度 / 深度 / Karis 参数在 TAA_FIXED_BLEND 下仅为旧自适应回退或诊断保留。
const ivec2 taaCrossOffsets[4] = ivec2[4](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));
const float TAA_MOTION_LOW = 0.5; // 目标像素 / 帧；低速不启用偏心拒绝
const float TAA_MOTION_HIGH = 8.0;
const float TAA_RECTIFY_STABLE = 0.35; // 仅方差盒软修正；样本极值盒仍硬约束
const float TAA_RECTIFY_CHANGE_LOW = 0.05; // Reinhard-YCoCg 域颜色差异
const float TAA_RECTIFY_CHANGE_HIGH = 0.25;
// TAAU 轮廓稳定：仅可信低速高反差区域放宽方差盒，不放宽真实样本极值。
const float TAAU_EDGE_CONTRAST_LOW = 0.08; // 曝光归一化 Reinhard 亮度跨度
const float TAAU_EDGE_CONTRAST_HIGH = 0.25;
const float TAAU_EDGE_CLIP_GAMMA = 3.0; // 高反差边缘的方差盒上限；快速运动 / 深度失配回基础值
const float TAAU_DEPTH_SUPPORT_LOW = 0.05; // 历史双线性足迹的最小贡献；零权重邻居不得救活历史
const float TAAU_DEPTH_SUPPORT_HIGH = 0.25; // 足迹内显著贡献的匹配深度可保留历史
const ivec2 taaHistoryOffsets[4] = ivec2[4](ivec2(0, 0), ivec2(1, 0), ivec2(0, 1), ivec2(1, 1));
const float TAAU_STAT_WEIGHT = 1.5; // exp2 距离统计权重，九样本与重建共享
const float TAAU_CONFIDENCE_POWER = 1.0; // 九样本正权重置信度；原生档置信度恒为 1
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
const float TAA_CLIP_GAMMA          = 2.0;  // 方差钳制 γ 基础值（深度置信度高时用）：拉宽 μ±γσ 盒 = 提高历史通过率、少被截向当前邻域（输出更贴稳定的历史）；与样本极值盒交配合有天然上界——γ 放宽到超出双峰 σ 后 binding 侧落到极值盒、历史最多放宽到邻域真实样本，鬼影风险不随 γ 无限增长。自 1.75 抬（2026-10 远处物体闪烁 / 反射噪点反馈）：远物邻域统计双峰 σ 窄、历史被截即 Karis 失效（clipDistance=0 不再压注入）→ 恒定注入闪烁，抬 γ 让历史更常稳居盒内、Karis 防闪随之激活（双重收益）
const float TAA_CLIP_DISTANCE_GAIN  = 5.0;  // Karis 距离防闪增益（Kappa / Photon 同式同值）：历史稳居钳制盒内时把当前帧权重压向 0——恒定注入相位漂移的当前帧样本是静止细节闪烁的主源；工作域已含曝光归一化，距离不再乘曝光
const float TAA_OFFCENTER_REJECTION = 0.15; // 偏心拒绝强度（Zombye，Kappa / Photon / c13 同族取 0.25）：重投影落点偏离纹素中心（=有运动）时按比例抬高当前帧权重，削运动拖影 / 运动糊；自 0.25 下调——运动中的逐像素抬权幅度即逐像素注入方差，是移动 shimmer 的放大器，下调换边缘稳定（代价同 TAA_BLEND_MOTION）
// TAA_FIXED_BLEND 下为有效历史的固定当前帧权重；旧自适应档含后续调制。
const float TAA_BLEND_BASE          = 0.03; // 当前帧基础权重（历史权重 0.97；原生档专用，TAAU 见 TAAU_BLEND_BASE）。自 0.05 降（2026-10 远处物体闪烁 / 反射噪点反馈）：base 是静止区被截历史（Karis 失效）时的恒定注入下限，远处高频细节每帧注入的相位噪声即闪烁残余，降注入拉长时间累积窗换稳态；代价 = 运动后 / 解遮挡后收敛变慢（运动侧由 MOTION / DISOCCCLUSION 项单独补偿、不受影响），嫌拖影回抬
const float TAA_BLEND_MOTION        = 0.012; // 每像素速度的当前帧权重增量（运动收敛）；自 0.02 下调——移动时锯齿 / 抖动反馈：运动中当前帧注入越少、时间累积窗越长、边缘越稳；代价是无逐物体速度的动态实体拖影收敛变慢（方差钳制兜底），嫌拖影回抬
const float TAA_BLEND_DISOCCCLUSION = 0.4;  // 独立解遮挡更新下限系数；完全失配时强制当前帧 1.0
const float TAA_BLEND_MIN           = 0.01; // 当前帧权重下限（历史权重上限 0.99）；置信度 / Karis 防闪在其后施加、允许压破下限（下限防的是「无信息时不信任历史」，防闪是「有信息时明确信任历史」）。自 0.02 降（2026-10 同批反馈）：SSR 反射等过程噪声源（bayer 相位翻转的命中判定）靠历史主导平均，下限即其稳态噪声地板
const float TAA_BLEND_HAND_MIN      = 0.1;  // 手部当前帧权重下限（防手部拖影）
const float TAA_HAND_DEPTH          = 0.56; // NDC 深度阈值：小于此值视为手（BSL / Photon 同值）：TAA 手部路径判定 + 屏幕空间追踪阴影的遮挡者排除（shadow.glsl）——两处消费者成对维护
const float TAA_DEPTH_SENTINEL      = 65504.0; // 半精度上限：历史 a 通道深度钳制与天空像素哨兵——天空↔天空 |Δ|=0 满置信、天空↔几何显式归零
const float TAA_DEPTH_CONF_EDGE0    = 0.02; // 深度置信 smoothstep 下沿（重投影深度 vs 历史 a 通道的相对差）
const float TAA_DEPTH_CONF_EDGE1    = 0.10; // 上沿

// ---- TAAU 时域上采样（子区域渲染 + composite_taa 解析上采样；关闭使用原生十字统计）----
// 机制 = c13 / Bliss 子区域缩放 + Photon / Kappa「TAA pass 即上采样器」（全貌见 AGENTS.md）：
// 几何渲染进左下 [0,S]² 子区域、像素成本 ×S²，composite_taa 上采样恢复全屏——bloom 链及之后零适配。
// jitter 有效幅度恒为 ±0.5 渲染纹素（注入在子区域缩放之后的 NDC 域，c13 / Kappa / Photon 三家同语义），
// 解析端在 buffer 域完整补偿 jitter（uv·S + jitterUV），与光栅注入互逆。颜色重建与深度搜索
// 共用该源位置；选出的深度锚点再完整去抖还原到无抖动视场，不以半补偿掩盖坐标错位。
// 预处理 #if 不支持浮点比较，开关宏与数值常量分离
#define TAAU
#ifdef TAAU
// 渲染比例 S（像素成本 ×S²：0.75 → ×0.5625、0.7 → ×0.49、0.5 → ×0.25）；完整补抖 + 置信度门控 + 32 相位
// 修复后 0.5 可用，仍嫌软回 0.75；<0.5 不建议（目标像素网格更稀、上采样核欠采样）
#define RENDER_SCALE 0.7 // [0.5 0.6 0.7 0.8 0.9 1.0]
const float TAAU_KERNEL_BIAS = 1.35; // 3x3 径向支撑：必须在 [4/3,sqrt(2)) 内，换中心时外侧权重为零
// TAA_FIXED_BLEND 下直接采用本值，不再受相位 / 深度 / 速度 / Karis 调制。
const float TAAU_BLEND_BASE = 0.03; // TAAU 当前帧基础权重（与原生档 TAA_BLEND_BASE 同值同调，2026-10 自 0.05 降——远处闪烁 / 反射噪点反馈，见其注释）：当前帧样本是相位噪声的注入端、base 即注入下限——历史权重 0.97，静止细节更依赖时间累积（配合相位置信度与历史防闪）；出现拖影 / 收敛慢回抬 0.08~0.12
#endif

// ---- SR 超分模组接管（配置 = shaders/superresolution.v3.json，Schema V3；接口文档
//      sr.187j3x1-114514.org——仅 Iris + SR mod + 配置有效时注入下列宏，未装 / 用户关闭 = 全部未定义）----
// SR_UPSCALE 为本包侧总门（一切 SR 专属代码的唯一开关；删除接入时回收本段 + superresolution.v3.json）。
// 接管三件事：
//   ① 渲染比例：RENDER_SCALE 重定义为 SR 的 SR_RENDER_SCALE_FACTOR（编译期宏，比例档切换触发
//      热重载；「无手抖动档位不更新」的 SR_SCALED_WIDTH 族禁止进 shaders.properties / 代码）。
//      TAAU 的子区域机制（applyTAAJitter 缩放 / outsideRenderRegion / FULLSCREEN_RENDER_REGION /
//      final 深度映射 / SSR 域界）门控由 #ifdef TAAU 放行为「TAAU || SR_UPSCALE」——TAAU 关闭 +
//      SR 开启时子区域机制照常工作；游戏内 RENDER_SCALE 选项在 SR 生效期间被覆盖（改档无效，调 SR 侧）
//   ② jitter：noise.glsl 的 taaJitterSample 换用 SRJitterOffset uniform（mod 生成的相位序列，
//      与 Halton 表同一「渲染分辨率像素域」约定，applyTAAJitter / vJitter 全链自动跟进）。算法不
//      支持 jitter 时该 uniform = 0 = 不抖（此时本包 TAA 已旁路、自抖无解析端，宁可不抖）
//   ③ 抗锯齿 / 上采样：SR 算法族（FSR2 / DLSS / XeSS…）自带时域累积，composite_taa（composite3）
//      整 pass 透传旁路（colortex3 历史停写）；SR 在 composite3 前触发点读 colortex6（雾后线性
//      HDR）+ noTranslucentDepthtex + colortex31 运动矢量、写回全屏 upscaled 色彩
// 运动矢量（写入端见 deferred_init / gbuffers_opaque_entities，取值实现 space.glsl 的
//   srSceneMotionVector / srEntityMotionVector）：colortex31 由 deferred_init（三维度共用的
//   deferred1 入口）写「相机重投影」底层 + gbuffers_entities 的 at_velocity 实体层（b 标记读回
//   保留）；用户关闭 SR 的 Iris at_velocity 扩展时 SR_ENTITY_VELOCITY 不定义、实体走相机 MV
#if defined(SR_INSTALLED) && defined(SR_SHOULD_APPLY_SCALE) && SR_SHOULD_APPLY_SCALE == 1
#define SR_UPSCALE
#ifdef RENDER_SCALE
#undef RENDER_SCALE
#endif
#define RENDER_SCALE SR_RENDER_SCALE_FACTOR
#endif
#if defined(SR_UPSCALE) && defined(SR_IRIS_EXT_VELOCITY) && SR_IRIS_EXT_VELOCITY == 1
#define SR_ENTITY_VELOCITY
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
const float SKY_AMBIENT_BRIGHTNESS = 4.5; // 天空环境辐照度 = LUT 天顶色 × 本系数（vSkyAmbient 主路径）：半球换算 ≈ π × 1.7（余弦加权天光平均 / 天顶的正午比值）；统调天光亮度的主旋钮（2026-10 按反馈自 3.0 ×1.5 上调——漫反射天光整体提亮，回 3.0 逐位还原；自动曝光会吸收一部分全局增益，仍嫌暗继续 ×1.3~1.5 阶梯抬）
const vec3 DAY_SKY_AMBIENT   = vec3(6.4, 8.9, 17.6);     // 仅 LUT 无效回退路径生效（vSkyAmbient 回退 / sky.glsl fallbackSkyColor）；≈ π × 余弦加权天光平均；不随 SKY_AMBIENT_BRIGHTNESS 联动——本值同时是首帧渲染天空的回退色，随旋钮放大会闪首帧天空，旋钮抬后只影响首帧 / 缓冲重建帧（略暗于稳态、交 TAA / 曝光适应吸收）
const vec3 NIGHT_SKY_AMBIENT = DAY_SKY_AMBIENT * 5.0e-4; // 夜晚回退值 = 月亮辐照度比；正常路径只抬 MOON_IRRADIANCE 单旋钮
const vec3 TORCHLIGHT_COLOR  = vec3(1.00, 0.52, 0.20) * PI; // 方块光辐照度（π × 旧 albedo 直乘时代的量级，行为不变）
const float TORCHLIGHT_NEAR_SCALE  = 1.30; // 方块光近距离幂曲线主量级（lm.x⁴ 直乘系数）——shadeSurface 与前向简单半透明共用同式
const float TORCHLIGHT_FLOOR_SCALE = 0.02; // 方块光线性小地板（原始 lm.x 直乘，近距渐灭不断黑）
// 前向轻量着色亮度倍率（乘在 forwardLightmapShade 整体、单真源覆盖其全部调用方 = gbuffers_translucent
// 的玻璃等非水分支 + gbuffers_translucent_simple 的「deferred 之后」两档——雨雪 / hand_water / 粒子）：
// 这些路径无直射项（无阴影 / 法线，只有天光 + 方块光，阳光下显著暗于受光地形），2026-10 按反馈
//「玻璃 / 雨雾有些暗」整体提亮；forwardEntityShade（实体 after 路径、自带直射项）不受本倍率影响，
// shadeWaterSurface 的雾色亮度另有 WATER_FOG_BRIGHTNESS 族。已知取舍 = 倍率全天候生效：夜间直射
// 缺项本不存在，同比放大后玻璃 / 雨雪会亮过夜间地形一截，嫌夜间过亮改按 lm.y 分档加权（扩展点）；
// 改 1.0 逐位回退
const float FORWARD_LIGHTMAP_BRIGHTNESS = 3.0; // 前向轻量着色亮度主旋钮（3.0 = 2026-10 第二轮回抬，首版 2.0 嫌不够）
// 全黑环境兜底（gameplay 地板，刻意低于物理夜天光），避免纯黑不可见；下界 / 末地按维度分支取
//「维度环境地板」——下界无天光（has_skylight = false、lm.y 恒 0），本值即全部环境光；末地开阔处
// 环境光由 END_SKY_AMBIENT × lm.y⁴ 承担（见下条），本值兜檐下 / 岛内暗角。**两维度地板量级史
//（2026-10 两轮反馈）**：首档暖红 (0.055, 0.020, 0.014) / 冷紫 (0.020, 0.018, 0.030) 常亮不受 lm
// 调制，暗环境被自动曝光〔上限 18×〕放大成整屏泛红「岩浆余温」辉光 / 冷紫辉光（亮橙裂纹 albedo
// 上最显眼），曾按反馈整体归零（暗处回归原版纯黑、方块光 / 岩浆光照常）；同日二轮按反馈「无光
// 处避免纯黑」重新接入——量级压至主世界地板同档（亮度 ≈ 0.004，约首档的 1/7 与 1/5）、色相沿用
// 各维度原色：18× 曝光满档下典型 albedo 输出 sRGB ~0.1 的暗灰、可见而不辉光。嫌暗整体 ×N 回抬
//（亮度超过 ~0.02 量级将重现整屏辉光），旧档数值见 git 历史
#ifdef NETHER
const vec3 MIN_AMBIENT       = vec3(0.0080, 0.0030, 0.0020); // 下界：暖红地板（压至主世界量级，见上注）
#elif defined(END)
const vec3 MIN_AMBIENT       = vec3(0.0040, 0.0035, 0.0060); // 末地：冷紫地板（压至主世界量级，见上注）
#else
const vec3 MIN_AMBIENT       = vec3(0.0035, 0.0040, 0.0055); // 主世界
#endif
#ifdef END
// 末地天光（2026-10 接入；skyAmbientColor 的 #ifdef END 早退供给、全部 vSkyAmbient 消费点单真源跟随）：
// 末地 has_skylight = true（原版 skylight 15、开阔 lm.y ≈ 1），环境光项 vSkyAmbient × lm.y⁴ 活着而
// 天空 LUT 本维度不生成——旧路径回退主世界白天天空色 DAY_SKY_AMBIENT (6.4, 8.9, 17.6)（亮蓝）=
//「末地天光蓝蓝的、非常亮」的真正根因（前两轮压天色常量 / 归零 MIN_AMBIENT 均无效即此）。专用色 =
// 末地天色 DIMENSION_SKY_COLOR × π：均匀暗紫天空对地表的辐照度——地表亮度 = albedo × 天色、与天空
// 结构性同比例（改天色天光自动跟随、比例永不失调），lm.y⁴ 调制保留；嫌暗整体 ×N 抬本式，要脱离
// 比例单独调色把本值改独立常量
const vec3 END_SKY_AMBIENT   = PI * DIMENSION_SKY_COLOR;
#endif
// 直射天光门（2026-10）：天光可见度 lm.y（remapLightmap 后 0~1）经 smoothstep(LOW→HIGH) 映 0~1、
// 再 pow4 整形（三消费点各以「平方再平方」连乘实现、同 lmPow4 纪律免 pow 调用——窄窗内 smoothstep
// 起坡陡、过渡带观感硬，pow4 把爬升推向窗上沿、暗侧平缓趋零；调指数 = 增删连乘行）后乘进直射项
//（shadeSurface / forwardEntityShade / shadeWaterSurface 的 directIrradiance 族三消费点同窗同形）——
// 洞穴 / 深室内天光 ≈ 0，阴影贴图超距按全亮 + SS 追踪背光面 / 出屏放行的直射泄漏由此兜底归零。窗口
// [0.05, 0.10] 只切最深数档：vanilla 天光 16 级量化（1/15 ≈ 0.067 落窗内 → pow4 后 ~0.5% 直射、
// ≥ 2 级满额），树冠 / 檐下经传播衰减仍在 0.5 以上、不触窗。环境 / 方块光不门（各自已随 lm 幂曲线收敛）
const float DIRECT_SKYLIGHT_GATE_LOW  = 0.05; // 天光门下沿：≤ 此值直射归零
const float DIRECT_SKYLIGHT_GATE_HIGH = 0.10; // 天光门上沿：≥ 此值直射满额
// 直射 GGX 高光（2026-10，春雷 specularBrdfAnalytic 谱系）：shadeSurface 直射分支内加性叠加
// Schlick F × GGX D × Smith 相关 V 的单次散射镜面项（× NdotL × 阴影可见性 × 辐照度 × 天光门——与
// 漫反射直射项同源同门）。**不含春雷的多散射能量补偿**（其 msEnergy 需 BRDF albedo LUT 独立供给，
// 低配定位砍除：粗糙面高光略暗于全量档、光滑面无差）。输入 = colortex4.ba 解包的 labPBR 高光贴图
//（gbuffers 阶段已采样打包，读取端零新增 fetch）：r 感知光滑度 → α = (1−r)²、g 线性金属度 →
// F0 = mix(0.04, albedo, g)（金属高光取 albedo 着色；**diffuse 不做金属度衰减**——按需后接）；
// 无 specular 的资源包 r/g 恒 0 → α = 1 全粗糙 + 电解质 F0 0.04 = 全方块 ~4% 微弱菲涅尔泽光
//（与漫反射同量级），labPBR 资源包光滑面出太阳耀斑。只在直射确有贡献像素求值（零贡献门控复用，
// ~40 ALU、无新增采样）；删宏 = 整段编译剔除逐位回退
#define DIRECT_SPECULAR
// 高光总强度（观感旋钮；1.0 = 物理量级——F0 4% 与漫反射同源亮度，0 = 视觉等价关但计算照跑，彻底关闭删上方宏）
#define DIRECT_SPECULAR_STRENGTH 1.0 // [0.5 1.0 1.5]
const float SPECULAR_ALPHA_MIN       = 0.002; // GGX α 下限：镜面级光滑（r→1）防 D 分母爆炸（春雷 getPbrAlpha 同值）

// ---- 次表面散射（SSS，lib/lighting/lighting.glsl + shadow.glsl，春v2 deferred5 同构）----
// 薄叶透光近似（wrap 漫反射）：归一化强度 [0,1] 线性缩放两处——cosTheta wrap 重映射量（把明暗界
// 拓宽到背光侧，植被整株近均匀受光、明暗只由阴影贴图区分）与阴影 PCF 软化半径（tap 越出叶片自身
// 阴影边界使背光薄叶漏光、阴影边变软）；同一强度驱动，两处 _MAX 为档位锚点非独立旋钮。
// 强度来源 colortex4 标记（gbuffer_data.glsl 的 materialSSSStrength）
// 植被 SSS 强度 [0,1]，唯一调效旋钮（0 = 关闭、退化为 max(ndl, 0)；1 = 全档）
#define VEGETATION_SSS_STRENGTH 0.5 // [0.0 0.25 0.5 0.75 1.0]
const float SSS_WRAP_MAX            = 2.0;  // 强度 1.0 全档的 wrap 量：ndl = 0 → 2/3、ndl = -0.5 → 0.5（默认 0.5 档再减半——温和背光辉光；春v2 plants 的 20 为近全透光档，故取保守量级）
const float SSS_SOFT_RADIUS_MAX     = 1.0;  // 强度 1.0 全档的阴影软化半径（texel）——过大会沿墙缘漏光，进游戏按需微调

// ---- 阴影（program/shadow.glsl 写入端 + lib/lighting/shadow.glsl 采样端）----
// 引擎指令前六条（shadowMapResolution 系 / sunPathRotation / shadowHardwareFiltering0 / noiseTextureResolution）由 OptiFine/Iris 扫描。
// 其中 shadowMapResolution / shadowDistance / sunPathRotation / ambientOcclusionLevel（通用区）已开放游戏内设置——
// 游戏内置 camelCase 指令是唯一可挂值表的 const 形态（行尾 [..] 由引擎回写），其余值不开放
// 阴影贴图边长（texel）；128m 距离下每米 8 texel，中心区经扭曲再放大约 6.7 倍
const int shadowMapResolution = 2048; // [1024 2048 4096]
// 阴影覆盖半径（米）；采样端超出即返回 1 全亮（贴图覆盖外无阴影，lib/lighting/shadow.glsl）——SS 追踪的
// 接管锚点全部按 ×D 表达、随本值自动缩放
const float shadowDistance = 128.0; // [64.0 96.0 128.0 192.0 256.0]
// 超出 shadowDistance 的几何不进阴影渲染（省填充率——超距采样本就按全亮）；与 shadowDistance 成对语义、不开放
const float shadowDistanceRenderMul  = 1.0;
// 太阳轨迹倾角（度，春雷同值）：正午太阳不过天顶、影子不退化；天空与光照方向自动一致
const float sunPathRotation = -30.0; // [-40.0 -30.0 -20.0 -10.0 0.0 10.0 20.0 30.0 40.0]
const bool  shadowHardwareFiltering0 = true;   // 仅 shadowtex0 开硬件深度比较（sampler2DShadow）；shadowtex1 保持 sampler2D 裸深度（仅不透明几何）——彩色阴影遮挡分离与未来 PCSS blocker search 共用的后路（春v2 同布置）
const int   noiseTextureResolution   = 256;    // 引擎程序化噪声纹理边长（texel），OptiFine 默认档；水焦散波场（lib/lighting/caustics.glsl）唯一消费者。参考：BSL 同参数族取 512（texel 密度翻倍更平滑、采样带宽翻倍），春v2 经 texture.*.noisetex 换自备 128 模糊纹理——本包不引资产、用引擎生成档
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

// ---- 水焦散（program/shadow.glsl 写入 shadowcolor0 + lib/lighting/caustics.glsl 图案 + lib/lighting/shadow.glsl 彩色阴影分支消费）----
// 春v2 computeCausticsWithDispersion 纯色移植（色散分支删）：世界坐标经 缩放 → 旋转 → 压扁 → 时间
// 平移 后采样 noisetex 双通道，(1-g) × mix(r, 1, MOD) 组合、pow 提对比成焦散网——零差分 / 零 fbm。
// 2026-10 噪声 3D 化（SEUS 3D-from-2D、z 维 = 时间演化 CAUSTICS_EVOLVE——平移的同时图案换形、
// 根治刚性平移感；与水波高度场 lib/water/waves.glsl waterNoise3D 同构造）：双通道 × 层间插值 = 4 fetch
//（原 2D 单 fetch 为 1）；压扁使波纹沿旋转后 x 拉长成条带状涟漪。**shadowcolor0 为 RGBA8、值域上限 1**：
// rgb = 生物群系水色 tint × 网强度（网谷 CAUSTICS_BASE → 波前 1.0）、a 通道 = SHADOW_COLOR_WATER_A
// 水标记（其余透射几何恒 1.0）；读取端识别标记后 ×WATER_CAUSTICS_BOOST 重建 >1 的 HDR 焦点
//（春v2 color.a = 0.5 同款标记思路；下游 colortex6 线性域无截断）。删 WATER_CAUSTICS 宏 = 水回退
// 原透射色路径（纹理色 tint、a = 1 无标记，读取端水分支自动失效），varying 一并编译剔除
#define WATER_CAUSTICS
const float CAUSTICS_SCALE = 0.006; // 缩放：世界块 → noisetex uv。texel ≈ 0.65 块（春v2 CAUSTICS_FREQ 0.03 × 128³ 噪声的等效密度折算到 256 noisetex 为 0.015 / texel 0.26 块；2026-10 按反馈两轮调稀：×2/3 至 0.010 仍嫌密、再至 0.006——累计放大 2.5 倍）；网嫌大嫌密调本值——**改本值须同比缩 CAUSTICS_DRIFT（噪声域速度），否则世界系滚动速度随密度联动**
const mat2  CAUSTICS_ROT   = mat2(0.900447, 0.434966, -0.434966, 0.900447); // 旋转（列主序，与春v2 rotate2D(xz, -0.45) 逐位一致：其矩阵形 [[c,-s],[s,c]] 配负角净效果 = 逆时针 0.45 rad）；三角值预算、编译期折叠免运行时 sincos。**改本矩阵的转角方向会连带翻转水流轴向（与 DRIFT 符号共同决定世界系流向），与春v2 对齐时勿只改角度不改符号**
const float CAUSTICS_SQUASH = 4.0; // 压扁：噪声 y 向频率 ×4 → 波纹沿旋转后 x 拉长成条带状涟漪（春v2 z×4 同值）；条带拉长比主旋钮
const vec2  CAUSTICS_DRIFT = vec2(0.0, 0.020); // 时间平移速度（uv/秒，沿旋转系压扁轴；caustics.glsl 侧 -= 与春v2 `sampleUV -=` 同号——图案沿压扁轴正向滚动）：世界速度 = 本值 / CAUSTICS_SCALE ≈ 3.3 块/秒（春v2 CAUSTICS_SPEED 0.13 折算）——2026-10 两轮调稀密度时同比缩放（0.065 → 0.0433 → 0.026）保持世界流速不变；2026-10-08 按反馈放缓：减半档 0.013（≈2.2 块/秒）实测过慢回退，取 0.020 温和档
const float CAUSTICS_EVOLVE = 0.8;  // 三维噪声 z 维演化速度（lattice 格/秒，2026-10 焦散 3D 化接入）：z 走 1 格 = 图案换一副不相关的网——DRIFT 平移的同时形态沿 z 连续换形（与水波高度场的 z 维同职责），根治「刚性平移感」；波形侧同构造 z 速率 ≈ 0.675（WAVE_SPEED 1.5 折算），初档取同量级；2026-10-08 按反馈 0.6 → 0.8 加快形态变化，DRIFT 平移速度不动。嫌变得快降本值、嫌图案死板抬
const float CAUSTICS_MOD   = 0.8;  // 次级通道调制权重：web = (1-n.g) × mix(n.r, 1, 本值)（春v2 同值）；嫌网碎抬 → 次级调制更弱、图案更由主通道独挑
const float CAUSTICS_POWER = 3.0;  // pow 收网对比度（春v2 同值）：网稀嫌淡降、嫌网满抬
const float CAUSTICS_TILT  = 0.2;  // 采样平面 y 斜置系数（BSL 同值）：xz − y·TILT——流动水面不同高度错开图案平面，跌水 / 阶梯水免竖直条纹
const float CAUSTICS_BASE  = 0.22; // 存储背景（网谷）：读取端默认 ×BOOST 后 = 0.44×tint
const float SHADOW_COLOR_WATER_A    = 0.5;  // shadowcolor0.a 水标记值（RGBA8 量化 128/255；非水几何恒写 1.0）
const float SHADOW_COLOR_WATER_TEST = 0.75; // 读取端水标记判定阈（texelFetch 精确纹素，0.5 与 1.0 的中点）
// 读取端 HDR 重建系数：vis = 存储 rgb × 本值——默认网谷 = 0.44×tint、波前 = 2.0×tint（直射光水下焦点亮度；
// 春v2 BRI_MIN/MAX 1.0→4.0 档两端折算，低配定位取收敛值）。实机 PCF 盘平均 + TAA 时间累积会再抹平一档。
// **人眼在水下时整体乘渲染点 lm.y 的 pow2**（焦散水深门，2026-10 按反馈——人在水下时水越深焦散越浅：
// lm.y = 天光级、水下随水深逐格衰减即水深代理；线性首档经 AgX 后不可辨、pow4 首档水下太黑，pow2 折中；
// 水上恒 1 原观感不变，见 shadow.glsl「焦散水深门」段）
// 2026-10-08 按反馈调浅：默认 2.8 → 2.0；保留旧档供玩家选择。
#define WATER_CAUSTICS_BOOST 2.0 // [1.5 2.0 2.8 3.6]

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
const int   SHADOW_SS_STEPS          = 8;    // 步数：temporalBayer64 64 相位 × TAA 补采样密度（Photon 10 / Bliss·Kappa 16 / 春v2 5，居中）；步序同时是命中软化分档（N 越大帧内梯度越细）；极低配降 6
const int   SHADOW_SS_CONTACT_STEPS  = 3;    // 接触死区步数 K：命中步序 i ≤ K 不软化、整像素全影——近端 trace 的职责是把贴图被 normal offset 浮空带（SHADOW_BIAS_NORMAL 0.05 格起、掠射背光放大至 ~0.11 格）与 PCF 模糊吃掉的接触影满强度补回，软化补不上；两者合计的接缝带至 ~17 cm，K=2〔死区 ~10 cm〕实测补不满、抬到 3（死区 ≈ (K+1)×步长 ≈ 20 cm 覆盖，随 trace 长度自动缩放）；再抬的代价 = 软化段最大深度变浅（(N−1−K)/N）、接管区全影范围扩大
const float SHADOW_SS_LENGTH_NEAR    = 0.4;  // 近距追踪长度（格，dist ≤ 5 格锚点）：接触阴影主尺度（楼梯棱 / 草根）；长度同时定软化段深浅——死区外命中返回 (i−K)/N，抬长 = 同一遮挡落更早步序 = 更深
const float SHADOW_SS_LENGTH_FAR     = 10.0; // shadowDistance 处长度（格，D 外饱和）：远景接管的山体尺度；嫌远景噪声 / 肥影先降此值、嫌步序软化后接管影整体偏浅则抬此值
const float SHADOW_SS_THICKNESS_NEAR = 0.1;  // 命中窗 3D 距离基数（格）：近中景紧窗防薄几何自命中
const float SHADOW_SS_THICKNESS_FAR  = 10.0; // D 处命中窗上限（格）：接管区容表面起伏 + 步距透视放大；自春v2 的 20 收紧——本包无雾，远场掠射退化（径向序对海拔二阶不敏感、命中退化为噪声翻转）直接可见，肥窗放大边界描黑
const float SHADOW_SS_EDGE_START     = 0.75; // 渲染边界淡出起点（×far，相机远平面 ≈ 渲染半径）：远边界掠射带的命中判定退化为噪声、经 TAA 平均成沿边界的渐变描黑——自此处向边界淡出（修复实测问题）
const float SHADOW_SS_EDGE_END       = 0.9;  // 渲染边界淡出终点（×far）：边界带回退无影（本效果接入前的原状态，优于描黑）；接管主体 0.9D → EDGE_START·far 不受影响，嫌边界仍有暗带先抬 START
const float SHADOW_SS_NEAR_BOUNDARY  = 0.7;  // 近/远景分界（×D）：近景不 trace SSS（保透光观感）、远景 trace（保接管，树冠在 0.9D 外必须有影）
const float SHADOW_SS_HANDOVER      = 0.9;  // 接管窗起点（×D）：SSS 渐入终点 = 贴图淡出起点，交接链三锚点（0.7 / 0.9 / 1.0）
const float SHADOW_SS_GATE          = 0.01; // 贴图可见性门（最大通道）：全影像素不 trace——最便宜的性能门（春v2 早退同款）；D 外贴图恒 1、门自然放行
// 整体不透明度（0~1）：接触影 / 接管影轻重的第一调效位
#define SHADOW_SS_STRENGTH 1.0 // [0.5 0.75 1.0]
const float SHADOW_SS_FAR_SCALE     = 1.0;  // D 外整体缩放（春v2 取 0.9 微减弱接管区噪声观感，默认不采纳）
#endif

// ---- 水面（lib/water/*〔2026-10 自 lib/lighting/water.glsl 按功能拆分：waves / fog / ssr / reflection / surface〕；接入 = gbuffers_translucent〔water 入口〕+ composite_fog 水下雾）----
// 前向水面框架（方案移植自春v2 lib/water/*，前向组合式样见其 gbuffers_water / deferred21）：水面恒
// deferred 后绘制，程序保持引擎混合（2026-10 回归修复：水输出整像素最终色 + alpha 1.0，ROP
// srcAlpha/1−srcAlpha 下 = 精确替换、与关混合直写逐位等价；同 draw 玻璃等半透明直通 alpha、ROP
// 原子叠层——曾整 draw 关混合迫使玻璃手动 mix，同 draw 重叠片段读改写竞态 = 玻璃叠玻璃 / 玻璃与
// 水交叠逐帧闪烁）——折射背景 = gaux1 背景快照位移采样 + depthtex1
//（仅不透明）背景深度，水雾 = 彩色吸收 + 满深 mix 雾色（雾基色只取顶点色、不含纹理色），反射 =
// 屏幕 SSR（未命中回退天空 LUT + 解析太阳盘 + **烘焙云层天空盒**——colortex7 八面体槽位单 fetch
// 预乘合成、反射路径不重算云，2026-10 接入）经 Fresnel 混合。**水波法线不走局部 TBN**
//（春v2 deferred21 路线）：波形高度场按世界 xz 求值，法线 = 世界系三点高度差分叉积——与纹理坐标 /
// 几何导数无关，折射与反射共用同一世界法线。玻璃等同 draw 的其余半透明方块经 mc_Entity（block.8）
// 运行时分流、走轻量光照 + ROP 直通。开关宏与数值常量分离（TAAU 同纪律）；删 WATER_FOG =
// 上下两个方向的吸收雾整体编译剔除（纯清水：折射 + 反射仍在）。常量名对齐春v2 便于对照调参
#define WATER_FOG
#ifdef WATER_FOG
const vec3  WATER_FOG_COLOR        = vec3(0.20, 0.83, 0.80); // 雾基色（水上透过水面的深水雾与水下整屏雾两路共用；春v2 默认档 0.20/0.75/0.90，2026-10 调参往返：两轮改绿至 0.20/0.85/0.75 过浓 → 回青蓝档 → 再改绿一档至此——BIOME_MIX 归零后纯色绿感比 biome 时代同数值更重，调参以实机为准）；归一化 [0,1] 域：吸收系数 = 1 − 基色。曾短暂与水下路分离、旋即按反馈合并回单值；2026-10-08 按截图略偏绿：0.20/0.80/0.85 → 0.20/0.83/0.80，保留青色、不回浓绿档
const float WATER_FOG_BIOME_MIX   = 0.0;  // 生物群系水色（水几何顶点色）混入雾基色的权重：默认水 tint 相当蓝（线性域 B ≈ 0.76 vs G ≈ 0.19），0.5 混入会把调好的绿色稀释成蓝——「改绿了看着还是蓝」的实测根因，2026-10 归零（雾色所见即所得 = 纯常量色）；代价是沼泽绿水与普通水同色，想找回生物群系差异回抬本值（≤ 0.1 才能保住 G 主导）
const float WATER_FOG_SUN_SCALE   = 0.125; // 直射辐照度对雾色亮度的系数（春v2 fogColor 的 sunColor × 0.125 同值）：去饱太阳色调制直射贡献
// 水下雾独立太阳项系数（2026-10-08）：0.125 → 0.10，降低白太阳项对雾的抬亮；水上档不动。
const float WATER_UW_SUN_SCALE    = 0.10;
const float WATER_FOG_SKY_SCALE   = 0.10; // 天空环境（vSkyAmbient）对雾色亮度的系数（本包适配：春v2 无此项）——**水上路**；水下走 WATER_UW_SKY_SCALE（2026-10 分离）
const float WATER_UW_SKY_SCALE    = 0.30; // 天空环境项系数——**水下路**（2026-10 按反馈「水下雾偏白偏灰」分离抬档）：白天的雾色由半去饱和白太阳项主导（≈236×0.125 ≈ 29.5）vs 天空蓝项仅 ≈ skyAmbient×0.1，蓝项占比过低 = 雾发白发灰的根因之一；水下抬至 0.30 把雾色拉回青蓝。水上路多轮调参收敛、不随动；嫌还白继续抬本值
const float WATER_FOG_BRIGHTNESS  = 1.0 / 24.0; // 水上雾色亮度总旋钮（2026-09 两轮反馈下调：原档满照雾色正午量级偏亮、实机观感「像自发光」，先 ×1/3 再 ×1/3——累计 1/9；2026-10 两轮续降：1/18 再 ×3/4 至 1/24）：乘在 waterFogLitColor 三项之和（直射 + 天空 + MIN_AMBIENT 地板）上；2026-10 与水下路分离（水下走 WATER_UW_FOG_BRIGHTNESS）；嫌淡按倍率回抬（观感近线性）
const float WATER_MIST_VISIBILITY = 12.0; // 满雾水深（格，春v2 同值）：水深超过此值背景完全变雾色
const float WATER_FOG_TRANSMIT    = 0.5;  // 水深吸收斜率（春v2 WATER_FOG_TRANSMIT 同值）：exp(−(1−基色)·深·本值)，红通道衰减快 → 深水偏蓝
// 水下雾满强视距（格，composite_fog 水下分支）：春v2 UNDERWATER_FOG_MIST 50 偏清、按 MC 观感收紧至 24；
// 2026-10 三轮按反馈回抬降浓度——24 → 36 → 48 → 64（中点 12 格遮盖权重 39% → 28% → 22% → 17%，嫌还浓继续抬）
#define WATER_UW_VISIBILITY 64.0 // [32.0 48.0 64.0 96.0 128.0]
const float WATER_UW_TRANSMIT     = 0.28; // 水下距离吸收斜率（composite_fog 水下分支；与 WATER_FOG_TRANSMIT 分离独立调；2026-10 随 VISIBILITY 三轮同步下调：0.5 → 0.4 → 0.33 → 0.28）
const float WATER_UW_FOG_BRIGHTNESS = 1.0 / 18.0; // 水下雾色亮度旋钮（结构同 WATER_FOG_BRIGHTNESS、作用 waterFogLitColor 三项之和；基色两路共用 WATER_FOG_COLOR）：分离时取 2026-09 两轮反馈的收敛值 1/9，水上路的续降不波及水下；2026-10-08 按反馈 1/9 → 1/15，雾色整体降低 40%（直接观视与水下 SSR 命中雾同源）；同日按截图再至 1/18（比 1/15 再降约 17%）
// 水下物体额外彩色吸收（2026-10-08）：仅眼睛在水下且 WATER_FOG 开启时生效。
// 深度代理 = 1 − lm.y²（与焦散天光 pow2 门互补），独立于眼到物体的距离雾；
// exp(−(1−WATER_FOG_COLOR)·代理·本值)，红光比蓝光衰减快，近处深水物体也呈水色。
// 0 = 关闭；不判物体是否在水中，水下看低天光岸壁 / 洞穴亦会偏色（按反馈接受的近似）。
const float WATER_UW_SURFACE_ABSORPTION = 2.0;
// 双重吸收后的水下物体亮度补偿（2026-10-08）：只乘物体着色，不提亮雾，不改指数吸收强度。
// 1.0 = 无补偿；地形 / 实体 / 简单半透明共用，WATER_FOG 关闭或眼睛出水时不生效。
const float WATER_UW_SURFACE_BRIGHTNESS = 1.35;
// 水下雾环境光门（2026-10「无光水下雾依然很亮」修复；首版「线性 × 无地板」两轮调参后整形）：
// eyeBrightnessSmooth 的**天光分量**（0..240）归一后经「幂 + 地板」整形乘进 waterFogLitColor 整体
// ——雾色光照的 vDirectIrradiance / vSkyAmbient 是帧级 varying（海平面天空条件、无位置信息）、
// MIN_AMBIENT 是常数地板，洞窟 / 深水 / 桥影下眼位天光衰减到 0 时三项照付 = 无光水下雾恒亮的
// 根源；天光分量承载位置遮挡（天光级夜间不降、昼夜量级由 varying 自带）。**方块光分量不参与**
//（2026-10 按反馈剔除——火把 / 海晶灯的暖色雾照未建模，max 混入只会让光源旁雾色凭空偏亮；
// 方块光暖色贡献为扩展点、接入时单建一项）
const float WATER_UW_ENV_LIGHT_SCALE = 1.0 / 240.0; // 单位换算（0..240 光照级 → 0..1），非调参旋钮
const float WATER_UW_ENV_POWER = 2.5;  // 感知线性化幂（首版线性门：雾色是 HDR，线性缩放经 AgX 压缩后高段不敏感——亮度骤变全挤在极低光照段、中段几乎看不出变化；pow 把变化摊到全量程，2.5 为按该压缩形状的收敛值）
const float WATER_UW_ENV_FLOOR = 0.001; // 亮度地板（首版归零档实测：环境光到最小值时雾彻底消失、水看起来像空气——保住最低能见度的暗雾；0.2 → 0.1 → 0.01 → 0.001 四档按反馈嫌亮续降，近归零、仅防整支消失，归零即回无地板档）
// ---- 波面漫反射起伏（2026-10 接入，「水面光照平」的拟合——起伏只调制雾色光照的直射项；零 march、
// 零新采样，见 lib/water/surface.glsl 水雾段。曾同期接入的水体 SSS〔逆光透射相位，GDC 2011 fake
// translucency 谱系〕两轮调参后逆光对齐带观感仍不自然、按反馈整体移除，git 历史含完整形态）----
const float WATER_DIFFUSE_STRENGTH = 1.0;  // 波面漫反射起伏权重（0 = 无起伏回退档、雾色只剩平稳环境底）：直射项乘 mix(1, N·L^power, 本值)；旧档（春v2 lightFactor：三项和整体 × mix(1, N·L, 0.5)）把天空环境 / 地板一并压平，且波面法线倾角 ~24° 下正午 N·L 实际波动仅 ±3%——水面「光照平」的根源
const float WATER_DIFFUSE_POWER    = 3.0;  // 起伏对比锐度（pow 指数）：迎光 / 背光波面的雾色明暗比，N·L∈[0.9,1] 经 ^3 → 太阳项波动 ~27%（旧档 ~10 倍）；嫌平淡抬本值
#endif
// ---- 波形 / 视差 / 折射 / 反射（WATER_FOG 之外的水面效果常量，gbuffers_translucent 消费）----
const float WAVE_SPEED            = 1.5;  // 波形时间速度倍率（春v2 默认档）
const float WAVE_FREQUENCY        = 1.0;  // 世界 xz → 波形域频率（春v2 同值）：特征尺度 ~2.9 格
// 波幅档位（春v2 同值；type1 以 pow(本值, 1.35) 混入高度 = 法线坡度的实际旋钮；再乘掠视角衰减
//〔|dot(视线, 水面几何法线)| 线性——见下方注记，俯视全幅、掠视趋平〕）
#define WAVE_HEIGHT 0.2 // [0.1 0.2 0.4 0.6]
// 2026-10-08 恢复低频粗糙度 mask：波团疏密变化；每水像素共享两次采样。删宏回均匀波幅。
// 2026-10-08 按反馈暂时关闭（游戏内 WATER 子屏仍可重新打开，或取消下行注释恢复默认开启）。
//#define WAVE_ROUGHNESS_MASK
// 足迹过滤仅法线侧：保留第一 octave，不恢复远距整波幅淡出。
const float WAVE_FILTER_LOW = 0.35; // 高频 octave 噪声域像素足迹
const float WAVE_FILTER_HIGH = 0.85;
const float WAVE_FILTER_NORMAL_SCALE = 0.35;
const float WAVE_FILTER_NORMAL_MAX = 0.5; // 差分上限（格），避免远水全平
const float WATER_SSR_CONFIDENCE_START = 0.65; // 原验证带内最后 35% 连续转天空，不扩大接受域
const float WAVE_NORMAL_EPS       = 0.05; // 世界差分步长 ε（格，春v2 getWaveNormalDH 同值）：三点高度差分的水平间距
//（曾有的 WAVE_FADE_START/END 波形距离淡出〔24→64 格到平水面〕已按反馈移除——2026-10 嫌远水太平，
// 远水按像素足迹过滤第二层高频，保留基础波与平均高度；剩余噪声交 TAA 累积。同月二次改版：换成
// 掠视角衰减——波幅混入系数直接乘 |dot(视线, 水面几何法线)|〔水平水 = sin 仰角；点乘 1 完全粗糙 /
// 0 完全平坦，无整形窗——首版 smoothstep 窗 WAVE_GRAZE_LOW/HIGH 0.05/0.35 旋即按反馈简化为
// 裸点乘线性档，git 历史含完整形态〕，shadeWaterSurface 消费：掠视〔波特征被 1/仰角透视放大到
// 亚像素的闪烁带〕趋平水、俯视全波幅，按视角压平不误杀高处俯视的远水。与 WAVE_FILTER_* 足迹
// 过滤叠加分工：足迹过滤砍高频 octave（按像素采样密度）、掠视角衰减砍整支波幅（按视角），两者
// 独立生效。衰减 0 时高度恒 1（平水基准）——法线恒 up、视差 g0 = 0 自然跳过，整支波形消费随
// 系数一致收敛）
// 掠视角衰减玩家旋钮（2026-10 接入设置屏）：开关宏 + 嵌套强度（SHADOW_SCREEN_SPACE /
// SHADOW_SS_STRENGTH 同款形态——父开关关闭即强度自动隐藏、无悬挂）；删 WAVE_GRAZE_FADE 定义 =
// 衰减整段编译剔除、全视角全波幅（逐位回退）。强度语义：1 = 裸点乘线性（掠视完全平坦，默认档
// = 接入时行为）、中间值经 mix(1, |dot|, 强度) 内插（0.5 = 掠视水保留一半波幅）；0 档由开关
// 承担、值表不含 0
#define WAVE_GRAZE_FADE
#ifdef WAVE_GRAZE_FADE
#define WAVE_GRAZE_STRENGTH 1.0 // [0.25 0.5 0.75 1.0]
#endif
// 水面「水平面假设」族共用的几何面水平度门（|世界几何法线 · up|，导数法线由 gbuffers_translucent
// 先于 discard 求好传入），低于本值（陡坡流动水 / 瀑布竖直流面）触发两处跳过：①「未抖动视线 ∩
// 水平面」的去抖替换——水平面假设在竖直流面上把水面点横向搬离真实几何几格，波形采样无锚定无感、
// 但 SSR march 起点随 viewPos 前移 = 反射从错误位置发出（2026-10 修复）；②WAVE_PARALLAX 视差段
//（隐式面 = 水平面下方波高场）——竖直面无意义，且 |视线.y| ≈ 0 的一阶解饱和于 ±MAX_SHIFT、着色
// 点 / SSR 起点沿视线在流面两侧整幅漂移（2026-10 竖直面修复接入）。0.5 ≈ 45° 坡度分界，水平静水
//（= 1）两处恒生效、行为不变
const float WATER_DEJIT_MIN_UPNESS = 0.5;

// ---- 水面视差（WAVE_PARALLAX；着色点沿视线 march 到波高场隐式面，迭代与守卫见 lib/water/surface.glsl）----
// 开关宏与数值常量分离（TAAU / WATER_FOG 同纪律）：删 WAVE_PARALLAX 宏 = 视差段编译剔除，水面回
// 平几何着色（法线 / SSR 起点 / 水深全部锚回未位移位置）
#define WAVE_PARALLAX
#ifdef WAVE_PARALLAX
const float WAVE_PARALLAX_HEIGHT     = 1.0;  // 视差幅度系数（竖向位移〔格〕= (波高 − 1) × 本值）：波高以 1 为平水基准、恒 ≤ 1 ⇒ 隐式面在几何水面以下（波谷下探、波峰贴面）；默认 WAVE_HEIGHT 0.2 档波高摆幅 ~0.11 ⇒ 实际最大下探 ≈ 0.11 格，嫌弱抬本值（波高档抬大时位移随字段全域等比放大）
const float WAVE_PARALLAX_MAX_SHIFT  = 0.75; // 沿视线位移上限（格）：一阶解 t = 高差 / |视线.y| 在掠射时发散、于此饱和（波形距离淡出移除后远水掠射会进饱和带，位移有界、亚像素尺度不可见），上限兜 SSR 起点 / 水深换算不跑飞
#endif

// 折射位移强度（像素域 × 视口高 /(距离 + 0.5)，春v2 WAVE_REFRACTION_INTENSITY 的分辨率无关改写）：
// 波扰动法线 xy 推背景采样位
#define WATER_REFRACTION_STRENGTH 0.6 // [0.2 0.4 0.6 1.0]
const float WATER_REFRACTION_MAX  = 0.03; // 折射位移上限（× 视口高像素）：防近距 / 强法线把背景拉穿屏
// 水面背景快照（colortex4，deferred_init 编码 / water 解码）的编码余量：存储值 = 场景色 × 曝光 ÷ 本值
//（曝光归一化后场景动态范围 ~1e-3~30，÷16 装进 RGBA16 的 [0,1]——旧「colortex4 场景副本」方案被删的
// 根因即裸存 HDR 被 [0,1] 硬截断；两端同帧读同一曝光槽位、解码精确还原，仅 > 16/exposure 的极亮背景
//〔快照内直射白面 / 日盘〕轻微滚降——经水雾吸收 / Fresnel 后不可见）。抬大 = 高光端更早滚落、压小 =
// 暗部量化变粗；16 为「白天雪地直射 ~60 保留 / 夜晚暗部 ~1.4e-5 量化低于噪声地板」的收敛值
const float WATER_BG_SNAPSHOT_HEADROOM = 16.0;
const float WATER_REFRAT_IOR      = 1.2;  // 水折射率（春v2 同值）：水下视角的 Fresnel 折射角换算与全内反射判定
const float WATER_F0              = 0.02; // 水面 Fresnel 基准反射率（春v2 同值，(1−1.33/2.33)² 量级）
// 水下 TIR 未命中回退色的压暗系数（2026-10 按反馈接入，shadeWaterSurface 的 miss 分支消费）：水下
// 仰视水面的镜面带 SSR miss 时回退 waterSkyReflection(向下方向)——LUT 下半区按 SKY_CLAMP_TO_HORIZON
// 全部存的是**钳到切线的地平线辉光**（太阳侧含 Mie 前向峰，是 LUT 全图最亮区域），云盒八面体边缘
// bilinear 还会串进少量云纹理 ⇒ 回退量级反超直接可见的天空，镜面带观感「比天空还亮」。物理上该处
// 应为被水下雾吸收后的**深水镜像**（水体另一侧的雾色，近似扩展点），辉光兜底量级过高。本值乘在
// 回退色整体（LUT 辉光 + 边缘串色云）；**只压 miss 回退**——SSR 命中的镜像水下几何是真实内容、本就
// 不亮，Fresnel 反射权重是物理量亦不动（2026-10 首试曾缩放水下 fresnel、按反馈回退——压权重会把
// 折射背景同步顶出来，错因不在遮罩强度）。1.0 = 回退原档
const float WATER_UW_REFL_DIM    = 0.2;
// 水下 TIR 回退的色调加权（与 DIM 配套、亮度 / 色相分离）：DIM 纯亮度缩放后回退随 LUT 辉光的
// 灰白散射走、饱和度低观感发灰——本 vec3 仿水体吸收的通道差（红快蓝慢）把色相拉向蓝青；分量
// 全 1 = 回退中性灰（删色偏基准档）。嫌青得不够浓压低 r / 抬高 b，嫌发绿抬 r 压 b
const vec3  WATER_UW_REFL_TINT   = vec3(0.75, 0.95, 1.0);
// 水反天空回退的天光门（2026-10「暗处水面反射天空盒爆亮」修复，shadeWaterSurface 的 miss 分支
// 消费）：LUT 天空 + 云天空盒是天空条件的帧级内容、对「该水面是否敞向天空」一无所知，按水顶点
// lm.y 门控。两级整形（首版线性 clamp 两轮调参）：①下界重映射——水上暗处（屋檐 / 桥下 / 洞口）
// 的水面 lm.y 常停在 0.1~0.3 的残余天光而非真 0，天空盒是 HDR、线性门下 10~30% 的亮度经 AgX 后
// 依旧明晃晃 ⇒ [LOW, 1] 重映射到 [0, 1] 把残余段压死；②感知域回线性——lm 光照级是感知域刻度
//（光照贴图语义），被门控的回退色是线性域 HDR，乘前过 srgbToLinear 同值的幂回到线性域
const float WATER_REFL_SKY_GATE_LOW   = 0.1;  // 重映射下界：低于此天光级的天空回退整支归零
const float WATER_REFL_SKY_GATE_GAMMA = 2.2;  // 感知域 → 线性域幂（srgbToLinear 同值）
// SSR = 2D SSPT 屏幕域 march（春雷 sstTrace 移植，机制见 lib/water/ssr.glsl「屏幕空间反射」段）
// 2026-10-07：步距减半（20 → 40）实测改善反射发虚，保留密度并优化精修重复读取 / 无效验证。
const float WATER_SSR_SHORT_EDGE_STEPS = 40.0; // SSR 步距定标（单一整体调节变量）：步距（buffer 纹素）= 视口最短边 ÷ 本值——1080p 基准 → 27 px/步（旧 20 档为 54 px/步；角度自适应见下方开关）；抬大步距变小（更密更贵）、压小步距变大（更省更粗）。march **不限步数**、走完可见段到屏幕 / 视锥边缘为止；步距随分辨率等比 ⇒ 最坏步数 ≈ 对角线 ÷ 步距 ≈ 2.3 × 本值 ≈ 92（TAAU 子区域段更短、再 × RENDER_SCALE），与分辨率无关；temporalBayer64 64 相位 × TAA 时间累积收敛缝隙
// 角度自适应步距 A/B（2026-10-07）：掠视保持基准，较正视最多放粗 25%。
// 角度只用调用方的稳定面法线；不依赖动画波面法线，避免步距随波场逐帧摆动。
// 注释开关只关闭角度自适应；与短段最低采样开关均关闭时回固定 40 档。仅源码诊断，不列设置。
#define WATER_SSR_ADAPTIVE_STRIDE
const float WATER_SSR_STRIDE_ANGLE_LOW = 0.45;
const float WATER_SSR_STRIDE_ANGLE_HIGH = 0.85;
const float WATER_SSR_STRIDE_MAX_EXTRA = 0.25;
// 短屏幕段最低采样 A/B（2026-10-07）：最多以段长 / 3 作为步距，长段不变。
// 减少短段只采 1~2 点的相位漏采；仅增加短段采样预算，命中 / 拒收仍即时终结。
// 注释本开关 = 回到上一轮仅角度自适应的方案，不影响其他开关。
#define WATER_SSR_SHORT_SEGMENT_SAMPLES
const float WATER_SSR_SHORT_SEGMENT_MIN_STEPS = 3.0;
const float WATER_SSR_HIT_TOLERANCE = 0.1; // 命中验证松弛量（格，waterSsrHitConfidence）：场景视深须落在「交点射线深 ±（整步跨度 × BIAS + 本值）」带内才判真命中（2026-10 调序起验证在精修交点纹素上做、分子与带宽分置，见 ssr.glsl）；春雷原档 0.05，按反馈多轮调参（0.05 → 0.2 → 0.4 → 回落 0.1 折中）——过紧时命中判定在阈值边缘随 dither 相位逐帧翻转，命中取场景色 / miss 取天空色的闪变即反射噪点，抬宽容度使命中稳定、噪点收敛；代价 = 前景剪影拉伸伪命中的接受度变大（嫌边缘拉丝回降）
const float WATER_SSR_HIT_BIAS = 1.0; // 命中验证步长项倍率：带宽 = 整步跨度（上一步 → 候选步的射线深差）× 本值 + TOLERANCE——2026-10 调序起分子与带宽分置（见 ssr.glsl）：分子 = 精修交点穿透深 ≤ 1/16 步长跨度 ⇒ 真命中 residual ≤ 1/(16·本值) 恒满置信（旧序分子 = 候选过冲随 bayer 相位均匀分布 ⇒ confidence 逐帧翻转的噪点根源），带宽维持整步 = 与旧序同宽容度、剪影拒收阈值不变（曾试收敛区间〔1/16 步长〕作带宽的更严档被否——对掠射打到岸线 / 剪影边缘等深度不连续处的真命中过严）；掠射大步长下步长项主导带宽、倍率使容忍随步长放宽，近段步短仍由固定项主导
const float WATER_SSR_DIR_MIN_DOT = 0.94; // SSR 命中方向一致性下限（2026-10 接入，cos 域）：dot(起点 → 碰撞点, 步进方向) 低于本值 → 信任因子 smoothstep 归零（waterSsrDirectionTrust，乘进命中 confidence = 因子 0 即验证失败、march 终结走天空回退）——真命中的夹角仅来自深度量化 / 纹素足迹 / refine 残留（~1-5°，重建点必在射线路径近旁），伪命中（剪影 / 深度跳变、表面不在路径上）夹角无界；0.94 ≈ 20° 起步，嫌误拒（掠射极端几何）降到 0.90（≈26°）、嫌伪命中漏过抬到 0.97（≈14°）。**首步候选（i == 0）豁免方向验证**（2026-10「折角天空线」实机修复，见 ssr.glsl march 内注）：起步即碰撞类命中的「起点 → 碰撞点」基线趋零、方位无意义地无界，全置信误杀成沿折角的直线天空色（实机 A/B 确认恒信任后消失）；豁免后仍受深度带验证把关，i ≥ 1 中远途候选方向验证照常
// 方向信任因子总开关：删定义 = waterSsrDirectionTrust 恒 1（**全程**恒信任、含 i ≥ 1，方向验证
// 整段旁路、深度带验证照常）——诊断 A/B 档（2026-10 折角天空线排查用，已定位首步豁免修复、默认
// 恢复启用）；恢复恒信任排查时删下一行定义即可
#define WATER_SSR_DIR_TRUST
//（Fresnel 低值免 march 门槛 WATER_SSR_MIN_FRESNEL 已按反馈删除，2026-10——离法线 ~53° 锥内有屏内命中点的
// 反射被确定性误杀成天空回退（HDR 天色在近法线小 Fresnel 权重下仍可见），改为恒 march、出屏 miss 交天空回退
// 自然处理，见 lib/water/surface.glsl shadeWaterSurface 反射段注，git 历史含完整形态）
//（屏幕边缘向天空回退淡出 WATER_SSR_EDGE_FADE 已按反馈删除，2026-10——带宽观感过宽：命中整段取快照色、出屏即 miss 硬切，git 历史含完整形态）
//（反射方向地平线钳制常量 WATER_REFL_MIN_UP 已按反馈删除，2026-10——反射向量背向顶点法线时改为整支
// 回退顶点法线（水平面 up）反射方向，见 lib/water/surface.glsl shadeWaterSurface 内「背向回退」段注）
const float WATER_GLINT_EXP       = 512.0; // 太阳 / 月亮镜面高光锐度（pow 指数）：主导光源方向的波面亮斑
// 高光亮度（× vDirectIrradiance）：峰值 ≈ 直射辐照度量级、经 AgX 滚落成波光
#define WATER_GLINT_BRIGHTNESS 1.0 // [0.5 1.0 2.0]

// ---- 雨天地表湿滑（`WET_SURFACE`，2026-10；lib/common/pipeline/wetness.glsl 湿度场 + gbuffers_opaque
//      湿面法线压平 + program/deferred_ssr〔deferred2 槽〕SSR 混合）----
// 湿滑程度 = 露天 lmcoord.y 门 × 水坑噪声 × 朝上度权重（2026-10 按反馈「方块侧面没有雨天湿滑效果」
// 接入侧面：反射可见度随世界法线朝上度单调增——越朝上的面水膜越厚，侧面半权、底面〔雨打不到〕无湿）
// × rainStrength——gbuffer 压平侧与 deferred2 消费侧
// 同一函数（terrainWetness）、同一输入（绝对世界 xz / 原始 lm.y / 世界法线 y）单真源求值，法线压平量与
// SSR 可见度结构性一致。SSR 可见度 = 湿度 × 水面 Fresnel 近似（waterFresnel 水上档），march / 天空回退 /
// 命中段雾全链复用水面反射件（lib/water/ssr.glsl + reflection.glsl）。开关宏与数值常量分离（TAAU 同纪律）；
// 删宏 = 压平段与反射段整体编译剔除、deferred2 透传旁路（colortex6 原样写回——composite_fog 旁路同款
// 翻转纪律，不可 discard）
#define WET_SURFACE
#ifdef WET_SURFACE
const float WET_SKY_LM_LOW   = 0.90; // 露天判定下沿（原始 lmcoord.y 的 smoothstep 窗，0.90→0.95 映 0→1）：天光 14 级起坡、15 级满湿——檐下 / 树冠下经光照传播衰减不触窗、天然无湿；gbuffer 侧 vLmcoord.y 与 deferred2 侧 colortex5.a 同域（原始值、不经 remapLightmap）
const float WET_SKY_LM_HIGH  = 0.95; // 上沿：满湿锚点（用户规格 0.9~0.95）；窗口收窄 / 放宽两端联动
const float WET_NOISE_LOW    = 0.0;  // 水坑噪声门下沿：噪声 ∈ [本值, WET_NOISE_HIGH] 经 smoothstep 映 [WET_NOISE_FLOOR, 1]，映射结果整体 pow2（wetness.glsl 内连乘实现）——边缘收紧成圆形水坑、中低值压死
const float WET_NOISE_HIGH   = 0.7;  // 上沿（2026-10 按反馈自 0.4 抬高并配 pow2）——双 octave 值噪声均值 ~0.5，0.7 门 + pow2 = 只有噪声峰值区成湿（稀疏水坑档）、噪声中低值 pow2 后趋地板 = 干地；嫌水坑多降本值、嫌少抬
const float WET_NOISE_FLOOR  = 0.1;  // 映射输出下沿（2026-10 按反馈接入，原 0.0）——干地湿度地板：映射域 [0.1, 1] 而非 [0, 1]，pow2 后地板 = 0.01（1% 湿）——恒低于 WET_SSR_MIN_WETNESS（0.01 < 0.03）不触发 SSR / 免 march，仅保留「雨后微潮」的极弱湿润感（法线压平 1% 不可辨）；0.0 = 回全干地板档
const float WET_NOISE_SCALE  = 1.0 / 1024.0; // 世界 xz → noisetex uv（基 octave 周期 1024 格 ≈ 水坑团块尺度；2026-10 按反馈「噪声太密」三轮放大：16 → 48 → 480 → 1024；REPEAT 寻址天然抗大世界坐标精度衰减——程序化 hash 直算在 ~1e4 后精度劣化，noise.glsl 头注同限）
const float WET_NOISE_OCTAVE2_SCALE = 2.63; // 次 octave 频率倍率（权重 1/3）：破 16 格平铺感
const float WET_TOP_NORMAL_LOW  = -1.0; // 朝上度权重窗（世界法线 y 的 smoothstep 下沿；2026-10 按反馈自 0.6 拉宽——旧「顶面判定窗」把侧面恒门为 0 湿 = 方块侧面无湿滑效果的根因）：湿度（法线压平量与 SSR 反射可见度的共同来源）随朝上度单调增——顶面 1 满档 / 侧面 0.5 半档（平滑窗中点）/ 底面 0（雨打不到朝下的面），同一水坑噪声锚点下顶面恒 ≥ 侧面（用户规格「越朝上可见度越高」）；MC 地形轴对齐三档即全部取值，labPBR 法线贴图的中间值平滑过渡。顶面行为与旧窗逐位一致（gbuffer 侧几何法线 y=1 两窗同给满档）；gbuffer 侧取导数几何法线、deferred2 侧取解包法线（已含压平），无 normal 贴图时两侧逐位一致。嫌侧面湿感强 / 弱改 LOW（越接近 0 侧面越干，回 0.6 档 = 侧面全干）
const float WET_TOP_NORMAL_HIGH = 1.0;  // 上沿（= 顶面满湿锚点，恒为 1）
const float WET_SSR_MIN_WETNESS = 0.03; // 免 march 湿度门槛（**只看湿度、与视角 / Fresnel 无关**，2026-10 按反馈自 WET_SSR_MIN_WEIGHT〔湿度 × Fresnel 门槛〕更名改判：旧门槛下 Schlick F0 0.02 使眼点正下方 ~53° 俯视锥——地面投影为以脚下为圆心、半径 ≈ 1.34 × 相机离地高度的硬边干圈，越高越大——整片跳过；Fresnel 现只进 mix 权重）：干地地板（WET_NOISE_FLOOR pow2 = 0.01）恒在门下、微潮免 march；0.0 = 恒 march
#endif

#endif
