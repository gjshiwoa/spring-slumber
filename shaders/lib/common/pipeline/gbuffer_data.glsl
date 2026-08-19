// gbuffer 数据读取端工具（对应春雷 pipeline/gbuffer_data.glsl 的读取换算部分）
// 依赖 lib/common/globals/constants.glsl（LIGHTMAP_MIN / LIGHTMAP_SPAN），由 program 在本文件之前 include
// 当前仅光照图重映射；光照接入后在此扩展 colortex4/5 的解包读取（albedo / 高光 / 法线 / lm）
#ifndef LIB_GBUFFER_DATA_GLSL
#define LIB_GBUFFER_DATA_GLSL

// 原版光照图坐标范围约 [1/32, 31/32]，重映射到 [0,1] 后再使用
vec2 remapLightmap(vec2 lm) {
    return clamp((lm - LIGHTMAP_MIN) / LIGHTMAP_SPAN, 0.0, 1.0);
}

#endif
