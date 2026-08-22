// 颜色空间转换工具（对应春雷 utils/color.glsl），由 program 按需平铺引入，无外部依赖
#ifndef LIB_COLOR_GLSL
#define LIB_COLOR_GLSL

// sRGB → 线性（gamma 2.2 近似，春雷 SRGBToLinear 同款）；反 gamma
vec3 srgbToLinear(vec3 color) {
    return pow(color, vec3(2.2));
}

// 线性 → sRGB（gamma 1/2.2 近似，春雷 LinearToSRGB 同款）；final 输出前的 gamma 矫正
vec3 linearToSrgb(vec3 color) {
    return pow(color, vec3(1.0 / 2.2));
}

// Rec.709 相对亮度（春雷 RGBToLuma 同款）
float rgbToLuma(vec3 linearRgb) {
    return dot(linearRgb, vec3(0.2126, 0.7152, 0.0722));
}

// RGB → YCoCg 去相关变换（Y = 亮度行 0.25/0.5/0.25，Co = R−B 色差，Cg = G−(R+B) 色度），
// 与 yCoCgToRgb 精确互逆；亮度域统计 / 逐通道去相关钳制用（TAA 方差钳制已用，
// 未来 denoise / SSR 方差估计等同用）；Y 分量单独取时未用的 Co/Cg 由编译器消除
vec3 rgbToYCoCg(vec3 color) {
    return vec3(
        color.x * 0.25 + color.y * 0.5  + color.z * 0.25,
        color.x * 0.5  - color.z * 0.5,
       -color.x * 0.25 + color.y * 0.5  - color.z * 0.25
    );
}

vec3 yCoCgToRgb(vec3 color) {
    float yLessCg = color.x - color.z;
    return vec3(yLessCg + color.y, color.x + color.z, yLessCg - color.y);
}

#endif
