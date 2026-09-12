// 坐标空间构造工具（对应春雷 utils/space.glsl 的 TBN 部分）
// TBN 部分仅片段阶段可用（dFdx / dFdy）；坐标换算任意阶段可用
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：uniforms.glsl（投影 / 视图矩阵，
//   含 previous 系与 cameraPosition 系；阴影换算另需 shadowProjection / shadowModelView）、
//   constants.glsl（阴影扭曲 / 压缩常量——仅阴影换算部分需要）
#ifndef LIB_SPACE_GLSL
#define LIB_SPACE_GLSL

// ---------------- 坐标换算（任意阶段） ----------------

// 线性重映射 + 饱和钳制：x ∈ [e0, e1] → [v0, v1]，域外按端值饱和。屏幕空间追踪阴影的距离
// remap 族（追踪长度 / 起点偏移 / 厚度曲线 / 贴图淡出窗，shadow.glsl）与 SSS 渐入（lighting.glsl）
float remapSaturate(float x, float e0, float e1, float v0, float v1) {
    float t = clamp((x - e0) / (e1 - e0), 0.0, 1.0);
    return v0 + t * (v1 - v0);
}

// 屏幕空间 [0,1] -> 观察空间位置：xy = uv、z = 深度缓冲原始值，*2-1 转 NDC 与透视除法都在
// 函数内完成（杜绝只转 xy 漏转 depth 的重建错位）；z 取 1 时落在远平面（天空视线）。
// TAA 深度重建与 deferred_init 天空视线 / 几何 viewPos 共用
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
// 一般传 cameraPosition - previousCameraPosition，手部等随相机几何传 vec3(0.0) 清零平移；
// 返回无抖动坐标，与 jitter 的衔接由调用方处理
vec2 relativeWorldToPreviousScreen(vec3 relativeWorldPos, vec3 cameraDelta) {
    vec4 prevClip = gbufferPreviousProjection * gbufferPreviousModelView
                  * vec4(relativeWorldPos + cameraDelta, 1.0);
    return prevClip.xy / prevClip.w * 0.5 + 0.5;
}

// 观察空间方向 -> 上一帧屏幕 uv：无穷远几何（天空）重投影——w = 0 平移自动失效、仅相机旋转
// 生效；输入不要求归一化
vec2 viewDirectionToPreviousScreen(vec3 dirView) {
    vec4 prevClip = gbufferPreviousProjection * gbufferPreviousModelView
                  * vec4(viewToWorldDirection(dirView), 0.0);
    return prevClip.xy / prevClip.w * 0.5 + 0.5;
}

// ---------------- 阴影屏幕换算（写读两侧同一实现，任意阶段可用） ----------------

// 线性扭曲因子：中心（d = 0）为 1 - SHADOW_DISTORT_FACTOR = 0.15，纹素密度放大约 6.7 倍；边缘（d = 1）为 1 不缩放
float shadowDistortFactor(vec2 ndcXY) {
    return length(ndcXY) * SHADOW_DISTORT_FACTOR + (1.0 - SHADOW_DISTORT_FACTOR);
}

// 扭曲 shadow NDC xy（正交投影 w = 1，clip 与 NDC 同值）；写入端 program/shadow.glsl 与
// 读取端 lib/lighting/shadow.glsl 共用本实现——对称性由共用结构性保证（原本分居写读两文件、须逐字符对称）
vec2 shadowDistort(vec2 ndcXY) {
    return ndcXY / shadowDistortFactor(ndcXY);
}

// 相对世界空间 -> shadow 屏幕 [0,1]：xy 扭曲、z 压缩——与 program/shadow.glsl 写侧逐字符对称
//（读取端比写侧多一步 NDC -> [0,1] 映射）；distortFactor 输出未扭曲 NDC 处的局部放大补偿
//（PCF 半径 / 未来 blocker search 用）
vec3 relativeWorldToShadowScreen(vec3 relativeWorldPos, out float distortFactor) {
    vec4 clipPos = shadowProjection * shadowModelView * vec4(relativeWorldPos, 1.0);
    vec3 ndcPos = clipPos.xyz; // 正交 w = 1
    distortFactor = shadowDistortFactor(ndcPos.xy);
    return vec3(shadowDistort(ndcPos.xy), ndcPos.z * SHADOW_DEPTH_SCALE) * 0.5 + 0.5;
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

// cotangent frame：由观察空间位置与 UV 的屏幕导数构造 TBN（春雷 / 春v2 同款）。导数由调用方
// 先于 discard 集中求好传入（discard 后 quad 内幸存像素的导数未定义），TBN 构造与后续法线
// 采样得以推迟到 discard 之后；任意贴图向量经 mat3(T, B, N) 左乘即观察空间向量
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
