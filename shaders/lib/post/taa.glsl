// 轻量 TAA / TAAU：相位感知 3x3 重建与统计共用样本，曝光归一化 Reinhard-YCoCg 域累积。
// 借鉴 ITRP FSR2 的距离加权统计 / 去振铃 / 历史修正思想；不新增缓冲、compute 或速度附件。
// 当前色完整补偿光栅 jitter；十字最近深度锚点去抖后重投影，历史 alpha 保存本帧观察深度。
// 解遮挡更新独立于防闪门控；软修正只放宽方差盒，样本极值盒仍为硬边界，防 HDR 过冲累积。
// 依赖（program 平铺引入）：constants.glsl、uniforms.glsl、utils/color.glsl、filters.glsl、
// space.glsl、utils/noise.glsl（applyInverseJitter——锚点去抖基底）。
#ifndef LIB_POST_TAA_GLSL
#define LIB_POST_TAA_GLSL
#ifdef STAGE_FRAGMENT

vec3 closestDepthCross(ivec2 pixel, float centerDepth, ivec2 resolution) {
    ivec2 closestPixel = pixel;
    float closestDepth = centerDepth;
    for (int i = 0; i < 4; i++) {
        ivec2 tapPixel = clamp(pixel + taaCrossOffsets[i], ivec2(0), resolution - 1);
        float tapDepth = texelFetch(depthtex0, tapPixel, 0).r;
        if (tapDepth < closestDepth) {
            closestPixel = tapPixel;
            closestDepth = tapDepth;
        }
    }
    return vec3((vec2(closestPixel) + 0.5) / vec2(resolution), closestDepth);
}

float taaLuma(vec3 color) { return rgbToYCoCg(color).x; }
vec3 taaTonemap(vec3 color) { return color / (1.0 + taaLuma(color)); }
vec3 taaInverseTonemap(vec3 color) { return color / max(1.0 - taaLuma(color), 1e-5); }

struct TaaNeighborhood {
    vec3 lo;
    vec3 hi;
    vec3 mean;
    vec3 sigma;
};

// Lanczos2 的低成本多项式近似；支撑半径 2，负瓣随后由样本极值去振铃约束。
float taaLanczosWeight(float radiusSq) {
    if (radiusSq >= 4.0) return 0.0;
    float a = 0.4 * radiusSq - 1.0;
    float b = 0.25 * radiusSq - 1.0;
    return (1.5625 * a * a - 0.5625) * b * b;
}

#ifdef TAAU
struct TaaReconstruction {
    vec3 color;
    vec3 m1;
    vec3 m2;
    float weight;
    float statsWeight;
    float maxPositive;
    float sumPositive;
};

// 固定九点调用，无动态样本索引；调用方仅保留五个需要退出支撑的外侧颜色。
vec3 taaAccumulateTap(ivec2 centerPixel, ivec2 offset, vec2 delta,
                      ivec2 resolution, float exposure, float boxWeight,
                      inout TaaReconstruction acc) {
    ivec2 tapPixel = clamp(centerPixel + offset, ivec2(0), resolution - 1);
    vec3 color = rgbToYCoCg(taaTonemap(max(texelFetch(colortex6, tapPixel, 0).rgb, vec3(0.0)) * exposure));
    float weight = taaLanczosWeight(dot(delta, delta) * TAAU_KERNEL_BIAS * TAAU_KERNEL_BIAS);
    acc.color += color * weight;
    acc.weight += weight;
    float positiveWeight = max(weight, 0.0);
    acc.maxPositive = max(acc.maxPositive, positiveWeight);
    acc.sumPositive += positiveWeight;
    acc.m1 += color * boxWeight;
    acc.m2 += color * color * boxWeight;
    acc.statsWeight += boxWeight;
    return color;
}

// 等价于 inverseTonemap → max(RGB,0) → tonemap，但消去一轮除法及颜色变换。
vec3 taaSanitizeWorkingColor(vec3 color) {
    vec3 rawRgb = yCoCgToRgb(color);
    vec3 positiveRgb = max(rawRgb, vec3(0.0));
    float denominator = max(1.0 - color.x, 1e-5) + taaLuma(positiveRgb);
    return rgbToYCoCg(positiveRgb / denominator);
}

