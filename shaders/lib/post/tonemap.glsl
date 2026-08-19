// AgX tonemap（参考春雷 lib/post/simple_tonemap.glsl，同款 minimal AgX 实现：
// https://iolite-engine.com/blog_posts/minimal_agx_implementation）
// 末段 pow 2.2 是「回到线性」（display-referred linear），输出仍为线性；
// 显示前的 gamma 矫正（linearToSrgb）由 final 负责
// 依赖接入方先行 include lib/common/globals/constants.glsl（AGX_ADDITIVE / min_ev / max_ev）
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

#endif
