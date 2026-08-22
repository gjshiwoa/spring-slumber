// 坐标空间构造工具（对应春雷 utils/space.glsl 的 TBN 部分）
// TBN 部分仅片段阶段可用（dFdx / dFdy）；坐标换算函数任意阶段可用
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：lib/common/globals/uniforms.glsl
//（gbufferProjectionInverse / gbufferModelViewInverse / previous 系矩阵与 cameraPosition 系——坐标换算函数所需）
#ifndef LIB_SPACE_GLSL
#define LIB_SPACE_GLSL

// ---------------- 坐标换算（任意阶段） ----------------

// 屏幕空间 [0,1] -> 观察空间位置：xy = uv、z = 深度缓冲原始值，*2-1 转 NDC 与透视除法都在
// 函数内完成——调用端不再手工转换（曾因只转 xy 漏转 depth 致重建位置沿视线偏移、阴影错位）；
// z 取 1 时结果落在远平面上（天空视线重建）
// 通用管线换算：TAA 深度重建（taa.glsl）、deferred_init 天空视线 / 几何 viewPos 共用
vec3 screenToView(vec3 screenPos) {
    vec4 viewPos = gbufferProjectionInverse * vec4(screenPos * 2.0 - 1.0, 1.0);
    return viewPos.xyz / viewPos.w;
}

// 观察空间方向 -> 世界空间方向（纯旋转、不要求归一化，长度保持）
// 天空色（sky.glsl）与光照方向换算（lighting.glsl）共用
vec3 viewToWorldDirection(vec3 dirView) {
    return mat3(gbufferModelViewInverse) * dirView;
}

// 观察空间位置 -> 相对世界空间（当帧相机为原点、世界轴向；绝对世界坐标 = 结果 + cameraPosition，
// 保持相机相对可避开大世界坐标的 float 精度损失）：重投影链第一段（taa.glsl），SSR / SSAO 等共用
vec3 viewToRelativeWorld(vec3 viewPos) {
    return (gbufferModelViewInverse * vec4(viewPos, 1.0)).xyz;
}

// 相对世界空间 -> 上一帧屏幕 uv（重投影链第二段）：cameraDelta 为当帧 -> 上帧相机位移，
// 一般传 cameraPosition - previousCameraPosition，手部等随相机运动几何传 vec3(0.0) 清零平移；
// 返回无抖动坐标，与 jitter 的衔接由调用方处理
vec2 relativeWorldToPreviousScreen(vec3 relativeWorldPos, vec3 cameraDelta) {
    vec4 prevClip = gbufferPreviousProjection * gbufferPreviousModelView
                  * vec4(relativeWorldPos + cameraDelta, 1.0);
    return prevClip.xy / prevClip.w * 0.5 + 0.5;
}

// 观察空间方向 -> 上一帧屏幕 uv：无穷远几何（天空）重投影——w = 0 平移自动失效、
// 仅相机旋转生效（天空挂在视线方向上、与相机平移无关）；输入不要求归一化（uv 对长度不变）
vec2 viewDirectionToPreviousScreen(vec3 dirView) {
    vec4 prevClip = gbufferPreviousProjection * gbufferPreviousModelView
                  * vec4(viewToWorldDirection(dirView), 0.0);
    return prevClip.xy / prevClip.w * 0.5 + 0.5;
}

#ifdef STAGE_FRAGMENT

// ---------------- cotangent frame（仅片段阶段） ----------------

// 由预求好的位置屏幕导数 cross / normalize 出几何法线（观察空间，逐像素面法线）：
// 导数已由调用方在 discard 前集中求好，本函数与 calculateTBN 因此可推迟到 discard 之后
vec3 geomNormalFromDerivatives(vec3 dp1, vec3 dp2) {
    return normalize(cross(dp1, dp2));
}

// 屏幕空间导数求几何法线（观察空间，逐像素面法线）
vec3 calculateGeomNormal(vec3 viewPos) {
    return geomNormalFromDerivatives(dFdx(viewPos), dFdy(viewPos));
}

// cotangent frame：由观察空间位置与 UV 的屏幕导数构造 TBN（春雷 / 春v2 同款）
// 导数由调用方先于 discard 集中求好传入（discard 后 quad 内幸存像素的导数未定义），
// TBN 构造与后续法线采样得以推迟到 discard 之后；任意贴图向量经 mat3(T, B, N) 左乘后
// 即观察空间向量；无 UV 变化的平面自动退化
mat3 calculateTBN(vec3 dp1, vec3 dp2, vec2 duv1, vec2 duv2) {
    vec3 n = geomNormalFromDerivatives(dp1, dp2);

    vec3 dp2perp = cross(dp2, n);
    vec3 dp1perp = cross(n, dp1);

    vec3 t = dp2perp * duv1.x + dp1perp * duv2.x;
    vec3 b = dp2perp * duv1.y + dp1perp * duv2.y;

    float invmax = inversesqrt(max(dot(t, t), dot(b, b)));
    return mat3(t * invmax, b * invmax, n);
}

#endif

#endif