// position 为渲染 buffer 像素中心坐标，每个 tap 独立钳到有效区。
// 离相位最近的 2×2 恒处于极值支撑平台，立即归约；仅五个外侧候选等待均值。
vec3 taaReconstruct(vec2 position, ivec2 resolution, float exposure,
                    out TaaNeighborhood stats, out float confidence) {
    vec2 p = position - 0.5;
    ivec2 centerPixel = ivec2(floor(p + 0.5));
    vec2 phase = p - vec2(centerPixel);
    ivec2 toward = ivec2(phase.x >= 0.0 ? 1 : -1, phase.y >= 0.0 ? 1 : -1);
    // 分量顺序 = 外侧、中心、朝相位侧；指数及 smoothstep 支撑按轴复用。
    vec3 dx = vec3(-float(toward.x), 0.0, float(toward.x)) - phase.x;
    vec3 dy = vec3(-float(toward.y), 0.0, float(toward.y)) - phase.y;
    vec3 sx = exp2(-TAAU_STAT_WEIGHT * dx * dx) * (1.0 - smoothstep(vec3(0.5), vec3(1.5), abs(dx)));
    vec3 sy = exp2(-TAAU_STAT_WEIGHT * dy * dy) * (1.0 - smoothstep(vec3(0.5), vec3(1.5), abs(dy)));
    float boundX = 1.0 - smoothstep(1.0, 1.5, abs(dx.x));
    float boundY = 1.0 - smoothstep(1.0, 1.5, abs(dy.x));
    TaaReconstruction acc;
    acc.color = vec3(0.0);
    acc.m1 = vec3(0.0);
    acc.m2 = vec3(0.0);
    acc.weight = 0.0;
    acc.statsWeight = 0.0;
    acc.maxPositive = 0.0;
    acc.sumPositive = 0.0;
    stats.lo = vec3(1e20);
    stats.hi = vec3(-1e20);
    {
        vec3 color = taaAccumulateTap(centerPixel, ivec2(0, 0),
                                      vec2(dx.y, dy.y), resolution, exposure, sx.y * sy.y, acc);
        stats.lo = min(stats.lo, color);
        stats.hi = max(stats.hi, color);
    }
    {
        vec3 color = taaAccumulateTap(centerPixel, ivec2(toward.x, 0),
                                      vec2(dx.z, dy.y), resolution, exposure, sx.z * sy.y, acc);
        stats.lo = min(stats.lo, color);
        stats.hi = max(stats.hi, color);
    }
    {
        vec3 color = taaAccumulateTap(centerPixel, ivec2(0, toward.y),
                                      vec2(dx.y, dy.z), resolution, exposure, sx.y * sy.z, acc);
        stats.lo = min(stats.lo, color);
        stats.hi = max(stats.hi, color);
    }
    {
        vec3 color = taaAccumulateTap(centerPixel, ivec2(toward.x, toward.y),
                                      vec2(dx.z, dy.z), resolution, exposure, sx.z * sy.z, acc);
        stats.lo = min(stats.lo, color);
        stats.hi = max(stats.hi, color);
    }
    vec3 outer0 = taaAccumulateTap(centerPixel, ivec2(-toward.x, -toward.y),
                                    vec2(dx.x, dy.x), resolution, exposure, sx.x * sy.x, acc);
    vec3 outer1 = taaAccumulateTap(centerPixel, ivec2(0, -toward.y),
                                    vec2(dx.y, dy.x), resolution, exposure, sx.y * sy.x, acc);
    vec3 outer2 = taaAccumulateTap(centerPixel, ivec2(toward.x, -toward.y),
                                    vec2(dx.z, dy.x), resolution, exposure, sx.z * sy.x, acc);
    vec3 outer3 = taaAccumulateTap(centerPixel, ivec2(-toward.x, 0),
                                    vec2(dx.x, dy.y), resolution, exposure, sx.x * sy.y, acc);
    vec3 outer4 = taaAccumulateTap(centerPixel, ivec2(-toward.x, toward.y),
                                    vec2(dx.x, dy.z), resolution, exposure, sx.x * sy.z, acc);
    float statsRcp = 1.0 / acc.statsWeight;
    stats.mean = acc.m1 * statsRcp;
    stats.sigma = sqrt(max(acc.m2 * statsRcp - stats.mean * stats.mean, vec3(0.0)));
    stats.lo = min(stats.lo, stats.mean);
    stats.hi = max(stats.hi, stats.mean);
    // 外侧候选平滑收回均值，保留半纹素换中心连续性与真实样本极值约束。
    {
        vec3 boundColor = mix(stats.mean, outer0, boundX * boundY);
        stats.lo = min(stats.lo, boundColor);
        stats.hi = max(stats.hi, boundColor);
    }
    {
        vec3 boundColor = mix(stats.mean, outer1, boundY);
        stats.lo = min(stats.lo, boundColor);
        stats.hi = max(stats.hi, boundColor);
    }
    {
        vec3 boundColor = mix(stats.mean, outer2, boundY);
        stats.lo = min(stats.lo, boundColor);
        stats.hi = max(stats.hi, boundColor);
    }
    {
        vec3 boundColor = mix(stats.mean, outer3, boundX);
        stats.lo = min(stats.lo, boundColor);
        stats.hi = max(stats.hi, boundColor);
    }
    {
        vec3 boundColor = mix(stats.mean, outer4, boundX);
        stats.lo = min(stats.lo, boundColor);
        stats.hi = max(stats.hi, boundColor);
    }
    confidence = clamp(acc.maxPositive / max(acc.sumPositive, 1e-5), 0.0, 1.0);
    vec3 current = acc.weight > 1e-3 ? acc.color / acc.weight : stats.mean;
    return taaSanitizeWorkingColor(clamp(current, stats.lo, stats.hi));
}
#else
TaaNeighborhood taaCrossStatistics(ivec2 pixel, ivec2 resolution, float exposure) {
    TaaNeighborhood stats;
    vec3 center = rgbToYCoCg(taaTonemap(max(texelFetch(colortex6, pixel, 0).rgb, vec3(0.0)) * exposure));
    vec3 m1 = center;
    vec3 m2 = center * center;
    stats.lo = center;
    stats.hi = center;
    for (int i = 0; i < 4; i++) {
        vec3 color = rgbToYCoCg(taaTonemap(max(texelFetch(colortex6, clamp(pixel + taaCrossOffsets[i], ivec2(0), resolution - 1), 0).rgb, vec3(0.0)) * exposure));
        m1 += color;
        m2 += color * color;
        stats.lo = min(stats.lo, color);
        stats.hi = max(stats.hi, color);
    }
    stats.mean = m1 * 0.2;
    stats.sigma = sqrt(max(m2 * 0.2 - stats.mean * stats.mean, vec3(0.0)));
    return stats;
}
#endif

