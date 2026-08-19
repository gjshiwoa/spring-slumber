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

#endif
