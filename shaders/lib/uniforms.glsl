// 全部 uniform 声明集中于此，由 program 文件 include
#ifndef LIB_UNIFORMS_GLSL
#define LIB_UNIFORMS_GLSL

uniform sampler2D tex; // 采样纹理统一命名 tex

uniform sampler2D normals;  // 法线贴图（labPBR 约定，rgb 存切线空间法线，读取端 *2-1 后经 TBN 变换，不翻 Y）
uniform sampler2D specular; // 高光贴图（labPBR 约定，r = smoothness，g = F0，b = porosity/SSS，a = emissive）

uniform sampler2D colortex0; // 场景主颜色缓冲，deferred 写入、final 采样
uniform sampler2D colortex4; // gbuffer: rg = 打包 albedo（4x8→2x16），ba = 打包高光贴图 RGBA
uniform sampler2D colortex5; // gbuffer: rg = 八面体观察空间法线，ba = 原始 lmcoord；光照接入后读取

uniform sampler2D depthtex0; // 深度缓冲；deferred 时刻仅含不透明几何深度（半透明尚未绘制），光照接入后使用

uniform vec4 entityColor; // 实体着色（受伤红闪等），rgb 为目标色，a 为混合权重；仅 gbuffers_entities 使用

// 以下为天空 / 光照效果库（lib/sky.glsl、lib/lighting.glsl）所需，效果暂不接入
uniform mat4 gbufferModelViewInverse; // 视图空间 -> 世界空间

uniform vec3 sunPosition;         // 太阳方向（视图空间，长度为到太阳的距离）
uniform vec3 shadowLightPosition; // 当前主导光源（白天太阳 / 夜晚月亮，视图空间）

uniform float sunAngle;     // 太阳角度 [0,1)，0 = 日出，0.25 = 正午，0.5 = 日落，0.75 = 午夜
uniform float rainStrength; // 雨强度 [0,1]

#endif
