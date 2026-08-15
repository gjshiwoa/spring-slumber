// 全部 uniform 声明集中于此，由 program 文件 include
#ifndef LIB_UNIFORMS_GLSL
#define LIB_UNIFORMS_GLSL

uniform sampler2D tex; // 采样纹理统一命名 tex

uniform sampler2D colortex0; // 场景主颜色缓冲，gbuffers 写入、final 采样
uniform sampler2D colortex4; // 中间缓冲: RGBA16
uniform sampler2D colortex5; // 中间缓冲: RGBA16F

uniform vec4 entityColor; // 实体着色（受伤红闪等），rgb 为目标色，a 为混合权重；仅 gbuffers_entities 使用

#endif
