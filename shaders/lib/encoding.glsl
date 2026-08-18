// 几何信息编解码工具
#ifndef LIB_ENCODING_GLSL
#define LIB_ENCODING_GLSL

// 八面体法线编码（Octahedral Normal Encoding）
// 输出 [0, 1] 范围，适合写入 RG8 / RG16 / RG16F 等双通道缓冲
// 法线空间不限（视图空间 / 世界空间均可），只需传入方向

// 将向量折叠回八面体菱形区域
vec2 octWrap(vec2 v) {
    vec2 w = 1.0 - abs(v.yx);
    if (v.x < 0.0) w.x = -w.x;
    if (v.y < 0.0) w.y = -w.y;
    return w;
}

// 三维法线 -> 二维八面体坐标
vec2 encodeOctahedral(vec3 normal) {
    float normalLength = length(normal);
    if (normalLength < 1e-8) {
        // 零向量没有方向，退化为 +Z 的八面体坐标
        return vec2(0.5);
    }

    normal /= normalLength;

    vec2 p = normal.xy / (abs(normal.x) + abs(normal.y) + abs(normal.z));
    if (normal.z < 0.0) {
        p = octWrap(p);
    }

    return p * 0.5 + 0.5;
}

// 二维八面体坐标 -> 三维单位法线
vec3 decodeOctahedral(vec2 oct) {
    oct = clamp(oct, 0.0, 1.0);

    vec2 p = oct * 2.0 - 1.0;
    vec3 n = vec3(p, 1.0 - abs(p.x) - abs(p.y));
    if (n.z < 0.0) {
        n.xy = octWrap(n.xy);
    }

    return normalize(n);
}

#endif
