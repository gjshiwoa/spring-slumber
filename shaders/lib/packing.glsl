// 位打包工具（int 位运算，值域 [0,1]）
// 输出粒度 1/65535，必须存入 16bit 无符号规范化格式（RGBA16），不可用浮点格式
// 标识符避开 GLSL 保留字（packed / filter / sample 等）
#ifndef LIB_PACKING_GLSL
#define LIB_PACKING_GLSL

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

#endif
