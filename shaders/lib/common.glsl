// 跨阶段通用宏与工具函数
// 依赖 lib/constants.glsl（TAU、LIGHTMAP_MIN / LIGHTMAP_SPAN），由 program 在本文件之前 include
#ifndef LIB_COMMON_GLSL
#define LIB_COMMON_GLSL

// 顶点阶段展开为 out，片段阶段展开为 in，varying 只需声明一次
#ifdef STAGE_VERTEX
#define VARYING out
#else
#define VARYING in
#endif

// 原版光照图坐标范围约 [1/32, 31/32]，重映射到 [0,1] 后再使用
vec2 remapLightmap(vec2 lm) {
    return clamp((lm - LIGHTMAP_MIN) / LIGHTMAP_SPAN, 0.0, 1.0);
}

#endif
