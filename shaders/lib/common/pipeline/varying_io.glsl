// 跨阶段 varying 声明宏（对应春雷 pipeline/varying_io.glsl）
#ifndef LIB_VARYING_IO_GLSL
#define LIB_VARYING_IO_GLSL

// 顶点阶段展开为 out，片段阶段展开为 in，varying 只需声明一次
#ifdef STAGE_VERTEX
#define VARYING out
#else
#define VARYING in
#endif

#endif
