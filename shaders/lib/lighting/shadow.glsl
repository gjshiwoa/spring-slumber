// 阴影贴图采样核心（写入端 program/shadow.glsl 与本文件读取端共用同一套扭曲 / 压缩公式，须逐字符对称）
// 路线（24 包调研定档，低配 / 高兼容）：线性 distortion（春v2 / BSL / Kappa 同族）+ shadowtex0 硬件比较
// 黄金螺旋 PCF（IGN 时域旋转，composite_taa 时间累积收敛为软阴影，零额外 pass）+ shadowtex1 裸深度手动
// 比较分离半透明遮挡、取 shadowcolor0 透射色上彩色阴影（春v2 getColorShadow 同款）
// shadowtex1 保持 sampler2D 裸深度（不开 shadowHardwareFiltering1）：彩色阴影检测与未来 PCSS blocker
// search 共用的后路——升级 PCSS 只需在本文件加 blocker search（读 tex1 浅于接收者的平均遮挡深度推半影
// 半径，替换下方常数半径），引擎配置零改动
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：
//   lib/common/globals/constants.glsl（阴影常量）、lib/common/globals/uniforms.glsl（shadow 矩阵与采样器、
//   frameCounter、rainStrength）、lib/common/utils/color.glsl（srgbToLinear）
#ifndef LIB_SHADOW_GLSL
#define LIB_SHADOW_GLSL

// ---------------- 变换（写读两侧同一公式，任意阶段可用） ----------------

// 线性扭曲因子：中心（d = 0）为 1 - SHADOW_DISTORT_FACTOR = 0.15，纹素密度放大约 6.7 倍；边缘（d = 1）为 1 不缩放
float shadowDistortFactor(vec2 ndcXY) {
    return length(ndcXY) * SHADOW_DISTORT_FACTOR + (1.0 - SHADOW_DISTORT_FACTOR);
}

// 扭曲 shadow NDC xy（正交投影 w = 1，clip 与 NDC 同值）
vec2 shadowDistort(vec2 ndcXY) {
    return ndcXY / shadowDistortFactor(ndcXY);
}

// 相对世界空间 -> shadow 屏幕 [0,1]：xy 扭曲、z 压缩——与 program/shadow.glsl 写侧
// gl_Position 的逐字符对称（读取端比写侧多一步 NDC -> [0,1] 映射）；
// distortFactor 输出未扭曲 NDC 处的局部放大补偿（PCF 半径 / 未来 blocker search 用）
vec3 relativeWorldToShadowScreen(vec3 relativeWorldPos, out float distortFactor) {
    vec4 clipPos = shadowProjection * shadowModelView * vec4(relativeWorldPos, 1.0);
    vec3 ndcPos = clipPos.xyz; // 正交 w = 1
    distortFactor = shadowDistortFactor(ndcPos.xy);
    return vec3(shadowDistort(ndcPos.xy), ndcPos.z * SHADOW_DEPTH_SCALE) * 0.5 + 0.5;
}

#ifdef STAGE_FRAGMENT

// ---------------- 采样（仅片段阶段） ----------------

// IGN 时域抖动噪声（interleaved gradient noise + 帧序 golden ratio 偏移，Photon 同款，3 条 ALU 无纹理）：
// 逐像素旋转 / 抖动 PCF 采样盘，composite_taa 时间累积把噪声解析成收敛的软阴影
float shadowDither(vec2 pixelPos) {
    return fract(52.9829189 * fract(dot(pixelPos, vec2(0.06711056, 0.00583715))
                                    + float(frameCounter % 64) * 0.61803399));
}

// 阴影可见性（rgb，1 = 全亮，被半透明遮挡处为其透射色——彩色阴影）
// relativeWorldPos 相对世界空间位置（未加 normal offset，函数内部加；由 shadeSurface 统一换算一次传入）
// normalWorld 世界系法线（归一化）
// ndl         世界系 NdotL（未截断；正值才调用，负值背光面由调用方直接全影）
// distWorld   相机距离；出屏 / 超距返回 1（回退门控由 lighting.glsl 用 lm 天空光近似混合）
vec3 sampleShadowVisibility(vec3 relativeWorldPos, vec3 normalWorld, float ndl, float distWorld) {
    if (distWorld > shadowDistance) return vec3(1.0);

    // normal offset：世界坐标沿法线偏移，随距离与坡度放大（春v2 同思路）——把接收点推出自阴影痤疮带
    vec3 shadowOrigin = relativeWorldPos
                      + normalWorld * (SHADOW_BIAS_NORMAL * (1.0 + distWorld * 0.01)
                                       * (2.0 - clamp(ndl, 0.0, 1.0)));

    float distortFactor;
    vec3 shadowPos = relativeWorldToShadowScreen(shadowOrigin, distortFactor);
    if (any(notEqual(clamp(shadowPos.xy, 0.0, 1.0), shadowPos.xy))) return vec3(1.0); // 出屏：贴图外无内容
    shadowPos.z -= SHADOW_BIAS_DEPTH;

    // 软半径：texel 基数 + 距离增长 + 雨天扩散；÷ 扭曲因子补偿扭曲空间的纹素密度
    //（中心 f = 0.15、纹素世界尺寸小 ~6.7 倍，除以 f 保持世界半径恒定——近处阴影边缘不锯齿化，c13 同款）
    float radiusTexels = SHADOW_RADIUS_BASE
                       + SHADOW_RADIUS_DIST * clamp(distWorld / shadowDistance, 0.0, 1.0)
                       + 2.0 * rainStrength;
    float radius = radiusTexels / (distortFactor * float(shadowMapResolution));

    float rotation = shadowDither(gl_FragCoord.xy) * TAU;
    float radialJitter = shadowDither(gl_FragCoord.yx);

    vec3 visibilitySum = vec3(0.0);
    for (int i = 0; i < SHADOW_PCF_SAMPLES; i++) {
        // 黄金螺旋盘：sqrt 径向分布均匀 + 黄金角展开（免采样表）
        float fi = float(i) + radialJitter;
        float r = sqrt(fi / float(SHADOW_PCF_SAMPLES)) * radius;
        float theta = fi * GOLDEN_ANGLE + rotation;
        vec2 tapUv = shadowPos.xy + r * vec2(cos(theta), sin(theta));

        // 基础可见性：shadowtex0（全几何，含半透明）硬件比较——一次 texture 顶手动 2×2 双线性比较
        // （GLSL 330 中 sampler2DShadow 的 texture() 返回 float 标量）
        float allVis = texture(shadowtex0, vec3(tapUv, shadowPos.z));

        vec3 tapVisibility = vec3(allVis);
        if (allVis < 1.0) {
            // 有遮挡：tex1 裸深度（仅不透明）手动比较，opaqueVis > 0 即非不透明遮挡——
            // 取 shadowcolor0 透射色上彩色阴影（染色玻璃 / 水下偏暗带蓝），不透明遮挡保持全影
            float opaqueVis = step(shadowPos.z, textureLod(shadowtex1, tapUv, 0.0).r);
            if (opaqueVis > 0.0) {
                tapVisibility = mix(srgbToLinear(texture(shadowcolor0, tapUv).rgb), vec3(1.0), allVis);
            }
        }
        visibilitySum += tapVisibility;
    }
    return visibilitySum / float(SHADOW_PCF_SAMPLES);
}

#endif

#endif