vec3 taaClipBox(vec3 color, vec3 lo, vec3 hi) {
    vec3 center = (hi + lo) * 0.5;
    vec3 extents = max((hi - lo) * 0.5, vec3(1e-5));
    vec3 delta = color - center;
    vec3 unit = abs(delta / extents);
    float extent = max(unit.x, max(unit.y, unit.z));
    return center + delta / max(extent, 1.0);
}

float taaHistoryDepthConfidence(float expectedDepth, float historyDepth, bool isSky) {
    bool historySky = historyDepth >= TAA_DEPTH_SENTINEL * 0.999;
    if (isSky != historySky) return 0.0;
    if (isSky) return 1.0;
    return 1.0 - smoothstep(TAA_DEPTH_CONF_EDGE0, TAA_DEPTH_CONF_EDGE1,
                            abs(expectedDepth - historyDepth) / expectedDepth);
}

#ifdef TAAU
// 最近深度不匹配时，仅在颜色同一 2×2 双线性足迹中找有实际贡献的几何深度。
// 不插值深度（前 / 背景混值是虚构表面），不扩大容差；手部、天空与快速运动不用兜底。
float taaHistoryFootprintConfidence(vec2 historyUV, vec2 viewSize, float expectedDepth,
                                     float nearestConf, float motion) {
    vec2 historyPos = historyUV * viewSize - 0.5;
    ivec2 basePixel = ivec2(floor(historyPos));
    vec2 phase = fract(historyPos);
    ivec2 nearestPixel = clamp(ivec2(historyUV * viewSize), ivec2(0), ivec2(viewSize) - 1);
    float footprintConf = nearestConf;
    for (int i = 0; i < 4; i++) {
        ivec2 offset = taaHistoryOffsets[i];
        vec2 axisWeight = mix(1.0 - phase, phase, vec2(offset));
        float support = smoothstep(TAAU_DEPTH_SUPPORT_LOW, TAAU_DEPTH_SUPPORT_HIGH,
                                    axisWeight.x * axisWeight.y);
        if (support <= 0.0) continue;
        ivec2 tapPixel = clamp(basePixel + offset, ivec2(0), ivec2(viewSize) - 1);
        if (all(equal(tapPixel, nearestPixel))) continue; // 已有最近 tap 的置信度，最多额外三读
        float tapDepth = texelFetch(colortex3, tapPixel, 0).a;
        float tapConf = taaHistoryDepthConfidence(expectedDepth, tapDepth, false);
        footprintConf = max(footprintConf, tapConf * support);
    }
    return mix(nearestConf, footprintConf, 1.0 - motion);
}
#endif

