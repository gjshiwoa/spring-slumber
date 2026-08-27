// 颜色空间转换工具（对应春雷 utils/color.glsl），由 program 按需平铺引入，无外部依赖
#ifndef LIB_COLOR_GLSL
#define LIB_COLOR_GLSL

// sRGB → 线性（gamma 2.2 的六阶多项式拟合，端点约束 p(0)=0 / p(1)=1）：替代 pow(color, 2.2)
// 的 6 次超越运算（log2+mul+exp2 × 3 通道，低配 GPU 超越函数多为 1/4 速率）为全速率乘加——
// 本函数是光照路径最热的纯 ALU 段（deferred_init 每几何像素的 albedo 转换 + 彩色阴影每个
// 被遮 tap 的透射色转换、单像素最多 4 次）；x²·(多项式) 形式结构性匹配 2.2 次幂在近零处的
// 平切线（带一次项的三次式会在 sRGB < ~0.03 区间翻负、黑位挤压）。系数为 [0,1] 上 x^2.2
// 的相对误差加权最小二乘（Lawson 迭代逼近极小极大）；数值验证：全程单调递增、无负值，
// 最大绝对误差 1.5e-3，sRGB ≥ 0.05（13/255，深色纹理区）相对误差 ≤ 2.4%、中段 ≤ 0.2%——
// 保持 2.2 观感不变；写读两侧共用本实现，拟合误差对称、不引入偏色
vec3 srgbToLinear(vec3 color) {
    return color * color * (0.489745929
                           + color * (1.603340030
                                     + color * (-2.710998662
                                               + color * (2.503631982 - 0.885719277 * color))));
}

// 线性 → sRGB（gamma 1/2.2 近似）；final 输出前的 gamma 矫正。保持 pow：全管线仅 final
// 每像素调用一次（非热点），且常见 sqrt 链近似每通道需 3 次开方（超越）、反多于 pow 的
// log2+exp2 两次，不是净收益
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
