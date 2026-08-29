// TAA 解析核心（composite_taa 专用），春雷 + 春v2 的合体精简：
// 深度重投影（无速度缓冲，十字最近片元锚点）+ Reinhard 域 YCoCg 方差钳制（μ±γσ）+ 速度 / 解遮挡
// 自适应混合；历史 a 通道存上帧最近片元线性深度做解遮挡置信（不占独立缓冲）
// 天空与几何同路径（无早退、吃满时间过滤）：deferred_init 已按当前帧 jitter 亚像素求值天空，
// 本 pass 时间累积把 16 相位采样解析成亚像素抗锯齿；天空锚点走无穷远方向仅旋转重投影、线性深度
// 取哨兵进同一置信公式（天空↔天空满置信、天空↔几何自然归零，免分支）
// 钳制域曝光归一化（春雷同思路）：统计 / 钳制 / 混合在「线性色 × 上一帧自适应曝光」工作域进行、
// 结果除回——本管线曝光在 final 才应用，colortex0 暗景原始值极小、σ 跌破 epsilon 地板会使钳制盒
// 退化成不钳 → 低亮度拖影；乘曝光后工作域稳定在 ~0.2-1
// TAAU：几何渲染在左下 [0,S]² 子区域，本 pass quad 全屏、即上采样器——resolveTAA 把目标域 uv/pixel
// 换算为渲染域（见函数内注释），当前帧 catmullRom5 上采样与全屏历史混合后恢复全屏；S=1 时编译期
// 逐位退化为纯 TAA。性能：锚点位置单次重建、prevDepth 随 catmullRom5 a 通道一趟带回、采样全
// textureLod 0；统计与深度扫描均十字 5-tap（不含对角，c13 / Photon 同款取舍），最坏 16 fetch
//（TAAU 20），换来整段像素成本 ×S²
// 依赖先行 include：constants.glsl（TAA_*）、uniforms.glsl（colortex0/3、depthtex0、视口、
// cameraPosition 系与 previous 系矩阵）、utils/color.glsl、filters.glsl（catmullRom5）、
// utils/space.glsl（screenToView / viewToRelativeWorld / relativeWorldToPreviousScreen /
// viewDirectionToPreviousScreen）；jitter 补偿与曝光由调用方传参（composite_taa 经 varying）
// 整体包裹 STAGE_FRAGMENT：vsh 编译串不解析（对齐春雷 fsh-only 代码的入口包裹法）
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
// resolution 显式传入：TAAU 下 depthtex0 / colortex0 的有效区是左下 [0,S]² 渲染子区域，锚点十字
// 与邻域统计都须在渲染域分辨率内进行（S=1 时即 viewWidth/Height，恒等）；返回 xy 为渲染域 uv
//（视场归一化 [0,1]，与 screenToView / 重投影的域约定一致）
vec3 closestDepthCross(ivec2 pixel, float centerDepth, ivec2 resolution) {
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
// resolution 显式传入（TAAU 下为渲染域分辨率——统计十字采样子区域内的 colortex0；统计盒按
// 渲染像素间隔覆盖 ±1/S 目标像素、天然宽于原生档，γ 维持原值即够）
vec3 clipHistoryToNeighborhood(vec3 historyColor, ivec2 pixel, float clipGamma, float exposure, ivec2 resolution) {
    ivec2 bounds = resolution - 1;

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
    // TAAU 域换算：入参 uv / pixel 为全屏目标域（本 pass quad 全屏），几何渲染在 buffer 左下
    // [0,S]² 子区域——renderResF = floor(视口 × S) 即子区域 buffer 像素数（一个渲染像素 = 子区域内
    // 一个 buffer 像素）。深度 / 统计十字的渲染域纹素 renderPixel：目标像素 x 的邻域锚点在渲染纹素
    // x·S 处（renderPixel = ivec2(uv × renderResF)）；重投影链走 closest.xy（渲染视场域归一化）、
    // 与 prevUv 数值域一致直接相减。S=1 时 renderPixel == pixel、上采样分支编译期不含，纯 TAA 逐位退化
#ifdef TAAU
    vec2 renderResF = floor(vec2(viewWidth, viewHeight) * RENDER_SCALE);
    ivec2 renderRes = ivec2(renderResF);
    ivec2 renderPixel = clamp(ivec2(uv * renderResF), ivec2(0), renderRes - 1);
#else
    ivec2 renderRes = ivec2(viewWidth, viewHeight);
    ivec2 renderPixel = pixel;
#endif

    // 天空（closest.z >= 1：十字全空）不早退、与几何同路径时间累积（16 相位采样解析成亚像素抗锯齿，
    // 消除大气地平线高频边界锯齿）；重投影切换无穷远方向仅旋转链、锚点线性深度取哨兵（同一条置信
    // 公式）；边缘像素因 jitter 在天空 / 几何间翻转，由最近片元锚点邻域膨胀落到几何路径、不闪烁爬行
    float centerDepth = texelFetch(depthtex0, renderPixel, 0).r;
    vec3 closest = closestDepthCross(renderPixel, centerDepth, renderRes);
    bool isSky = closest.z >= 1.0;
    bool isHand = closest.z < TAA_HAND_DEPTH;
    // 当前帧：半 jitter 补偿采样（几何 +jitter 后像素含 center+j 处场景，采样向 jitter 方向偏一半——
    // 抗锯齿收敛与锐度折中，c13 / Bliss 同款）；乘曝光进归一化工作域。
    // TAAU 上采样（Photon 同构）：采样 uv =（目标域 uv + 半 jitter 补偿）× S 压进子区域纹理域，
    // catmullRom5 的 texSize 必须传**纹理真实尺寸**（viewWidth/Height——函数内部 position = uv×texSize
    // 定位纹素、tc = center/texSize 回纹理域；误传渲染分辨率会与未乘 S 的 uv 相抵消、退化成全屏域
    // 恒等映射采到子区域外旧帧残留），采样 uv 乘 S 后自动把目标像素 x 落位 x·S 渲染纹素（即放大
    // S 倍）；钳进子区域边缘 0.75 渲染 texel，核半径 2 texel 的越界 tap 由引擎 clamp-to-edge 兜底
    //（边缘纹素重复采样、无垃圾读入）。与全屏历史（colortex3）混合、时间累积恢复超渲染分辨率细节
#ifdef TAAU
    vec2 upsampleUV = clamp((uv + jitterUV * 0.5) * RENDER_SCALE,
                            0.75 / vec2(viewWidth, viewHeight),
                            RENDER_SCALE - 0.75 / vec2(viewWidth, viewHeight));
    vec3 currentColor = catmullRom5(colortex0, upsampleUV,
                                    vec2(viewWidth, viewHeight),
                                    TAAU_UPSAMPLE_SHARPNESS).rgb * exposure;
#else
    vec3 currentColor = textureLod(colortex0, uv + jitterUV * 0.5, 0.0).rgb * exposure;
#endif

    // 锚点观察空间位置只重建一次：线性深度与重投影共用（原先各做一次 mat4 乘 + 透视除）；
    // 天空锚点落在远平面（z = 1），该位置同时就是无穷远方向的载体
    vec3 anchorViewPos = screenToView(vec3(closest.xy, closest.z));
    float linearDepth = isSky ? TAA_DEPTH_SENTINEL : min(-anchorViewPos.z, TAA_DEPTH_SENTINEL);
    outHistoryDepth = linearDepth;

    // 速度：锚点只提供位移量、作用在当前像素坐标上（历史采样位 = uv − velocity，c13 / 春雷 / 春v2
    // 同款——若直接用锚点自身前帧位置采样，会带入「锚点 − 中心」的固定偏移，静止场景出邻色拖痕）；
    // 天空锚点走无穷远方向链（旋转精确、平移误差可忽略，方差钳制兜底）。TAAU 域自洽：closest.xy
    //（渲染域视场归一化）与 prevUv（上帧视场归一化）数值域一致直接相减；velocityPx 用全屏像素
    // 量纲时同一物理运动的速度值与 S=1 相同、混合阈值语义不变
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
    vec3 historyWorking = clipHistoryToNeighborhood(history.rgb * exposure, renderPixel, clipGamma, exposure, renderRes);

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