vec3 taaRectifyHistory(vec3 history, TaaNeighborhood stats, float depthConf, float motion,
                       out float clipDistance) {
    float clipGamma = TAA_CLIP_GAMMA;
#ifdef TAAU
    float edgeContrast = smoothstep(TAAU_EDGE_CONTRAST_LOW, TAAU_EDGE_CONTRAST_HIGH,
                                    stats.hi.x - stats.lo.x);
    float stableEdge = edgeContrast * depthConf * (1.0 - motion);
    clipGamma = mix(clipGamma, TAAU_EDGE_CLIP_GAMMA, stableEdge);
#endif
    vec3 lo = max(stats.mean - clipGamma * stats.sigma, stats.lo);
    vec3 hi = min(stats.mean + clipGamma * stats.sigma, stats.hi);
    // 极值盒始终硬约束；只有方差盒软修正。无亮度历史，不能把真实颜色变化误认作周期闪烁。
    vec3 bounded = taaClipBox(history, stats.lo, stats.hi);
    vec3 clipped = taaClipBox(bounded, lo, hi);
    vec3 extents = max((hi - lo) * 0.5, vec3(1e-5));
    vec3 unit = abs((history - (hi + lo) * 0.5) / extents);
    float maxUnit = max(unit.x, max(unit.y, unit.z));
    vec3 toEdge = max(min(history - lo, hi - history), vec3(0.0));
    clipDistance = maxUnit > 1.0 ? 0.0 : clamp(length(toEdge) * TAA_CLIP_DISTANCE_GAIN, 0.0, 1.0);
    // 大幅亮度 / 色度变化照常修正，防动态实体拖影；低速可信历史只减轻小幅方差盒摆动。
    float changeDistance = length(history - stats.mean);
#ifdef TAAU
    // 轮廓两侧均值随覆盖率摆动，不等于真实颜色突变；边缘按历史越出硬极值盒的距离判变。
    // 平坦区及不可信 / 快速运动区仍用原判据，硬盒之外的旧色始终先行剔除。
    changeDistance = mix(changeDistance, length(history - bounded), stableEdge);
#endif
    float colorChange = smoothstep(TAA_RECTIFY_CHANGE_LOW, TAA_RECTIFY_CHANGE_HIGH, changeDistance);
    float repair = mix(TAA_RECTIFY_STABLE, 1.0, max(max(1.0 - depthConf, motion), colorChange));
    return mix(bounded, clipped, repair);
}

