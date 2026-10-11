// 本文件实现源自下列上游作品（经春雷 lib/post/simple_tonemap.glsl 带入），其随代码发布的 MIT
// 声明原样保留于下（依 MIT 条款：版权与许可声明须随副本保留）：
//
// MIT License
//
// Copyright (c) 2024 Missing Deadlines (Benjamin Wrensch)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

// All values used to derive this implementation are sourced from Troy's initial AgX
// implementation/OCIO config file available here:
//   https://github.com/sobotka/AgX

// Tonemap 算子族（lib/post/tonemap.glsl）。AgX 为本包原有实现；Filmic / ACES / Hable 三算子
// 自春雷 lib/post/simple_tonemap.glsl 移植（2026-10，游戏内 TONEMAP 宏切换），上游同源
//（dmnsgn/glsl-tone-map 谱系、ACES 为 Stephen Hill 拟合、Hable = Uncharted 2 filmic）。
// 全算子同一输出契约：display-referred linear [0,1]（AgX 末段 pow 2.2 即「回到线性」），
// 显示前的 gamma 矫正（linearToSrgb）由 final 负责
// 依赖接入方先行 include lib/common/globals/constants.glsl
//（TONEMAP / AGX_ADDITIVE / min_ev / max_ev / ACES_ADDITIVE / FILMIC_ADDITIVE /
//  HABLE_ADDITIVE / HABLE_WHITE_POINT）
#ifndef LIB_TONEMAP_GLSL
#define LIB_TONEMAP_GLSL

const mat3 AgXInsetMatrix = mat3(
    0.842479062253094, 0.0423282422610123, 0.0423756549057051,
    0.0784335999999992, 0.878468636469772, 0.0784336,
    0.0792237451477643, 0.0791661274605434, 0.879142973793104
);

const mat3 AgXOutsetMatrix = mat3(
    1.19687900512017, -0.0528968517574562, -0.0529716355144438,
    -0.0980208811401368, 1.15190312990417, -0.0980434501171241,
    -0.0990297440797205, -0.0989611768448433, 1.15107367264116
);

// AgX 默认对比度曲线的 6 阶多项式近似
vec3 agxDefaultContrastApprox6(vec3 x) {
    vec3 x2 = x * x;
    vec3 x4 = x2 * x2;

    return + 15.5     * x4 * x2
           - 40.14    * x4 * x
           + 31.96    * x4
           - 6.868    * x2 * x
           + 0.4298   * x2
           + 0.1191   * x
           - 0.00232;
}

// 线性 HDR → tonemap 后的线性显示参考值（仍为线性，final 侧再做 linearToSrgb）
vec3 agx(vec3 color) {
    color = max(color, 0.0);
    color += exp2(min_ev); // 抬高黑位，避免 log2(0)
    color *= AGX_ADDITIVE;
    color = AgXInsetMatrix * color;

    color = clamp(log2(color), min_ev, max_ev);
    color = (color - min_ev) / (max_ev - min_ev);

    color = agxDefaultContrastApprox6(color);

    color = AgXOutsetMatrix * color;
    color = max(color, 0.0);
    color = pow(color, vec3(2.2)); // 回到线性（display-referred linear）

    return color;
}

// ---- 以下三算子自春雷 lib/post/simple_tonemap.glsl 移植（逐式同款，仅改名 Hable = 其 Uncharted2）----

// ACES：Stephen Hill 的 RRT+ODT 多项式拟合（输入线性 HDR，输出 display-referred linear）
// https://github.com/TheRealMJP/BakingLab/blob/master/BakingLab/ACES.hlsl
const mat3 LINEAR_TO_ACES = mat3(
    0.59719, 0.07600, 0.02840,
    0.35458, 0.90834, 0.13383,
    0.04823, 0.01566, 0.83777
);

const mat3 ACES_TO_LINEAR = mat3(
    1.60475, -0.10208, -0.00327,
    -0.53108, 1.10813, -0.07276,
    -0.07367, -0.00605, 1.07602
);

vec3 RrtAndOdtFit(vec3 col) {
    vec3 a = col * (col + 0.0245786) - 0.000090537;
    vec3 b = col * (0.983729 * col + 0.4329510) + 0.238081;
    return a / b;
}

vec3 ACES(vec3 col) {
    col *= ACES_ADDITIVE;
    vec3 aces = LINEAR_TO_ACES * col;
    aces = RrtAndOdtFit(aces);
    return ACES_TO_LINEAR * aces;
}

// Hable（Uncharted 2 filmic，John Hable）：hableCurve 为曲线本体（未归一白位）
vec3 hableCurve(vec3 x) {
    float A = 0.15;
    float B = 0.50;
    float C = 0.10;
    float D = 0.20;
    float E = 0.02;
    float F = 0.30;
    return ((x * (A * x + C * B) + D * E) / (x * (A * x + B) + D * F)) - E / F;
}

// Hable 入口：白位点（HABLE_WHITE_POINT）归一到 1，春雷 Uncharted2 同式
vec3 Hable(vec3 x) {
    vec3 curr = hableCurve(x * HABLE_ADDITIVE);
    vec3 whiteScale = 1.0 / hableCurve(vec3(HABLE_WHITE_POINT));
    return curr * whiteScale;
}

// Filmic：有理式 filmic 曲线（负分量入口内钳 0，春雷同式）
vec3 Filmic(vec3 x) {
    x *= FILMIC_ADDITIVE;
    vec3 X = max(vec3(0.0), x);
    return (X * (6.2 * X + 0.5)) / (X * (6.2 * X + 1.7) + 0.06);
}

// 统一出口（TONEMAP 宏 = constants.glsl 游戏内选项，引擎回写宏行切换档位）：
// 0 = agx（默认，逐位回退接入史实）1 = Filmic 2 = ACES 3 = Hable。
// 入口统一钳非负（调用方色彩滤镜的饱和度 >1 / 对比度 >1 会把低通道压负，四算子均要求非负
// 输入；春雷 TONEMAP_TYPE(max(hdrColor, 0.0)) 同款守卫）；出口同样钳非负——ACES 拟合在
// 极小正值处有轻微负过冲（a = x(x+0.0246)−0.0000905 于 x ≲ 0.0036 为负），而 final 的
// linearToSrgb pow 对负值未定义；agx 分支首尾各有一体 max、无重复求值
vec3 applyTonemap(vec3 color) {
    color = max(color, 0.0);
#if TONEMAP == 1
    return max(Filmic(color), 0.0);
#elif TONEMAP == 2
    return max(ACES(color), 0.0);
#elif TONEMAP == 3
    return max(Hable(color), 0.0);
#else
    return agx(color);
#endif
}

#endif
