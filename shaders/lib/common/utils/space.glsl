// 坐标空间构造工具（对应春雷 utils/space.glsl 的 TBN 部分）
// 仅片段阶段可用（dFdx / dFdy），由 program 按需平铺引入，无外部依赖
#ifndef LIB_SPACE_GLSL
#define LIB_SPACE_GLSL

#ifdef STAGE_FRAGMENT

// 屏幕空间导数求几何法线（观察空间，逐像素面法线）
vec3 calculateGeomNormal(vec3 viewPos) {
    return normalize(cross(dFdx(viewPos), dFdy(viewPos)));
}

// cotangent frame：由观察空间位置与 UV 的屏幕导数构造 TBN（春雷 / 春v2 同款）
// 任意贴图向量经 mat3(T, B, N) 左乘后即观察空间向量；无 UV 变化的平面自动退化
mat3 calculateTBN(vec3 viewPos, vec2 duv1, vec2 duv2) {
    vec3 n = calculateGeomNormal(viewPos);

    vec3 dp1 = dFdx(viewPos);
    vec3 dp2 = dFdy(viewPos);
    vec3 dp2perp = cross(dp2, n);
    vec3 dp1perp = cross(n, dp1);

    vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;

    float invmax = inversesqrt(max(dot(t, t), dot(b, b)));
    return mat3(t * invmax, b * invmax, n);
}

#endif

#endif