vec3 resolveTAA(vec2 uv, ivec2 pixel, vec2 jitterUV, float exposure, out float outHistoryDepth) {
    vec2 viewSize = vec2(viewWidth, viewHeight);
#ifdef TAAU
    vec2 renderResF = floor(viewSize * RENDER_SCALE + 0.5);
    ivec2 renderRes = ivec2(renderResF);
    // 光栅缩放取精确 S；整数有效区仅用于 tap 边界，不改变投影坐标尺度。
    ivec2 renderPixel = clamp(ivec2(uv * viewSize * RENDER_SCALE), ivec2(0), renderRes - 1);
#else
    ivec2 renderRes = ivec2(viewSize);
    ivec2 renderPixel = pixel;
#endif
    vec3 closest = closestDepthCross(renderPixel, texelFetch(depthtex0, renderPixel, 0).r, renderRes);
    bool isSky = closest.z >= 1.0;
    bool isHand = closest.z < TAA_HAND_DEPTH;
    TaaNeighborhood stats;
    float upsampleConfidence = 1.0;
#ifdef TAAU
    // applyTAAJitter 在缩放后平移完整 jitter；源色采样必须等量补偿，半补偿会留下相位漂移。
    vec3 current = taaReconstruct(uv * viewSize * RENDER_SCALE + jitterUV * viewSize,
                                  renderRes, exposure, stats, upsampleConfidence);
#else
    stats = taaCrossStatistics(renderPixel, renderRes, exposure);
    vec3 current = rgbToYCoCg(taaTonemap(max(textureLod(colortex6, uv + jitterUV * 0.5, 0.0).rgb, vec3(0.0)) * exposure));
#endif
    // 手工施加的 jitter 不在 gbufferProjectionInverse 内；先回无抖动视场域再重建（去抖基底与
    // deferred_init 同式——noise.glsl 的 applyInverseJitter 参数版单真源；TAAU 下最近深度像素
    // 域先 ×renderResF/viewSize 换 buffer uv）
#ifdef TAAU
    vec2 anchorUV = applyInverseJitter(closest.xy * renderResF / viewSize, jitterUV);
#else
    vec2 anchorUV = applyInverseJitter(closest.xy, jitterUV);
#endif
    vec3 anchorViewPos = screenToView(vec3(anchorUV, closest.z));
    float linearDepth = isSky ? TAA_DEPTH_SENTINEL : min(-anchorViewPos.z, TAA_DEPTH_SENTINEL);
    outHistoryDepth = linearDepth;
    float expectedDepth = 0.0;
    vec4 previousClip;
    if (isSky) {
        previousClip = gbufferPreviousProjection * gbufferPreviousModelView * vec4(viewToWorldDirection(anchorViewPos), 0.0);
    } else {
        vec3 cameraDelta = isHand ? vec3(0.0) : cameraPosition - previousCameraPosition;
        vec4 previousView = gbufferPreviousModelView * vec4(viewToRelativeWorld(anchorViewPos) + cameraDelta, 1.0);
        expectedDepth = max(-previousView.z, 1e-4);
        previousClip = gbufferPreviousProjection * previousView;
    }
    vec2 previousUV = previousClip.xy / max(previousClip.w, 1e-5) * 0.5 + 0.5;
    vec2 velocity = anchorUV - previousUV;
    vec2 historyUV = uv - velocity;
    bool invalid = previousClip.w <= 0.0 || any(lessThan(historyUV, vec2(0.0))) || any(greaterThan(historyUV, vec2(1.0)));
    if (invalid || frameCounter == 0) return max(taaInverseTonemap(yCoCgToRgb(current)) / exposure, vec3(0.0));
    ivec2 historyPixel = clamp(ivec2(historyUV * viewSize), ivec2(0), ivec2(viewSize) - 1);
    float historyDepth = texelFetch(colortex3, historyPixel, 0).a;
    float velocityPx = length(velocity * viewSize);
    float motion = smoothstep(TAA_MOTION_LOW, TAA_MOTION_HIGH, velocityPx);
    float depthConf = taaHistoryDepthConfidence(expectedDepth, historyDepth, isSky);
#ifdef TAAU
    // 仅高反差轮廓且最近深度失配时多取足迹深度；普通表面沿原单点路径。
    if (!isSky && !isHand && motion < 1.0 && depthConf < 1.0 &&
        stats.hi.x - stats.lo.x > TAAU_EDGE_CONTRAST_LOW) {
        depthConf = taaHistoryFootprintConfidence(historyUV, viewSize, expectedDepth, depthConf, motion);
    }
#endif
    vec3 historyLinear;
    if (isSky) historyLinear = textureLod(colortex3, historyUV, 0.0).rgb;
    else historyLinear = catmullRom5(colortex3, historyUV, viewSize, TAA_HISTORY_SHARPNESS).rgb;
    vec3 history = rgbToYCoCg(taaTonemap(max(historyLinear, vec3(0.0)) * exposure));
    float clipDistance;
    history = taaRectifyHistory(history, stats, depthConf, motion, clipDistance);
#ifdef TAAU
    float blendBase = TAAU_BLEND_BASE;
#else
    float blendBase = TAA_BLEND_BASE;
#endif
    float blend = max(blendBase + velocityPx * TAA_BLEND_MOTION, TAA_BLEND_MIN);
    float confidence = pow(upsampleConfidence, TAAU_CONFIDENCE_POWER);
    blend *= confidence * (1.0 - clipDistance);
    // 偏心拒绝只在真实运动时工作，并服从相位置信度，不再绕过防闪无条件注入 15%。
    vec2 centered = 1.0 - abs(2.0 * fract(historyUV * viewSize) - 1.0);
    float eccentricity = 1.0 - sqrt(centered.x * centered.y);
    blend += (1.0 - blend) * eccentricity * TAA_OFFCENTER_REJECTION * motion * confidence * (1.0 - clipDistance);
    // 解遮挡是最后的独立更新下限；完全失配直接当前帧，任何防闪门控都不能压住它。
    float disocclusion = 1.0 - depthConf;
    blend = max(blend, mix(TAA_BLEND_DISOCCCLUSION * disocclusion, 1.0, disocclusion * disocclusion));
    if (isHand) blend = max(blend, TAA_BLEND_HAND_MIN);
    vec3 resolved = mix(history, current, clamp(blend, 0.0, 1.0));
    return max(taaInverseTonemap(yCoCgToRgb(resolved)) / exposure, vec3(0.0));
}

#endif
#endif
