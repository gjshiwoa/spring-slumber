// 噪声 / 抖动工具（通用，与具体效果解耦）
// 当前仅 IGN 时域噪声（无纹理、纯 ALU）；未来 bayer 抖动、hash 随机等在此扩展
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：lib/common/globals/uniforms.glsl（frameCounter）
#ifndef LIB_NOISE_GLSL
#define LIB_NOISE_GLSL

// IGN 时域抖动噪声（interleaved gradient noise + 帧序 golden ratio 偏移，Photon 同款，3 条 ALU 无纹理）：
// 逐像素 [0,1) 噪声、帧间按黄金比旋转相位——用于单帧去相关采样图案（如旋转 / 抖动 PCF 采样盘），
// composite_taa 时间累积把噪声解析成收敛结果（阴影 PCF 即此用法，见 lib/lighting/shadow.glsl）
float interleavedGradientNoise(vec2 pixelPos) {
    return fract(52.9829189 * fract(dot(pixelPos, vec2(0.06711056, 0.00583715))
                                    + float(frameCounter % 64) * 0.61803399));
}

#endif
