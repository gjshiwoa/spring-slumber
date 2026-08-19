// 数据打包 / 编码工具（对应春雷 utils/packing.glsl：位打包与八面体编码同文件）
// 位打包输出粒度 1/65535，必须存入 16bit 无符号规范化格式（RGBA16），不可用浮点格式
// 八面体映射为单位向量 ↔ 二维 [0,1] 的通用编码，不限法线用途（天空方向、环境采样方向等皆可）
// 标识符避开 GLSL 保留字（packed / filter / sample 等）
#ifndef LIB_PACKING_GLSL
#define LIB_PACKING_GLSL

// ============================== 位打包（int 位运算，值域 [0,1]） ==============================

// 两个 8bit 值打包进一个 16bit 通道
float pack2x8To16(float a, float b) {
    int ai = int(clamp(a, 0.0, 1.0) * 255.0);
    int bi = int(clamp(b, 0.0, 1.0) * 255.0);
    return float((ai << 8) | bi) / 65535.0;
}

vec2 unpack16To2x8(float data) {
    int p = int(data * 65535.0);
    return vec2(float((p >> 8) & 255), float(p & 255)) / 255.0;
}

// 四个 8bit 值打包进两个 16bit 通道
vec2 pack4x8To2x16(vec4 abcd) {
    ivec4 quantized = ivec4(clamp(abcd, 0.0, 1.0) * 255.0);
    int combined1 = (quantized.x << 8) | quantized.y;
    int combined2 = (quantized.z << 8) | quantized.w;
    return vec2(float(combined1), float(combined2)) / 65535.0;
}

vec4 unpack2x16To4x8(vec2 data) {
    ivec2 combined = ivec2(data * 65535.0);
    ivec4 unpacked;
    unpacked.x = (combined.x >> 8) & 0xFF;
    unpacked.y = combined.x & 0xFF;
    unpacked.z = (combined.y >> 8) & 0xFF;
    unpacked.w = combined.y & 0xFF;
    return vec4(unpacked) / 255.0;
}

// ============================== 八面体编码（单位向量 ↔ 二维 [0,1]） ==============================

// 将向量折叠回八面体菱形区域
vec2 octWrap(vec2 v) {
    vec2 w = 1.0 - abs(v.yx);
    if (v.x < 0.0) w.x = -w.x;
    if (v.y < 0.0) w.y = -w.y;
    return w;
}

// 三维单位向量 -> 二维八面体坐标
vec2 encodeOctahedral(vec3 direction) {
    float length_ = length(direction);
    if (length_ < 1e-8) {
        // 零向量没有方向，退化为 +Z 的八面体坐标
        return vec2(0.5);
    }

    direction /= length_;

    vec2 p = direction.xy / (abs(direction.x) + abs(direction.y) + abs(direction.z));
    if (direction.z < 0.0) {
        p = octWrap(p);
    }

    return p * 0.5 + 0.5;
}

// 二维八面体坐标 -> 三维单位向量
vec3 decodeOctahedral(vec2 oct) {
    oct = clamp(oct, 0.0, 1.0);

    vec2 p = oct * 2.0 - 1.0;
    vec3 v = vec3(p, 1.0 - abs(p.x) - abs(p.y));
    if (v.z < 0.0) {
        v.xy = octWrap(v.xy);
    }

    return normalize(v);
}

#endif
