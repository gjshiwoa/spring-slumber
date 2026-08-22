// TAA 解析核心（composite_taa 专用），对应春雷 lib/post/taa.glsl + 春v2 lib/antialiasing/TAA.glsl 的合体精简：
// 深度重投影（无速度缓冲，3×3 最近片元锚点）+ Reinhard 域 YCoCg 方差钳制（μ±γσ）+ 速度 / 解遮挡自适应混合，
// 历史 a 通道存上帧最近片元线性深度做解遮挡置信（itrp / itt3.2 同款打包位，不占独立缓冲）
// 天空与几何同路径（无早退、吃满时间过滤）：deferred_init 已按当前帧 jitter 亚像素求值天空（与几何
// vsh 抖动同相位），本 pass 时间累积把 16 相位采样解析成亚像素抗锯齿——大气地平线高频边界不再锯齿；
// 天空锚点重投影取无穷远方向仅旋转链（space.glsl viewDirectionToPreviousScreen，相机平移对无穷远无效），
// 线性深度取哨兵值进置信公式（天空 -> 天空 |Δ|=0 满置信、天空 <-> 几何相对差巨大自然归零，免分支）
// 性能设计：锚点观察空间位置只重建一次（linearDepth 与重投影共用）、prevDepth 随 catmullRom5 的
// a 通道一趟带回（省独立采样）、采样全部 textureLod 0（免隐式导数路径）；方差统计与最近深度扫描
// 均为十字 5-tap（各省 4 fetch，统计盒略粗由 γ 抬一档补偿）；十字不含对角，仅对角有几何的单像素
// 角点（叶尖等）保护带缺角，c13 / Photon 同款取舍：全像素统一最坏 1+5+5+5 = 16 fetch
// 钳制域曝光归一化（春雷同思路）：统计 / 钳制 / 混合在「线性色 × 上一帧自适应曝光」的工作域进行、
// 结果除回后输出与存储——本管线曝光在 final 才应用（tonemap 前乘一次），colortex0 的原始值在
// 暗景下极小，tonemap c/(1+luma) 近似恒等、σ 跌破 extents 的 1e-5 地板会使钳制盒退化成「不钳」→
// 历史以 95% 权重原样存活 → 低亮度拖影；乘曝光后工作域稳定在 ~0.2-1，与场景亮度无关
// 依赖先行 include：constants.glsl（TAA_* 常量）、uniforms.glsl（colortex0/3、depthtex0、视口、
// cameraPosition 系与 previous 系矩阵）、utils/color.glsl（rgbToYCoCg / yCoCgToRgb）、
// filters.glsl（catmullRom5）、utils/space.glsl（screenToView / viewToRelativeWorld /
// relativeWorldToPreviousScreen / viewDirectionToPreviousScreen）；
// 当前帧 jitter 补偿量与曝光系数均由调用方传参（composite_taa 经 varying）
// 整体包裹 STAGE_FRAGMENT：解析逻辑仅片段阶段需要，vsh 编译串不再解析（对齐春雷 fsh-only 代码的入口包裹法）
#ifndef LIB_POST_TAA_GLSL
#define LIB_POST_TAA_GLSL
#ifdef STAGE_FRAGMENT

// ---------------- 深度与重投影 ----------------

// 十字 5-tap 偏移（最近深度扫描与方差统计共用）
const ivec2 taaCrossOffsets[4] = ivec2[4](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));

// 十字 5-tap 最近深度片元（c13 closestToCamera5taps / Photon get_closest_fragment 同形；越界 texel 钳回边缘），
// 重投影锚点取最近片元，避免边缘处前景 / 背景速度串扰；返回值 z >= 1 即十字全空（纯天空内部，
// 调用方切换无穷远方向重投影）；中心深度由调用方传入（免重复 fetch）；不含对角——仅对角有几何的
// 单像素角点不受保护（同上取舍）
vec3 closestDepthCross(ivec2 pixel, float centerDepth) {
    ivec2 resolution = ivec2(viewWidth, viewHeight);
    ivec2 bounds = resolution - 1;
    ivec2 closestPixel = pixel;
    float closestDepth = centerDepth;

    for (int i = 0; i < 4; i++) {
        ivec2 samplePixel = clamp(pixel + taaCrossOffsets[i], ivec2(0), bounds);
        float sampleDepth = texelFetch(depthtex0, samplePixel, 0).r;
        if (sampleDepth < closestDepth) {
            closestPixel = samplePixel;
            closestDepth = sampleDepth;
        }
    }

    return vec3((vec2(closestPixel) + 0.5) / vec2(resolution), closestDepth);
}

// 观察空间 -> 上一帧 uv：space.glsl 通用链的组合（viewToRelativeWorld -> relativeWorldToPreviousScreen，
// 观察逆推相对世界、平移相机增量、上一帧正推裁剪，参考包通用链）；isHand 时相机位移清零——手随相机
// 运动（BSL / Photon 同取舍）；viewPos 由调用方重建一次共用；天空（无穷远）改走 viewDirectionToPreviousScreen
vec2 reprojectViewToPreviousUV(vec3 viewPos, bool isHand) {
    vec3 cameraDelta = isHand ? vec3(0.0) : cameraPosition - previousCameraPosition;
    return relativeWorldToPreviousScreen(viewToRelativeWorld(viewPos), cameraDelta);
}

