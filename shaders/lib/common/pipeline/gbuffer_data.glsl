// gbuffer 数据读取端工具（对应春雷 pipeline/gbuffer_data.glsl 的读取换算部分）
// 依赖 lib/common/globals/constants.glsl（LIGHTMAP_MIN / LIGHTMAP_SPAN / MATERIAL_*），由 program 在本文件之前 include
// 光照图重映射与物品标记读取（colortex4/5 的解包按需扩展）
#ifndef LIB_GBUFFER_DATA_GLSL
#define LIB_GBUFFER_DATA_GLSL

// 原版光照图坐标范围约 [1/32, 31/32]，重映射到 [0,1] 后再使用
vec2 remapLightmap(vec2 lm) {
    return clamp((lm - LIGHTMAP_MIN) / LIGHTMAP_SPAN, 0.0, 1.0);
}

// 物品标记 → 次表面散射强度（shadeSurface / sampleShadowVisibility 的 sssStrength 入参，[0,1] 归一化）
// 入参为 colortex4 解包 albedo 的 a 通道（标记 8bit 经 pack/unpack 往返，半 8bit 容差比较防边缘抖动）；
// 植被硬编码取 VEGETATION_SSS_STRENGTH（唯一调效旋钮在此定档；标记来源 = block.properties 春v2 同款
// 五族显式列表——列表外几何一律无 SSS），未标记一律 0（下式 else 分支自然覆盖），253~255 预留时在此
// 按材质定 0~1（春v2：SSS_INTENSITY × specularMap.b 同位职责）
float materialSSSStrength(float marker) {
    return abs(marker - MATERIAL_VEGETATION) < 0.5 / 255.0 ? VEGETATION_SSS_STRENGTH : 0.0;
}

#endif
