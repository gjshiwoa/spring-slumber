// 全部 uniform 声明集中于此，由 program 文件 include
#ifndef LIB_UNIFORMS_GLSL
#define LIB_UNIFORMS_GLSL

uniform sampler2D tex; // 采样纹理统一命名 tex
uniform sampler2D noisetex; // 引擎程序化噪声纹理（边长 = constants.glsl 的 noiseTextureResolution，线性滤波、REPEAT 寻址）：水焦散波场（lib/lighting/caustics.glsl）

uniform sampler2D normals;  // 法线贴图（labPBR 约定，rgb 存切线空间法线，读取端 *2-1 后经 TBN 变换，不翻 Y）
uniform sampler2D specular; // 高光贴图（labPBR 约定，r = smoothness，g = F0，b = porosity/SSS，a = emissive）

uniform sampler2D colortex1; // bloom tile 图集（composite4~8 下采样、composite9~12 上采样回卷，tile0 终态 = 合并后的完整泛光，final 消费 tile0、composite12 测光读 tile4）+ 云形状场槽位（图集右侧 r 通道，布局见 bloom.glsl 的 cloudFieldRect——deferred 槽生成、deferred_init 伪自阴影探针读，见 clouds.glsl）。gbuffers 阶段不可采样（同上）
uniform sampler2D colortex3; // TAA 历史缓冲（clear = false）：rgb = 上帧混合色，a = 上帧最近片元线性深度；仅 composite_taa 读写。gbuffers 阶段不可采样（同上）
uniform sampler2D colortex4; // gbuffer: rg = 打包 albedo（4x8→2x16），ba = 打包高光贴图 RGBA；deferred_init 解包消费后整面覆写为**曝光归一化背景快照**（编码式见 constants.glsl 的 WATER_BG_SNAPSHOT_HEADROOM——RGBA16 [0,1] 域装下 HDR，water 折射 / SSR 位移采样的稳定背景）。**gbuffers 阶段读须用别名 gaux1**
uniform sampler2D colortex5; // gbuffer: rg = 八面体观察空间法线，ba = 原始 lmcoord；光照接入后读取。**gbuffers 阶段读须用别名 gaux2**
uniform sampler2D colortex6; // 场景主颜色缓冲（RGBA16F），deferred_init 初始化、前向半透明 after 路径合成（2026-10 兼容性标准化：**全部 colortex6 写入者输出 (色, alpha) 交硬件 alpha 混合直写〔时机两可族经 per-buffer 行、water 族经引擎默认半透明混合〕、gbuffers 阶段无任何 fetch**——gaux3 手动合成全面废止，读正在写的附件在个别驱动未定义）、composite_taa 抗锯齿，final 读取后直接输出屏幕（不再写回）。放 colortex6 而非惯例的 colortex0 的历史缘由：colortex0~3 的采样单元在 gbuffers 阶段被游戏纹理 / 深度绑定占用（colortex0 即几何纹理 tex，实测采样返回纹理图集内容——water 曾因此把图集画上屏幕），colortex0 全程未使用

// gaux1~4 = colortex4~7 的采样别名（gbuffers 阶段读缓冲的规范名——deferred / composite / final 阶段
// 两者同单元等价、均可用；gbuffers 程序一律用 gaux 名，见各 colortex 注释）
uniform sampler2D gaux1; // = colortex4：帧内两阶段——before-deferred 手动合成类（color / beacon 外壳）读 gbuffer 背景包装；deferred_init 之后 = 曝光归一化背景快照（water 折射 / SSR 采样 × vBgDecodeScale 解码）
uniform sampler2D gaux2; // = colortex5
uniform sampler2D gaux3; // = colortex6：场景主颜色（**gbuffers 阶段已无读者**——2026-10 兼容性标准化：所有写 colortex6 的 gbuffer 一律 (色, alpha) 直通 + 硬件混合〔时机两可族 per-buffer 行 / water 族引擎默认〕，读正在写的附件废止；声明保留为 gaux 别名族完整性的文档位，composite 阶段读主颜色用 colortex6 名）
uniform sampler2D gaux4; // = colortex7：杂项簇（pass 顺序标记、天空 LUT 探针——ambient.glsl / pass_order_marker.glsl 经本名采样，gbuffers vsh 消费）