// ---------------- 钳制域（Reinhard + YCoCg）----------------

// 压缩 HDR 进 [0,1) 再做统计 / 钳制，抑制 firefly 与高亮闪烁（春雷 / 春v2 / c13 同款）；
// luma 取 color.glsl 通用 YCoCg 变换的 Y 分量——tonemap 分母与钳制域统计结构共享一套系数，
// 未用的 Co/Cg 由编译器消除；YCoCg 正逆变换本体在 utils/color.glsl（通用化，denoise / SSR 方差估计可复用）
float taaLuma(vec3 color) {
    return rgbToYCoCg(color).x;
}

vec3 taaTonemap(vec3 color) {
    return color / (1.0 + taaLuma(color));
}

vec3 taaInverseTonemap(vec3 color) {
    return color / max(1.0 - taaLuma(color), 1e-5);
}

// 历史钳制：十字 5-tap（中心 + 上下左右）当前帧统计 μ / σ，历史超出 μ±γσ 的部分截到盒面
//（保方向的 clipAABB，春雷 / 春v2 同款；比逐通道 clamp 少丢色相）；较 3×3 省 4 次 fetch，
// 盒略粗由 γ 抬一档补偿（TAA_CLIP_GAMMA 1.5）；stats 样本与入参历史色均已在曝光归一化工作域
vec3 clipHistoryToNeighborhood(vec3 historyColor, ivec2 pixel, float clipGamma, float exposure) {
    ivec2 bounds = ivec2(viewWidth, viewHeight) - 1;

    vec3 centerColor = rgbToYCoCg(taaTonemap(texelFetch(colortex0, pixel, 0).rgb * exposure));
    vec3 m1 = centerColor;
    vec3 m2 = centerColor * centerColor;
    for (int i = 0; i < 4; i++) {
        vec3 sampleColor = rgbToYCoCg(taaTonemap(texelFetch(colortex0, clamp(pixel + taaCrossOffsets[i], ivec2(0), bounds), 0).rgb * exposure));
        m1 += sampleColor;
        m2 += sampleColor * sampleColor;
    }

    const float count = 5.0;
    vec3 mu = m1 / count;
    vec3 sigma = sqrt(max(m2 / count - mu * mu, 0.0));
    vec3 aabbMin = mu - clipGamma * sigma;
    vec3 aabbMax = mu + clipGamma * sigma;

    // Y 通道上界帽（tonemap 值域 [0,1)）：高对比边缘双峰统计的 μ+γσ 可越出 1，截到盒面的落点
    // Y 会 > 1，逆变换分母 (1−Y) 变负、被 1e-5 地板钳住后放大 1e5 倍——物体边缘极亮爆闪的根源
    aabbMax.x = min(aabbMax.x, TAA_TONEMAP_DOMAIN_MAX);

    vec3 clipped = rgbToYCoCg(taaTonemap(historyColor));
    vec3 center = 0.5 * (aabbMax + aabbMin);
    vec3 extents = max(0.5 * (aabbMax - aabbMin), vec3(1e-5));

    vec3 clipVector = clipped - center;
    vec3 unit = abs(clipVector / extents);
    float maxUnit = max(unit.x, max(unit.y, unit.z));
    if (maxUnit > 1.0) clipped = center + clipVector / maxUnit;

    return taaInverseTonemap(yCoCgToRgb(clipped));
}

// ---------------- 解析主入口 ----------------

