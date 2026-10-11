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

// screenToView 的典则透视闭式（shadow.glsl 屏幕空间追踪的步内场化同款公式，与 screenToView
// 代数恒等——tools/sim_canonical_viewpos_verify.py 数值验证机器精度级）：gbufferProjection 恒为
// 典则对称透视矩阵（OptiFine / Iris 注入，clip.w = -view.z）——viewZ = -projD/(ndcZ + projC)
// 一次除、view.xy = ndc.xy·projXY·(-viewZ)，免每像素 mat4 乘 + 3 div；矩阵结构若变则回退
// screenToView。逐像素全屏重建的热路径（composite_fog 边界雾）消费；入参 uv / depth 语义与
// screenToView(vec3(uv, depth)) 完全一致（z = 1 落远平面、未归一化方向的调用方照用）
vec3 screenToViewCanonical(vec2 uv, float depth) {
    float projC = gbufferProjection[2].z;
    float projD = gbufferProjection[3].z;
    vec2 projXY = 1.0 / vec2(gbufferProjection[0].x, gbufferProjection[1].y);

    vec2 ndc = uv * 2.0 - 1.0;
    float viewZ = -projD / (depth * 2.0 - 1.0 + projC);
    return vec3(ndc * projXY * (-viewZ), viewZ);
}

// 观察空间方向 -> 世界空间方向（纯旋转、不要求归一化，长度保持）
// 天空色（sky.glsl）与光照方向换算（lighting.glsl）共用
vec3 viewToWorldDirection(vec3 dirView) {
    return mat3(gbufferModelViewInverse) * dirView;
}

// 观察空间位置 -> 玩家相对世界空间（世界轴向；绝对世界坐标 = 结果 + cameraPosition）。
// 完整逆视图含平移：旧版原点可在脚部，新版可与实际眼点相差视角晃动；
// 实际眼点在此空间为 gbufferModelViewInverse[3].xyz，不保证是零点。
// 位置用于阴影 / TAA 重投影；视向量必须由观察位置仅旋转获得，不能直接归一化本结果。
// 保持相对坐标可避开大世界坐标的 float 精度损失：SSR / SSAO 等共用
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

// ---------------- SR 超分运动矢量（SR mod，superresolution.v3.json；constants.glsl 的
// SR_UPSCALE / SR_ENTITY_VELOCITY 须先行引入）----------------
// 域约定：入参 uv 一律为「无抖动全视场 uv」（= 子区域 buffer uv 经 applyInverseJitter 归一——
// 子区域渲染下全视场 uv 即渲染分辨率归一 uv，SR 的 MV 域定义）；返回 prev − cur。
// 上帧的子区域缩放与本帧互逆（buffer uv = 全视场 uv·S + jitter），故两侧全视场 uv 之差 =
// 渲染分辨率域 MV、无额外换算。prevClip.w <= 0（上帧相机背后 / 出视锥）置 0：该像素上帧
// 不存在、位移无意义，交超分算法的解遮挡检测处置
#if defined(SR_UPSCALE)
// 场景（相机运动）运动矢量：depth 由调用方传入（deferred_init 采样 depthtex1——与 SR 的
// noTranslucentDepthtex 输入同源；SR 资源名不能作为 GLSL sampler 使用）。
// 天空（depth >= 1）走远平面方向旋转链（w = 0 平移失效，只随相机旋转），几何走相对世界坐标
// + 相机位移重投影（relativeWorldToPreviousScreen 同链内联，w 守卫归并）
vec2 srSceneMotionVector(vec2 uv, float depth) {
    vec4 prevClip;
    if (depth >= 1.0) {
        prevClip = gbufferPreviousProjection * gbufferPreviousModelView
                 * vec4(viewToWorldDirection(screenToViewCanonical(uv, 1.0)), 0.0);
    } else {
        // 手部跟随相机，不叠相机平移（与本包 TAA / SR 文档示例同约定）；
        // depthtex1 含不透明手，不能把它当固定世界几何做平移重投影。
        vec3 cameraDelta = depth < TAA_HAND_DEPTH ? vec3(0.0)
                         : cameraPosition - previousCameraPosition;
        prevClip = gbufferPreviousProjection * gbufferPreviousModelView * vec4(
            viewToRelativeWorld(screenToViewCanonical(uv, depth)) + cameraDelta, 1.0);
    }
    return prevClip.w > 1e-5 ? prevClip.xy / prevClip.w * 0.5 + 0.5 - uv : vec2(0.0);
}
#endif
#if defined(SR_ENTITY_VELOCITY)
// 实体层运动矢量：velocity = at_velocity（观察空间「到上一帧顶点位置的偏移」，仅实体 / 方块
// 实体绑定——SR 的 Iris 扩展供给，gbuffers_opaque_entities 的 vsh 声明）——viewPos + velocity
// 即上帧观察空间位置、直接过上帧投影（相机运动已含在偏移内，无须 cameraDelta）；curUv =
// fsh 将 vsh 传入的无抖动 vec4 clip 位置在插值后除 w 得到的全视场 uv（不得先除 w 再插值）
vec2 srEntityMotionVector(vec3 viewPos, vec3 velocity, vec2 curUv) {
    vec4 prevClip = gbufferPreviousProjection * vec4(viewPos + velocity, 1.0);
    return prevClip.w > 1e-5 ? prevClip.xy / prevClip.w * 0.5 + 0.5 - curUv : vec2(0.0);
}
#endif

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
