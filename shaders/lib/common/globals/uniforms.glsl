// 全部 uniform 声明集中于此，由 program 文件 include
#ifndef LIB_UNIFORMS_GLSL
#define LIB_UNIFORMS_GLSL

uniform sampler2D tex; // 采样纹理统一命名 tex

uniform sampler2D normals;  // 法线贴图（labPBR 约定，rgb 存切线空间法线，读取端 *2-1 后经 TBN 变换，不翻 Y）
uniform sampler2D specular; // 高光贴图（labPBR 约定，r = smoothness，g = F0，b = porosity/SSS，a = emissive）

uniform sampler2D colortex1; // bloom tile 图集（composite4~8 下采样、composite9~12 上采样回卷，tile0 终态 = 合并后的完整泛光，final 消费 tile0、composite12 测光读 tile4）+ 云形状场槽位（图集右侧 r 通道，布局见 bloom.glsl 的 cloudFieldRect——deferred 槽生成、deferred_init 伪自阴影探针读，见 clouds.glsl）。gbuffers 阶段不可采样（同上）
uniform sampler2D colortex3; // TAA 历史缓冲（clear = false）：rgb = 上帧混合色，a = 上帧最近片元线性深度；仅 composite_taa 读写。gbuffers 阶段不可采样（同上）
uniform sampler2D colortex4; // gbuffer: rg = 打包 albedo（4x8→2x16），ba = 打包高光贴图 RGBA；deferred_init 解包消费，此后帧内无读者、内容留存至帧末。**gbuffers 阶段读须用别名 gaux1**
uniform sampler2D colortex5; // gbuffer: rg = 八面体观察空间法线，ba = 原始 lmcoord；光照接入后读取。**gbuffers 阶段读须用别名 gaux2**
uniform sampler2D colortex6; // 场景主颜色缓冲（RGBA16F），deferred_init 初始化、前向半透明 after 路径合成（textured 族手动 fetch——**gbuffers 阶段读须用别名 gaux3**；water / hand_water / weather 走引擎硬件混合直写、无 fetch）、composite_taa 抗锯齿，final 读取后直接输出屏幕（不再写回）。放 colortex6 而非惯例的 colortex0：前向半透明须在 gbuffers 阶段采样主颜色作合成背景，而 colortex0~3 的采样单元在该阶段被游戏纹理 / 深度绑定占用（colortex0 即几何纹理 tex，实测采样返回纹理图集内容——water 曾因此把图集画上屏幕），colortex0 全程未使用

// gaux1~4 = colortex4~7 的采样别名（gbuffers 阶段读缓冲的规范名——deferred / composite / final 阶段
// 两者同单元等价、均可用；gbuffers 程序一律用 gaux 名，见各 colortex 注释）
uniform sampler2D gaux1; // = colortex4：gbuffer albedo / 高光（before-deferred 手动合成类 color / beacon 外壳的背景读取）
uniform sampler2D gaux2; // = colortex5
uniform sampler2D gaux3; // = colortex6：场景主颜色（textured 族 after 路径手动合成的背景——读正在写的缓冲与手动合成类同款已知取舍；water 族走引擎混合、不 fetch）
uniform sampler2D gaux4; // = colortex7：杂项簇（pass 顺序标记、天空 LUT 探针——ambient.glsl / pass_order_marker.glsl 经本名采样，gbuffers vsh 消费）

uniform sampler2D colortex7; // 杂项数据缓冲（clear = false，左下角杂项簇）：曝光槽位 1 texel（exposure.glsl 的 exposureTexel）= 自适应曝光（composite12 写、composite_taa 与 final 读）、天空 view LUT 200×200（太阳半区 + 月亮半区，deferred_init 读）、预留天空盒 256×256

uniform sampler2D depthtex0; // 深度缓冲（全部几何）；deferred 时刻除不透明外可能已含 deferred 前绘制的 textured 族（粒子 / 闪电）深度，天空判定须用 depthtex1；composite 时刻含半透明与手，TAA 重投影取十字最近片元
uniform sampler2D depthtex1; // 深度缓冲（仅不透明几何，含手部；粒子等非不透明写入被排除）：deferred_init 天空判定 / 光照位置重建用

