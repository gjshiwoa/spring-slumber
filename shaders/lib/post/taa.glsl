// 轻量 TAA / TAAU：相位感知 3x3 重建与统计共用样本，曝光归一化 Reinhard-YCoCg 域累积。
// 借鉴 ITRP FSR2 的距离加权统计 / 去振铃 / 历史修正思想；不新增缓冲、compute 或速度附件。
// 当前色完整补偿光栅 jitter；十字最近深度锚点去抖后重投影，历史 alpha 保存本帧观察深度。
// 默认常量混合；唯一深度区间确认拒绝解遮挡，固定TAAU另放宽可信颜色盒。
// 删 TAA_FIXED_BLEND 切换自适应混合、共用深度区间；当前去振铃与历史颜色边界分离。
// 依赖（program 平铺引入）：constants.glsl、uniforms.glsl、utils/color.glsl、filters.glsl、
// space.glsl、utils/noise.glsl（applyInverseJitter——锚点去抖基底）。
// VOXY 另需 compat/voxy/scene.glsl：专属深度重建、最近可见表面选择。
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

#ifdef VOXY
// 十字锚点比较真实观察深度；LOD 锚点保留 vx 矩阵重建的位置供重投影。
vec3 closestVoxyDepthCross(ivec2 pixel, ivec2 resolution, vec2 jitterUv,
                           out vec3 anchorViewPos, out bool isSky, out bool isHand) {
    ivec2 closestPixel = pixel;
    float closestDepth = 1.0;
    float closestDistance = 1e30;
    isSky = true;
    isHand = false;
    for (int i = 0; i < 5; i++) {
        ivec2 tapPixel = i == 0 ? pixel : clamp(pixel + taaCrossOffsets[i - 1], ivec2(0), resolution - 1);
        vec2 bufferPx = vec2(tapPixel) + 0.5;
        float nativeDepth = texelFetch(depthtex0, tapPixel, 0).r;
        vec2 fullUv = applyInverseJitter(bufferPx / vec2(viewWidth, viewHeight), jitterUv);
        vec3 viewPos = screenToView(vec3(fullUv, nativeDepth));
        bool lodSurface;
        bool valid = voxyScenePosition(bufferPx, jitterUv, nativeDepth, true, viewPos, lodSurface);
        bool hand = valid && !lodSurface && nativeDepth < TAA_HAND_DEPTH;
        float distance = valid ? (hand ? nativeDepth - 1.0 : -viewPos.z) : 1e30;
        if (i == 0 || distance < closestDistance) {
            closestPixel = tapPixel;
            closestDepth = nativeDepth;
            closestDistance = distance;
            anchorViewPos = viewPos;
            isSky = !valid;
            isHand = hand;
        }
    }
    return vec3((vec2(closestPixel) + 0.5) / vec2(resolution), closestDepth);
}
#endif

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
// 只给高反差历史盒少量颜色容差；范围有绝对上限，平坦邻域无余量。
float taaHistoryBoundMargin(float span, float edgeContrast) {
    return min(max(span * TAAU_HISTORY_MARGIN_SCALE, TAAU_HISTORY_MARGIN_FLOOR),
               TAAU_HISTORY_MARGIN_MAX) * edgeContrast;
}

struct TaaReconstruction {
    vec3 color;
    vec3 m1;
    vec3 m2;
    float weight;
    float statsWeight;
    float maxPositive;
    float sumPositive;
#ifdef TAAU_HISTORY_RAW_BOUNDS
    vec3 rawLo;
    vec3 rawHi;
#endif
};