uniform sampler2D colortex7; // 杂项数据缓冲（clear = false，左下角杂项簇）：云层天空盒 256×256（八面体烘焙云，composite12 写 / water 反射经 gaux4 读）+ 曝光槽位 1 texel（exposure.glsl 的 exposureTexel）= 自适应曝光（composite12 写、composite_taa 与 final 读）、天空 view LUT 200×200（太阳半区 + 月亮半区，deferred_init 读）、aerial 透视 LUT 64×192（(460,0) 起，composite_fog 读）

uniform sampler2D depthtex0; // 深度缓冲（全部几何）；deferred 时刻除不透明外可能已含 deferred 前绘制的 textured 族（粒子 / 闪电）深度，天空判定须用 depthtex1；composite 时刻含半透明与手，TAA 重投影取十字最近片元
uniform sampler2D depthtex1; // 深度缓冲（仅不透明几何，含手部；粒子等非不透明写入被排除）：deferred_init 天空判定 / 光照位置重建用

// ---- SR 超分模组（superresolution.v3.json；SR_UPSCALE 由 constants.glsl 依 mod 注入宏派生，
//      须先于本文件引入——各 program 的既有引入序已满足）----
#if defined(SR_UPSCALE)
uniform sampler2D colortex31; // SR 运动矢量缓冲（colortex31Format = RGBA16F）：rg = 本帧→上帧位移（渲染分辨率归一 uv 域、无抖动采样位）、b = 实体层标记（gbuffers_entities 写 1、deferred_init 读回保留实体 MV / 其余写相机 MV）。SR 只读不写
uniform vec2 SRScaledViewportSize; // SR 实际整数渲染尺寸（以 vec2 提供），随窗口与档位更新
uniform vec2 SRJitterOffset;  // SR 当前帧 jitter（渲染分辨率像素域，与 noise.glsl 的 Halton 表同域约定）：taaJitterSample 消费——applyTAAJitter / applyJitter / vJitter 全链自动跟进
#endif

uniform vec4 entityColor; // 实体着色（受伤红闪等），rgb 为目标色，a 为混合权重；仅 gbuffers_opaque_entities 使用

// 引擎 alpha test 参考值（OptiFine 文档的标准消费式 = if (color.a < alphaTestRef) discard;），逐 draw
// 更新。Iris 在 alphaTest.* = off 下恒 0（off 映射 ALWAYS、取其 reference 0），老 OptiFine（1.12-）不
// 识别该 uniform 亦恒 0——pass 侧统一经 constants.glsl 的 CUTOUT_REF 钳制消费（下限 ALPHA_CUTOUT
// 兜底），全版本一致；shadow 阶段不消费（恒 ALPHA_CUTOUT）
uniform float alphaTestRef;

uniform float viewWidth;  // 视口宽度（像素）；lib/post/bloom.glsl 计算 colortex6 源纹素尺寸
uniform float viewHeight; // 视口高度（像素）；同上
uniform float far;        // 相机远平面（≈ 渲染半径 × √2 + 余量）：屏幕空间追踪阴影的渲染边界淡出锚点（shadow.glsl；GLSL 330 非保留字，各参考包通用名）
uniform float frameTime;  // 帧间隔（秒）；自动曝光时间适应
uniform float frameTimeCounter; // 游戏时间累计（秒，世界加载起算）；云层风场动画时基（lib/atmosphere/clouds.glsl）
uniform int frameCounter; // 帧序号；TAA jitter 相位（frameCounter & 7）与首帧守卫

// ---- TAA 重投影（lib/common/utils/noise.glsl + lib/post/taa.glsl + utils/space.glsl 上一帧换算）----
uniform vec3 cameraPosition;         // 本帧相机世界坐标
uniform vec3 previousCameraPosition; // 上帧相机世界坐标
uniform mat4 gbufferProjection;         // 视图 -> 裁剪（当前帧，正向投影）：屏幕空间追踪阴影的每步射线投影（shadow.glsl）
uniform mat4 gbufferProjectionInverse;  // 裁剪 -> 视图（当前帧）：TAA 深度重建；屏幕空间追踪阴影的场景点重建共用
uniform mat4 gbufferPreviousModelView;  // 视图 -> 世界（上帧）：TAA 重投影
uniform mat4 gbufferPreviousProjection; // 世界 -> 裁剪（上帧）：TAA 重投影