// 读当前线性 colortex0 + depthtex0，重投影采 colortex3 历史，钳制混合后返回新颜色（已除回归一化曝光）；
// outHistoryDepth 输出本帧最近片元线性深度（随颜色一起写进历史 a 通道供下帧置信比对）；
// exposure 为上一帧自适应曝光（调用方经 varying 传入），仅作钳制域归一化、不影响输出 / 存储的亮度
vec3 resolveTAA(vec2 uv, ivec2 pixel, vec2 jitterUV, float exposure, out float outHistoryDepth) {
    // 天空（closest.z >= 1：中心与十字邻域全无几何）不早退、与几何同路径时间累积——deferred_init 的
    // 天空已按当前帧 jitter 亚像素求值（与几何抖动同相位），16 相位采样经累积解析成亚像素抗锯齿，
    // 消除大气地平线高频边界的锯齿；重投影切换无穷远方向仅旋转链，锚点线性深度取哨兵——
    // 天空 -> 天空 |Δ| = 0 满置信、天空 <-> 几何相对差巨大自然归零，置信公式与几何路径同一条。
    // 边缘像素因 jitter 逐帧在天空 / 几何间翻转，由最近片元锚点自然落到几何路径（邻域膨胀），
    // 高对比轮廓以邻域几何为锚做时间累积、不闪烁爬行
    float centerDepth = texelFetch(depthtex0, pixel, 0).r;
    vec3 closest = closestDepthCross(pixel, centerDepth);
    bool isSky = closest.z >= 1.0;
    bool isHand = closest.z < TAA_HAND_DEPTH;
    // 当前帧：半 jitter 补偿采样（c13 / Bliss 同款；几何 +jitter 后像素含 center+j 处场景，
    // 采样向 jitter 方向偏一半，在抗锯齿收敛与锐度间折中）；textureLod 0 免隐式导数路径；
    // 乘曝光进归一化工作域（钳制 / 混合在此域进行）
    vec3 currentColor = textureLod(colortex0, uv + jitterUV * 0.5, 0.0).rgb * exposure;

    // 锚点观察空间位置只重建一次：线性深度与重投影共用（原先各做一次 mat4 乘 + 透视除）；
    // 天空锚点落在远平面（z = 1），该位置同时就是无穷远方向的载体
    vec3 anchorViewPos = screenToView(vec3(closest.xy, closest.z));
    float linearDepth = isSky ? TAA_DEPTH_SENTINEL : min(-anchorViewPos.z, TAA_DEPTH_SENTINEL);
    outHistoryDepth = linearDepth;

    // 速度：锚点（十字 5-tap 最近片元）只提供位移量，速度作用在当前像素坐标上——历史采样位 = uv − velocity
    //（c13 / 春雷 / 春v2 同款）；若直接用锚点自身的前帧位置采样，会带入「锚点 − 中心」的固定像素偏移，
    // 静止场景即出现整片邻色拖痕、锚点随 jitter 翻转时闪烁；天空锚点走无穷远方向链（仅旋转）——
    // 大气渐变挂在视线方向上，旋转精确、平移误差可忽略（方差钳制兜底）
    vec2 prevUv = isSky ? viewDirectionToPreviousScreen(anchorViewPos)
                        : reprojectViewToPreviousUV(anchorViewPos, isHand);
    vec2 velocity = closest.xy - prevUv;
    vec2 historyUv = uv - velocity;

    // 屏幕外或首帧时直接采用当前帧，避免无意义的历史采样与边界 clamp。
    bool offscreen = any(lessThan(historyUv, vec2(0.0))) || any(greaterThan(historyUv, vec2(1.0)));
    if (offscreen || frameCounter == 0) {
        return max(currentColor / exposure, vec3(0.0));
    }

    // 解遮挡置信：颜色历史使用 Catmull-Rom，但深度必须独立最近采样。
    // Catmull-Rom 的负权重会让天空哨兵值 / 几何深度在边缘过冲，不能把 history.a 当真实深度。
    ivec2 resolution = ivec2(viewWidth, viewHeight);
    ivec2 historyPixel = clamp(ivec2(historyUv * vec2(viewWidth, viewHeight)), ivec2(0), resolution - 1);
    float historyDepth = texelFetch(colortex3, historyPixel, 0).a;
    bool historySky = historyDepth >= TAA_DEPTH_SENTINEL * 0.999;

    float velocityPx = length(velocity * vec2(viewWidth, viewHeight));
    vec4 history = catmullRom5(colortex3, historyUv, vec2(viewWidth, viewHeight), TAA_HISTORY_SHARPNESS);
    float depthConf;
    if (isSky != historySky) {
        depthConf = 0.0;
    } else if (isSky) {
        depthConf = 1.0;
    } else {
        depthConf = 1.0 - smoothstep(TAA_DEPTH_CONF_EDGE0, TAA_DEPTH_CONF_EDGE1, abs(linearDepth - historyDepth) / max(linearDepth, 1e-4));
    }

    // 方差钳制；置信度低时放宽 γ 防鬼影（春雷自适应同思路）；历史 rgb 乘曝光进工作域（a 为深度不乘）
    float clipGamma = mix(TAA_CLIP_GAMMA_MAX, TAA_CLIP_GAMMA, depthConf);
    vec3 historyWorking = clipHistoryToNeighborhood(history.rgb * exposure, pixel, clipGamma, exposure);

    // 当前帧权重：基础 + 运动收敛 + 解遮挡收敛（春v2 低配版混合公式思路）
    float blend = TAA_BLEND_BASE + velocityPx * TAA_BLEND_MOTION + (1.0 - depthConf) * TAA_BLEND_DISOCCCLUSION;
    blend = clamp(blend, TAA_BLEND_MIN, 1.0);
    if (isHand) blend = max(blend, TAA_BLEND_HAND_MIN); // 手部历史快收敛，防视角摆动拖影

    // 屏幕外或首帧已在历史采样前直接采用当前帧。

    // 除回归一化曝光：输出与历史存储均回到未曝光的线性域（曝光由 final 统一应用）
    return max(mix(historyWorking, currentColor, blend) / exposure, vec3(0.0));
}

#endif
#endif
