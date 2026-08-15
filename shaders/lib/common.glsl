// 跨阶段通用宏
#ifndef LIB_COMMON_GLSL
#define LIB_COMMON_GLSL

// 顶点阶段展开为 out，片段阶段展开为 in，varying 只需声明一次
#ifdef STAGE_VERTEX
#define VARYING out
#else
#define VARYING in
#endif

#endif