// 固定九点调用，无动态样本索引；调用方仅保留五个需要退出支撑的外侧颜色。
vec3 taaAccumulateTap(ivec2 centerPixel, ivec2 offset, vec2 delta,
                      ivec2 resolution, float exposure, float boxWeight,
                      inout TaaReconstruction acc) {
    ivec2 tapPixel = clamp(centerPixel + offset, ivec2(0), resolution - 1);
    vec3 color = rgbToYCoCg(taaTonemap(max(texelFetch(colortex6, tapPixel, 0).rgb, vec3(0.0)) * exposure));
    float weight = taaLanczosWeight(dot(delta, delta) * TAAU_KERNEL_BIAS * TAAU_KERNEL_BIAS);
#ifdef TAAU_HISTORY_RAW_BOUNDS
    // 历史接受范围使用原始样本；与重建核负瓣 / 外侧样本相位淡出分离。
    acc.rawLo = min(acc.rawLo, color);
    acc.rawHi = max(acc.rawHi, color);
#endif
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
#ifdef TAAU_HISTORY_RAW_BOUNDS
    acc.rawLo = vec3(1e20);
    acc.rawHi = vec3(-1e20);
#endif
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
    // 当前帧仍用相位连续边界去振铃；历史另用原始九点范围，避免外侧样本
    // 随 jitter 收回均值时把已积累的轮廓中间色硬推走。不增加纹理读取。
    current = taaSanitizeWorkingColor(clamp(current, stats.lo, stats.hi));
#ifdef TAAU_HISTORY_RAW_BOUNDS
    stats.lo = acc.rawLo;
    stats.hi = acc.rawHi;
#endif
#ifdef TAAU_HISTORY_BOUND_SLACK
    float boundContrast = smoothstep(TAAU_EDGE_CONTRAST_LOW, TAAU_EDGE_CONTRAST_HIGH,
                                     stats.hi.x - stats.lo.x);
    vec3 boundSpan = stats.hi - stats.lo;
    vec3 margin = vec3(taaHistoryBoundMargin(boundSpan.x, boundContrast),
                       taaHistoryBoundMargin(boundSpan.y, boundContrast),
                       taaHistoryBoundMargin(boundSpan.z, boundContrast));
    // Reinhard 亮度不能越过 1；高曝光亮部余量随剩余空间缩小，防逆映射放大。
    stats.lo -= margin;
    stats.hi.yz += margin.yz;
    stats.lo.x = max(stats.lo.x, 0.0);
    stats.hi.x += min(margin.x, max(1.0 - stats.hi.x, 0.0) * 0.25);
#endif
    return current;
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

// 历史硬边界 A/B：逐分量限制，避免窄色度轴越界时径向缩放连带推动亮度。
// 方差盒保留径向裁剪；不改变当前帧重建，也不放宽历史样本极值范围。
vec3 taaBoundHistory(vec3 color, vec3 lo, vec3 hi) {
#if defined(TAAU) && defined(TAAU_HISTORY_COMPONENT_CLAMP)
    return clamp(color, lo, hi);
#else
    return taaClipBox(color, lo, hi);
#endif
}

#ifdef TAAU_DEPTH_RANGE_CLIP
// ITT3.2 TAA 的历史 3x3 min/max 拒绝思想；本包 alpha 已是线性观察深度，
// expectedDepth 为当前锚点变换到上一帧观察系后的深度，不比较跨帧原始深度。
float taaDepthRangeConfidence(float expectedDepth, float depthMin, float depthMax) {
    float outside = max(max(depthMin - expectedDepth, expectedDepth - depthMax), 0.0);
    return 1.0 - smoothstep(TAAU_DEPTH_RANGE_TOLERANCE,
                            TAAU_DEPTH_RANGE_TOLERANCE * 2.0,
                            outside / max(expectedDepth, 1e-4));
}

float taaHistoryDepthRangeConfidence(vec2 historyUV, vec2 viewSize,
                                     float expectedDepth, bool isSky) {
    ivec2 centerPixel = clamp(ivec2(historyUV * viewSize), ivec2(0), ivec2(viewSize) - 1);
    float centerDepth = texelFetch(colortex3, centerPixel, 0).a;
    bool hasSky = centerDepth >= TAA_DEPTH_SENTINEL * 0.999;
    if (isSky && hasSky) return 1.0;
    bool centerGeometry = centerDepth > 0.0 && !hasSky;
    float depthMin = centerGeometry ? centerDepth : TAA_DEPTH_SENTINEL;
    float depthMax = centerGeometry ? centerDepth : 0.0;
    float tolerance = max(expectedDepth, 1e-4) * TAAU_DEPTH_RANGE_TOLERANCE;
    float acceptMin = expectedDepth - tolerance;
    float acceptMax = expectedDepth + tolerance;
    // min/max 范围只会扩大；置信度已为1时，剩余样本不可能改变接受结果。
    // 中心是同一套区间归约的首个样本，不另算旧单点置信或重复取中心。
    if (!isSky && centerGeometry && depthMin <= acceptMax && depthMax >= acceptMin)
        return 1.0;
    // 历史为输出分辨率，jitter 为渲染像素：邻域半径至少覆盖一个渲染像素。
    // 先检查原 3x3，再按圈补读，保留细线近邻且已接受像素不增加读取。
    int historyRadius = 1;
#ifdef TAAU
    historyRadius = int(ceil(1.0 / EFFECTIVE_RENDER_SCALE));
#endif
    for (int radius = 1; radius <= historyRadius; radius++) {
        for (int y = -radius; y <= radius; y++) {
            for (int x = -radius; x <= radius; x++) {
                if (abs(x) != radius && abs(y) != radius) continue;
                ivec2 tapPixel = clamp(centerPixel + ivec2(x, y), ivec2(0), ivec2(viewSize) - 1);
                float depth = texelFetch(colortex3, tapPixel, 0).a;
                if (depth >= TAA_DEPTH_SENTINEL * 0.999) {
                    hasSky = true;
                    if (isSky) return 1.0;
                } else if (depth > 0.0) {
                    depthMin = min(depthMin, depth);
                    depthMax = max(depthMax, depth);
                    if (!isSky && depthMin <= acceptMax && depthMax >= acceptMin)
                        return 1.0;
                }
            }
        }
    }
    if (isSky) return 0.0;
    if (depthMax <= 0.0) return 0.0;
    return taaDepthRangeConfidence(expectedDepth, depthMin, depthMax);
}

#if defined(TAAU) && defined(TAA_FIXED_BLEND)
// 有深度支撑时放宽历史颜色范围至均值 +/- gamma*sigma；不扩大当前色重建盒。
// 仍保留颜色变化约束，深度相同并不等于纹理 / 光照 / 半透明颜色相同。
void taaRelaxDepthValidatedBounds(inout TaaNeighborhood stats, float depthConf) {
    vec3 varianceExtent = stats.sigma * TAAU_DEPTH_COLOR_GAMMA;
    stats.lo = mix(stats.lo, min(stats.lo, stats.mean - varianceExtent), depthConf);
    stats.hi = mix(stats.hi, max(stats.hi, stats.mean + varianceExtent), depthConf);
    stats.lo.x = max(stats.lo.x, 0.0);
    stats.hi.x = min(stats.hi.x, max(stats.mean.x, 1.0 - TAAU_DEPTH_COLOR_Y_HEADROOM));
}
#endif
#endif

#ifdef TAA_FIXED_BLEND
// 颜色域单独修正历史：轮廓覆盖率 / 深度 / 运动波动不再收紧方差盒。
// 高反差轮廓按越出最终历史盒的距离判变，避免前背景均值摆动拉动历史；
// 真正变色仍受颜色盒约束；深度区间档扩张系数限制为均值 +/- 2sigma，平坦变色仍收紧。
vec3 taaRectifyFixedHistory(vec3 history, TaaNeighborhood stats) {
    float edgeContrast = smoothstep(TAAU_EDGE_CONTRAST_LOW, TAAU_EDGE_CONTRAST_HIGH,
                                    stats.hi.x - stats.lo.x);
    float clipGamma = mix(TAA_CLIP_GAMMA, TAAU_EDGE_CLIP_GAMMA, edgeContrast);
#if defined(TAAU) && defined(TAAU_DEPTH_RANGE_CLIP)
    clipGamma = max(clipGamma, TAAU_DEPTH_COLOR_GAMMA);
#endif
    vec3 lo = max(stats.mean - clipGamma * stats.sigma, stats.lo);
    vec3 hi = min(stats.mean + clipGamma * stats.sigma, stats.hi);
    vec3 bounded = taaBoundHistory(history, stats.lo, stats.hi);
    vec3 clipped = taaClipBox(bounded, lo, hi);
    float changeDistance = mix(length(history - stats.mean), length(history - bounded), edgeContrast);
    float colorChange = smoothstep(TAA_RECTIFY_CHANGE_LOW, TAA_RECTIFY_CHANGE_HIGH, changeDistance);
    float repair = mix(TAA_RECTIFY_STABLE, 1.0, colorChange);
    return mix(bounded, clipped, repair);
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
    vec3 bounded = taaBoundHistory(history, stats.lo, stats.hi);
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

vec3 resolveTAA(vec2 uv, ivec2 pixel, vec2 jitterUV, float exposure,
                out float outHistoryDepth, out float debugValue) {
    // 诊断标量仅写主颜色的闲置 alpha，RGB / 历史 / 测光保持正常；默认档编译剔除。
    debugValue = 0.0; // 无历史 / 越界：深度拒绝，尚无可量化的历史钳制
#if TAA_DEBUG_VIEW == 2
    debugValue = 1.0; // 无历史 / 越界：全量当前帧
#endif
    vec2 viewSize = vec2(viewWidth, viewHeight);
#ifdef TAAU
    vec2 renderResF = floor(viewSize * EFFECTIVE_RENDER_SCALE + 0.5);
    ivec2 renderRes = ivec2(renderResF);
    // 光栅缩放取精确 S；整数有效区仅用于 tap 边界，不改变投影坐标尺度。
    // 与颜色重建共用完整补抖后的源位置。先选真实光栅样本，再对锚点去抖；
    // 先在无抖动位置选深度会在轮廓处误选另一表面，令历史置信度随相位翻转。
    vec2 sourcePosition = uv * viewSize * EFFECTIVE_RENDER_SCALE + jitterUV * viewSize;
    ivec2 renderPixel = clamp(ivec2(floor(sourcePosition)), ivec2(0), renderRes - 1);
#else
    ivec2 renderRes = ivec2(viewSize);
    ivec2 renderPixel = pixel;
#endif
#ifdef VOXY
    vec3 anchorViewPos;
    bool isSky, isHand;
    vec3 closest = closestVoxyDepthCross(renderPixel, renderRes, jitterUV, anchorViewPos, isSky, isHand);
#else
    vec3 closest = closestDepthCross(renderPixel, texelFetch(depthtex0, renderPixel, 0).r, renderRes);
    bool isSky = closest.z >= 1.0;
    bool isHand = closest.z < TAA_HAND_DEPTH;
#endif
    TaaNeighborhood stats;
    float upsampleConfidence = 1.0;
#ifdef TAAU
    // applyTAAJitter 在缩放后平移完整 jitter；源色采样必须等量补偿，半补偿会留下相位漂移。
    vec3 current = taaReconstruct(sourcePosition, renderRes, exposure, stats, upsampleConfidence);
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
#ifndef VOXY
    vec3 anchorViewPos = screenToView(vec3(anchorUV, closest.z));
#endif
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
    // 仅一套历史深度区间确认；关宏时不采历史深度，纯颜色回退。
    float depthConf = 1.0;
#ifdef TAAU_DEPTH_RANGE_CLIP
    depthConf = taaHistoryDepthRangeConfidence(historyUV, viewSize, expectedDepth, isSky);
#endif
#ifndef TAA_FIXED_BLEND
    float velocityPx = length(velocity * viewSize);
    float motion = smoothstep(TAA_MOTION_LOW, TAA_MOTION_HIGH, velocityPx);
#endif
#if defined(TAAU) && defined(TAA_FIXED_BLEND) && defined(TAAU_DEPTH_RANGE_CLIP)
    // 手部没有逐物体速度，保留颜色硬盒，不按宽深度区间放松。
    if (!isHand) taaRelaxDepthValidatedBounds(stats, depthConf);
#endif
    vec3 historyLinear;
    if (isSky) historyLinear = textureLod(colortex3, historyUV, 0.0).rgb;
    else historyLinear = catmullRom5(colortex3, historyUV, viewSize, TAA_HISTORY_SHARPNESS).rgb;
    vec3 history = rgbToYCoCg(taaTonemap(max(historyLinear, vec3(0.0)) * exposure));
#if TAA_DEBUG_VIEW == 3 || TAA_DEBUG_VIEW == 4
    vec3 unrectifiedHistory = history;
#endif
#if TAA_DEBUG_VIEW == 4 || TAA_DEBUG_VIEW == 5
    // 与两档修正函数的第一步一致，诊断不改变实际颜色 / 累积。
    vec3 hardBoundedHistory = taaBoundHistory(history, stats.lo, stats.hi);
#endif
#ifdef TAA_FIXED_BLEND
    history = taaRectifyFixedHistory(history, stats);
#else
    float clipDistance;
    history = taaRectifyHistory(history, stats, depthConf, motion, clipDistance);
#endif
#ifdef TAAU
    float blendBase = TAAU_BLEND_BASE;
#else
    float blendBase = TAA_BLEND_BASE;
#endif
#ifdef TAA_FIXED_BLEND
    float blend = blendBase;
#ifdef TAAU_DEPTH_RANGE_CLIP
    // 完全深度失配时直接当前帧；通过时仍是固定 3%，中间区间平滑过渡。
    blend = mix(blendBase, 1.0, 1.0 - depthConf);
#endif
#else
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
#endif
#if TAA_DEBUG_VIEW == 1
    debugValue = depthConf;
#elif TAA_DEBUG_VIEW == 2
    debugValue = clamp(blend, 0.0, 1.0);
#elif TAA_DEBUG_VIEW == 3
    debugValue = clamp(length(unrectifiedHistory - history) * TAA_DEBUG_CLIP_GAIN, 0.0, 1.0);
#elif TAA_DEBUG_VIEW == 4
    debugValue = clamp(length(unrectifiedHistory - hardBoundedHistory) * TAA_DEBUG_CLIP_GAIN, 0.0, 1.0);
#elif TAA_DEBUG_VIEW == 5
    debugValue = clamp(length(hardBoundedHistory - history) * TAA_DEBUG_CLIP_GAIN, 0.0, 1.0);
#endif
    vec3 resolved = mix(history, current, clamp(blend, 0.0, 1.0));
    return max(taaInverseTonemap(yCoCgToRgb(resolved)) / exposure, vec3(0.0));
}

#endif
#endif