uniform vec4 entityColor; // 实体着色（受伤红闪等），rgb 为目标色，a 为混合权重；仅 gbuffers_opaque_entities 使用

uniform float viewWidth;  // 视口宽度（像素）；lib/post/bloom.glsl 计算 colortex6 源纹素尺寸
uniform float viewHeight; // 视口高度（像素）；同上
uniform float far;        // 相机远平面（≈ 渲染半径 × √2 + 余量）：屏幕空间追踪阴影的渲染边界淡出锚点（shadow.glsl；GLSL 330 非保留字，各参考包通用名）
uniform float frameTime;  // 帧间隔（秒）；自动曝光时间适应
uniform float frameTimeCounter; // 游戏时间累计（秒，世界加载起算）；云层风场动画时基（lib/atmosphere/clouds.glsl）
uniform int frameCounter; // 帧序号；TAA jitter 相位（frameCounter & 31）与首帧守卫

// ---- TAA 重投影（lib/common/utils/noise.glsl + lib/post/taa.glsl + utils/space.glsl 上一帧换算）----
uniform vec3 cameraPosition;         // 本帧相机世界坐标
uniform vec3 previousCameraPosition; // 上帧相机世界坐标
uniform mat4 gbufferProjection;         // 视图 -> 裁剪（当前帧，正向投影）：屏幕空间追踪阴影的每步射线投影（shadow.glsl）
uniform mat4 gbufferProjectionInverse;  // 裁剪 -> 视图（当前帧）：TAA 深度重建；屏幕空间追踪阴影的场景点重建共用
uniform mat4 gbufferPreviousModelView;  // 视图 -> 世界（上帧）：TAA 重投影
uniform mat4 gbufferPreviousProjection; // 世界 -> 裁剪（上帧）：TAA 重投影

// 以下为天空 / 光照效果库所需：天空（lib/atmosphere/）与光照（lib/lighting/）均已接入 deferred_init
uniform mat4 gbufferModelViewInverse; // 视图空间 -> 世界空间（viewToWorldDirection / viewToRelativeWorld 共用）

uniform vec3 sunPosition;         // 太阳方向（视图空间，长度为到太阳的距离）
uniform vec3 moonPosition;        // 月亮方向（视图空间，同上；与太阳恰好相对——白天沉于地平线下、月亮半区自然归零）；天空 LUT 月亮半区光源
uniform vec3 shadowLightPosition; // 当前主导光源（白天太阳 / 夜晚月亮，视图空间）

uniform float sunAngle;     // 太阳角度 [0,1)，0 = 日出，0.25 = 正午，0.5 = 日落，0.75 = 午夜
uniform float rainStrength; // 雨强度 [0,1]
uniform int isEyeInWater;   // 0 = 大气中 / 1 = 水中 / 2 = 熔岩中（水下效果扩展点）

// ---- 阴影贴图（program/shadow.glsl 写入 + lib/lighting/shadow.glsl 采样）----
uniform mat4 shadowModelView; // 相对世界（当帧相机为原点、与 gbufferModelView 同源空间）-> shadow 视图
uniform mat4 shadowProjection; // shadow 视图 -> shadow 裁剪（正交）
// shadowtex0 开硬件比较（constants.glsl 的 shadowHardwareFiltering0）、声明为 sampler2DShadow：
// 比较采样即深度比较 + 2×2 双线性插值，一次采样顶手动 4 次比较（GLSL 330 的 textureLod
// 重载同样走硬件比较滤波，采样端显式 LOD 0 免隐式导数）
uniform sampler2DShadow shadowtex0; // 全几何深度（含半透明）：基础可见性 PCF
// shadowtex1 不开硬件比较、保持 sampler2D 裸读（仅不透明几何）——彩色阴影遮挡分离与
// 未来 PCSS blocker search 共用的后路（春v2 同布置）
uniform sampler2D shadowtex1;   // 仅不透明深度（裸值）
uniform sampler2D shadowcolor0; // shadow pass 透射色（sRGB albedo，program/shadow.glsl 写入）

#endif
