// 阴影贴图采样核心（路线与分档依据见 AGENTS.md「阴影贴图」条 / constants.glsl 阴影分区）：
// 线性 distortion + shadowtex0 硬件比较黄金螺旋 PCF（temporal bayer 时域旋转，composite_taa
// 时间累积收敛为软阴影）+ shadowtex1 裸深度手动比较分离半透明遮挡、取 shadowcolor0 透射色
// 上彩色阴影（春v2 getColorShadow 同款）。扭曲 / 压缩换算在 utils/space.glsl（写读两侧共用）。
// PCSS 后路：tex1 保持裸深度，未来加 blocker search（读 tex1 浅于接收者的平均遮挡深度推半影
// 半径、替换常数半径）即升级，引擎配置零改动
// 依赖由接入的 program 先行 include：constants.glsl / uniforms.glsl / utils/color.glsl（srgbToLinear）/
//   utils/space.glsl（shadowDistort / relativeWorldToShadowScreen）/ utils/noise.glsl（temporalBayer64）
#ifndef LIB_SHADOW_GLSL
#define LIB_SHADOW_GLSL

#ifdef STAGE_FRAGMENT

// ---------------- 采样（仅片段阶段） ----------------

// 阴影可见性（rgb，1 = 全亮，被半透明遮挡处为其透射色——彩色阴影）
// relativeWorldPos 相对世界空间位置（未加 normal offset，函数内部加；由 shadeSurface 统一换算一次传入）
// normalWorld 世界系法线（归一化）
// ndl         世界系 NdotL（未截断、未 wrap——SSS 背光面采样时仍取原始值，normal offset 的坡度
//             缩放在背光侧保持满档，把采样点推出叶片自身的阴影面；调用方按 wrap 后余弦门控）
// distWorld   相机距离；出屏 / 超距返回 1（贴图覆盖外按全亮，无回退门控）
// sssStrength 次表面散射强度 [0,1]（materialSSSStrength）——软半径 = SSS_SOFT_RADIUS_MAX × 强度
//             线性增长，tap 越出叶片自身阴影边界使背光侧部分漏光（春v2 同构）
vec3 sampleShadowVisibility(vec3 relativeWorldPos, vec3 normalWorld, float ndl, float distWorld,
                            float sssStrength) {
    if (distWorld > shadowDistance) return vec3(1.0);

    // normal offset：世界坐标沿法线偏移，随距离与坡度放大（春v2 同思路）——把接收点推出自阴影痤疮带
    vec3 shadowOrigin = relativeWorldPos
                      + normalWorld * (SHADOW_BIAS_NORMAL * (1.0 + distWorld * 0.01)
                                       * (2.0 - clamp(ndl, 0.0, 1.0)));

    float distortFactor;
    vec3 shadowPos = relativeWorldToShadowScreen(shadowOrigin, distortFactor);
    if (any(notEqual(clamp(shadowPos.xy, 0.0, 1.0), shadowPos.xy))) return vec3(1.0); // 出屏：贴图外无内容
    shadowPos.z -= SHADOW_BIAS_DEPTH;

    // 软半径：texel 基数 + 距离增长 + 雨天扩散 + SSS 软化；÷ 扭曲因子补偿扭曲空间的纹素密度
    //（中心纹素密度高 ~6.7 倍，除以 f 保持世界半径恒定——近处阴影边缘不锯齿化，c13 同款）
    float radiusTexels = SHADOW_RADIUS_BASE
                       + SHADOW_RADIUS_DIST * clamp(distWorld / shadowDistance, 0.0, 1.0)
                       + 2.0 * rainStrength
                       + SSS_SOFT_RADIUS_MAX * sssStrength;
    float radius = radiusTexels / (distortFactor * float(shadowMapResolution));

    // tap 数按盘半径分档（噪声取决于 tap 密度，分档依据见 constants.glsl）；黄金螺旋取前 N 个
    // 方向仍是均匀盘——两档共用 SHADOW_PCF_DIRS 表，仅径向归一化分母随档变化
    int sampleCount = radiusTexels > SHADOW_PCF_LOW_TIER_TEXELS
                    ? SHADOW_PCF_SAMPLES : SHADOW_PCF_SAMPLES_LOW;

    // temporal bayer（春v2 同款）驱动盘相位：起始角乘非整系数 17.333 打散 bayer 相邻像素的规则
    // 角度差免取向条纹，径向相位同源单噪声驱动，帧间 golden ratio 步进整个盘旋转、时间累积解析为
    // 软阴影。角度加法外提（性能）：theta_i = i·GA + φ 与原 (i+noise)·GA + rotation 逐位恒等——
    // 基准方向查编译期常量表，每像素仅一对 sincos，逐 tap 一次 mat2 旋转乘（低配 GPU 超越函数
    // 1/4 速率，高档省 22 次）；采样位置逐位不变
    float noise = temporalBayer64(gl_FragCoord.xy);
    float phi = noise * (GOLDEN_ANGLE + TAU * 17.3333333);
    vec2 rot = vec2(cos(phi), sin(phi));
    mat2 rotM = mat2(rot.x, rot.y, -rot.y, rot.x);

    vec3 visibilitySum = vec3(0.0);
    for (int i = 0; i < sampleCount; i++) {
        // 黄金螺旋盘：sqrt 径向分布均匀（径向抖动逐 tap sqrt，与基准角解耦）+ 黄金角展开（查表）
        float r = sqrt((float(i) + noise) / float(sampleCount)) * radius;
        vec2 tapUv = shadowPos.xy + r * (rotM * SHADOW_PCF_DIRS[i]);

        // 基础可见性：shadowtex0（全几何，含半透明）硬件比较——一次采样顶手动 2×2 双线性比较
        // （GLSL 330 中 sampler2DShadow 的比较采样返回 float 标量；textureLod 重载同样支持，
        //   LOD 0 显式指定免隐式导数——深度图无 mip，恒采最高细节层）
        float allVis = textureLod(shadowtex0, vec3(tapUv, shadowPos.z), 0.0);

        vec3 tapVisibility = vec3(allVis);
        if (allVis < 1.0) {
            // 有遮挡：tex1 裸深度（仅不透明）texelFetch 手动比较，opaqueVis > 0 即非不透明遮挡——
            // 取 shadowcolor0 透射色上彩色阴影，不透明遮挡保持全影。texelFetch 免滤波且免隐式导数；
            // shadowcolor0 与 tex1 同分辨率同布局、判定与取色 texel 恒一致；tap 可越出 [0,1]，由钳边承担
            ivec2 tapTexel = clamp(ivec2(tapUv * float(shadowMapResolution)),
                                   ivec2(0), ivec2(shadowMapResolution - 1));
            float opaqueVis = step(shadowPos.z, texelFetch(shadowtex1, tapTexel, 0).r);
            if (opaqueVis > 0.0) {
                tapVisibility = mix(srgbToLinear(texelFetch(shadowcolor0, tapTexel, 0).rgb), vec3(1.0), allVis);
            }
        }
        visibilitySum += tapVisibility;
    }
    return visibilitySum / float(sampleCount);
}

#endif

#endif
