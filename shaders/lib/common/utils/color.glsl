// 颜色空间转换工具（对应春雷 utils/color.glsl），由 program 按需平铺引入，无外部依赖
#ifndef LIB_COLOR_GLSL
#define LIB_COLOR_GLSL

// sRGB → 线性（gamma 2.2 的六阶多项式拟合，端点约束）：替代 pow 的 6 次超越运算（低配 GPU 超越
// 函数多为 1/4 速率；本函数是光照路径最热 ALU 段——每几何像素 albedo 转换 + 彩色阴影透射色）。
// x²·(多项式) 形式结构性匹配 2.2 次幂近零平切线（带一次项的三次式会在 sRGB < ~0.03 翻负、黑位
// 挤压）；sRGB ≥ 0.05 相对误差 ≤ 2.4%、中段 ≤ 0.2%，观感与 pow 2.2 一致；写读两侧共用、误差对称
vec3 srgbToLinear(vec3 color) {
    return color * color * (0.489745929
                           + color * (1.603340030
                                     + color * (-2.710998662
                                               + color * (2.503631982 - 0.885719277 * color))));
}

// 线性 → sRGB（gamma 1/2.2）；final 输出前的 gamma 矫正。保持 pow：全管线仅 final 每像素一次
//（非热点，sqrt 链近似不是净收益）
vec3 linearToSrgb(vec3 color) {
    return pow(color, vec3(1.0 / 2.2));
}

// Rec.709 相对亮度（春雷 RGBToLuma 同款）
float rgbToLuma(vec3 linearRgb) {
    return dot(linearRgb, vec3(0.2126, 0.7152, 0.0722));
}

// RGB → YCoCg 去相关变换，与 yCoCgToRgb 精确互逆；亮度域统计 / 逐通道去相关钳制用
//（TAA 方差钳制已用，denoise / SSR 方差估计等同用）
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
