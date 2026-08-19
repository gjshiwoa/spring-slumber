// 全部 uniform 声明集中于此，由 program 文件 include
#ifndef LIB_UNIFORMS_GLSL
#define LIB_UNIFORMS_GLSL

uniform sampler2D tex; // 采样纹理统一命名 tex

uniform sampler2D normals;  // 法线贴图（labPBR 约定，rgb 存切线空间法线，读取端 *2-1 后经 TBN 变换，不翻 Y）
uniform sampler2D specular; // 高光贴图（labPBR 约定，r = smoothness，g = F0，b = porosity/SSS，a = emissive）

uniform sampler2D colortex0; // 场景主颜色缓冲，deferred_init 初始化、composite_tonemap 与 final 读写
uniform sampler2D colortex1; // bloom tile 图集：composite4~8 下采样、composite9~12 上采样回卷（tile0 终态 = 合并后的完整泛光），composite13 消费后不再写入
uniform sampler2D colortex3; // TAA 历史缓冲（clear = false）：rgb = 上帧混合色，a = 上帧最近片元线性深度；仅 composite_taa 读写
uniform sampler2D colortex4; // gbuffer: rg = 打包 albedo（4x8→2x16），ba = 打包高光贴图 RGBA
uniform sampler2D colortex5; // gbuffer: rg = 八面体观察空间法线，ba = 原始 lmcoord；光照接入后读取
uniform sampler2D colortex7; // 杂项数据缓冲（clear = false）：右上角 1 texel = 自适应曝光（composite13 写、composite14 读），其余槽位预留

uniform sampler2D depthtex0; // 深度缓冲；deferred 时刻仅含不透明几何深度（半透明尚未绘制），光照接入后使用；composite 时刻含全部几何（TAA 重投影取 3×3 最近片元）

uniform vec4 entityColor; // 实体着色（受伤红闪等），rgb 为目标色，a 为混合权重；仅 gbuffers_opaque_entities 使用

uniform float viewWidth;  // 视口宽度（像素）；lib/post/bloom.glsl 计算 colortex0 源纹素尺寸、exposure.glsl 定位 colortex7 角点
uniform float viewHeight; // 视口高度（像素）；同上
uniform float frameTime;  // 帧间隔（秒）；自动曝光时间适应
uniform int frameCounter; // 帧序号；TAA jitter 相位（frameCounter & 15）与首帧守卫

// ---- TAA 重投影（lib/common/utils/jitter.glsl + lib/post/taa.glsl）----
uniform vec3 cameraPosition;         // 本帧相机世界坐标
uniform vec3 previousCameraPosition; // 上帧相机世界坐标
uniform mat4 gbufferProjectionInverse;  // 裁剪 -> 视图（当前帧）：TAA 深度重建
uniform mat4 gbufferPreviousModelView;  // 视图 -> 世界（上帧）：TAA 重投影
uniform mat4 gbufferPreviousProjection; // 世界 -> 裁剪（上帧）：TAA 重投影

// 以下为天空 / 光照效果库（lib/atmosphere/sky.glsl、lib/lighting/lighting.glsl）所需，效果暂不接入
uniform mat4 gbufferModelViewInverse; // 视图空间 -> 世界空间

uniform vec3 sunPosition;         // 太阳方向（视图空间，长度为到太阳的距离）
uniform vec3 shadowLightPosition; // 当前主导光源（白天太阳 / 夜晚月亮，视图空间）

uniform float sunAngle;     // 太阳角度 [0,1)，0 = 日出，0.25 = 正午，0.5 = 日落，0.75 = 午夜
uniform float rainStrength; // 雨强度 [0,1]

#endif