// 以下为天空 / 光照效果库所需：天空（lib/atmosphere/）与光照（lib/lighting/）均已接入 deferred_init
uniform mat4 gbufferModelView;       // 世界空间 -> 视图空间（3x3 部分把世界方向转观察方向：植物晃动偏移 gbuffers 侧转观察系，lib/common/pipeline/waving.glsl）
uniform mat4 gbufferModelViewInverse; // 视图空间 -> 世界空间（viewToWorldDirection / viewToRelativeWorld 共用）

uniform vec3 sunPosition;         // 太阳方向（视图空间，长度为到太阳的距离）
uniform vec3 moonPosition;        // 月亮方向（视图空间，同上；与太阳恰好相对——白天沉于地平线下、月亮半区自然归零）；天空 LUT 月亮半区光源
uniform vec3 shadowLightPosition; // 当前主导光源（白天太阳 / 夜晚月亮，视图空间）

uniform float sunAngle;     // 太阳角度 [0,1)，0 = 日出，0.25 = 正午，0.5 = 日落，0.75 = 午夜
uniform float rainStrength; // 雨强度 [0,1]
uniform int isEyeInWater;   // 0 = 大气中 / 1 = 水中 / 2 = 熔岩中（水下效果扩展点）
uniform ivec2 eyeBrightnessSmooth; // 眼位光照级的引擎平滑值（x = 方块光 / y = 天光，各 0..240、进出光照平滑过渡）：水下雾亮度随环境光调制（lib/water/fog.glsl 的 waterUwEnvLight）

// ---- 阴影贴图（program/shadow.glsl 写入 + lib/lighting/shadow.glsl 采样）----
uniform mat4 shadowModelView; // 相对世界（当帧相机为原点、与 gbufferModelView 同源空间）-> shadow 视图
uniform mat4 shadowProjection; // shadow 视图 -> shadow 裁剪（正交）
uniform mat4 shadowModelViewInverse; // shadow 视图 -> 相对世界：shadow vsh 水面 / 植物晃动的绝对世界坐标重建（焦散图案世界锚定，BSL / 春v2 同款逆链）
// shadowtex0 开硬件比较（constants.glsl 的 shadowHardwareFiltering0）、声明为 sampler2DShadow：
// 比较采样即深度比较 + 2×2 双线性插值，一次采样顶手动 4 次比较（GLSL 330 的 textureLod
// 重载同样走硬件比较滤波，采样端显式 LOD 0 免隐式导数）
uniform sampler2DShadow shadowtex0; // 全几何深度（含半透明）：基础可见性 PCF
// shadowtex1 不开硬件比较、保持 sampler2D 裸读（仅不透明几何）——彩色阴影遮挡分离与
// 未来 PCSS blocker search 共用的后路（春v2 同布置）
uniform sampler2D shadowtex1;   // 仅不透明深度（裸值）
uniform sampler2D shadowcolor0; // shadow pass 透射色（sRGB albedo，program/shadow.glsl 写入）；RGBA8：水面像素写 焦散×tint（rgb ≤1）+ a 通道水标记（SHADOW_COLOR_WATER_A，读取端 ×WATER_CAUSTICS_BOOST 重建 HDR）

#ifdef VOXY
uniform sampler2D colortex16;
uniform sampler2D colortex17;
// LOD 专属深度与配套逆矩阵；excludeLodsFromVanillaDepth = true。
// 场景位置消费集中经 compat/voxy/scene.glsl，depthtex0/1 只重建原版几何。
uniform sampler2D vxDepthTexOpaque;
uniform sampler2D vxDepthTexTrans;
uniform mat4 vxProjInv;
uniform mat4 vxModelViewInv;
uniform int vxRenderDistance;
#endif

#endif
