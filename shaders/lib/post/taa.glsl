// TAA 解析核心（composite_taa 专用），春雷 + 春v2 的合体精简：
// 深度重投影（无速度缓冲，十字最近片元锚点）+ Reinhard 域 YCoCg 方差钳制（μ±γσ ∩ 邻域样本
// 极值）+ 速度 / 解遮挡
// 自适应混合；历史 a 通道存上帧最近片元线性深度做解遮挡置信（不占独立缓冲）
// 天空与几何同路径（无早退、吃满时间过滤）：deferred_init 已按当前帧 jitter 亚像素求值天空，
// 本 pass 时间累积把 32 相位采样解析成亚像素抗锯齿；天空锚点走无穷远方向仅旋转重投影、线性深度
// 取哨兵进同一置信公式（天空↔天空满置信、天空↔几何自然归零，免分支）
// 钳制域曝光归一化（春雷同思路）：统计 / 钳制 / 混合在「线性色 × 上一帧自适应曝光」工作域进行、
// 结果除回——本管线曝光在 final 才应用，colortex0 暗景原始值极小、σ 跌破 epsilon 地板会使钳制盒
// 退化成不钳 → 低亮度拖影；乘曝光后工作域稳定在 ~0.2-1
// TAAU：几何渲染在左下 [0,S]² 子区域，本 pass quad 全屏、即上采样器——resolveTAA 把目标域 uv/pixel
// 换算为渲染域（见函数内注释），当前帧 catmullRom5 上采样做半抖去抖（c13 / Kappa / Photon 三家一致）
// 后与全屏历史混合恢复全屏；混合链 = 基础权重 → 上采样置信度门控（UE 最大核权重法）→
// Karis 距离防闪（稳定区等效注入压到 ~0）→ 偏心拒绝（运动中抬当前帧），S=1 时编译期逐位退化为
// 纯 TAA。性能：锚点位置单次重建、prevDepth 随
// catmullRom5 a 通道一趟带回、采样全
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

// 历史钳制：十字 5-tap（中心 + 上下左右）当前帧统计 μ / σ 并取样本极值，历史超出「μ±γσ ∩
// 样本极值」盒的部分截到盒面
//（保方向的 clipAABB，春雷 / 春v2 同款；比逐通道 clamp 少丢色相）；较 3×3 省 4 次 fetch，
// 盒略粗由 γ 抬一档补偿（TAA_CLIP_GAMMA 1.75）；stats 样本与入参历史色均已在曝光归一化工作域
// outClipDistance：Karis「距盒边距离」∈ [0,1]（Kappa / Photon 同式）——历史被截 → 0（与当前
// 邻域不符，当前帧正常注入收敛）；稳居盒内 → 1（与当前邻域一致，调用方据此把当前帧权重压向 0
// 防闪）。工作域已含曝光归一化，距离直接乘增益、不再乘曝光
// resolution 显式传入：TAAU 下为渲染域分辨率——统计十字采样子区域内的 colortex0；统计盒按
// 渲染像素间隔覆盖 ±1/S 目标像素、天然宽于原生档，γ 维持原值即够
vec3 clipHistoryToNeighborhood(vec3 historyColor, ivec2 pixel, float clipGamma, float exposure, ivec2 resolution,
                                out float outClipDistance) {
    ivec2 bounds = resolution - 1;

    vec3 centerColor = rgbToYCoCg(taaTonemap(texelFetch(colortex0, pixel, 0).rgb * exposure));
    vec3 m1 = centerColor;
    vec3 m2 = centerColor * centerColor;
    vec3 sampleMin = centerColor;
    vec3 sampleMax = centerColor;
    for (int i = 0; i < 4; i++) {
        vec3 sampleColor = rgbToYCoCg(taaTonemap(texelFetch(colortex0, clamp(pixel + taaCrossOffsets[i], ivec2(0), bounds), 0).rgb * exposure));
        m1 += sampleColor;
        m2 += sampleColor * sampleColor;
        sampleMin = min(sampleMin, sampleColor);
        sampleMax = max(sampleMax, sampleColor);
    }

    const float count = 5.0;
    vec3 mu = m1 / count;
    vec3 sigma = sqrt(max(m2 / count - mu * mu, 0.0));
    vec3 aabbMin = mu - clipGamma * sigma;
    vec3 aabbMax = mu + clipGamma * sigma;
    // 方差盒 ∩ 邻域样本极值盒（Kappa / Photon 的 AABB 即取样本 min/max）：Reinhard 压缩后亮色
    // Y→1 渐近，天空 / 物体边缘的双峰统计把 μ+γσ 撑得比全邻域都亮的历史还宽（Y 侧永远不绑定），
    // 历史 / 上采样重采样负瓣的过冲会逐帧累积成轮廓极亮像素——交上样本极值后历史以「当前邻域
    // 最亮真实样本」为上界，数据驱动、无全局亮度帽（原 0.995 常数帽会把工作域 luma ≳ 200 的亮部
    // 系统性压暗且拖色相，已删）；γ 随深度置信的放宽仍在样本范围内生效。clip 落点是 center 与
    // 历史 tonemap 值的凸组合、两端 Y 恒 < 1，逆变换分母恒正（1e-5 地板只为 Y→1⁻ 的极端亮部兜底）
    aabbMin = max(aabbMin, sampleMin);
    aabbMax = min(aabbMax, sampleMax);

    vec3 clipped = rgbToYCoCg(taaTonemap(historyColor));
    vec3 center = 0.5 * (aabbMax + aabbMin);
    vec3 extents = max(0.5 * (aabbMax - aabbMin), vec3(1e-5));

    vec3 clipVector = clipped - center;
    vec3 unit = abs(clipVector / extents);
    float maxUnit = max(unit.x, max(unit.y, unit.z));
    bool clippedToBox = maxUnit > 1.0;
    if (clippedToBox) clipped = center + clipVector / maxUnit;

    vec3 toBoxEdge = min(clipped - aabbMin, aabbMax - clipped);
    outClipDistance = clippedToBox ? 0.0 : clamp(length(toBoxEdge) * TAA_CLIP_DISTANCE_GAIN, 0.0, 1.0);

    return taaInverseTonemap(yCoCgToRgb(clipped));
}

// ---------------- 解析主入口 ----------------

// 上采样置信度（UE「最大核权重」法，Photon catmull_rom_filter 的 confidence 同式）：f 与
// catmullRom5 内部 f = fract(position − 0.5) 同源；采样位在纹素中心 → 1（采到「真像素」）、
// 纹素角点 → ~0.32（纯插值过渡、两帧间随相位漂移的人造值）。用标准 Catmull-Rom 权重族即可——
// 锐化参数只改权重分布、不动「离纹素中心越近越可信」的单调性，数值略保守无碍
float catmullConfidence(vec2 f) {
    vec2 f2 = f * f;
    vec2 f3 = f2 * f;
    vec2 w0 = -0.5 * f  + f2 - 0.5 * f3;
    vec2 w1 =  1.0 - 2.5 * f2 + 1.5 * f3;
    vec2 w2 =  0.5 * f  + 2.0 * f2 - 1.5 * f3;
    vec2 w3 = -0.5 * f2 + 0.5 * f3;
    return max(max(w0.x, w1.x), max(w2.x, w3.x))
         * max(max(w0.y, w1.y), max(w2.y, w3.y));
}

// 读当前线性 colortex0 + depthtex0，重投影采 colortex3 历史，钳制混合后返回新颜色（已除回归一化曝光）；
// outHistoryDepth 输出本帧最近片元线性深度（随颜色一起写进历史 a 通道供下帧置信比对）；
// exposure 为上一帧自适应曝光（调用方经 varying 传入），仅作钳制域归一化、不影响输出 / 存储的亮度
vec3 resolveTAA(vec2 uv, ivec2 pixel, vec2 jitterUV, float exposure, out float outHistoryDepth) {
    // TAAU 域换算：入参 uv / pixel 为全屏目标域（本 pass quad 全屏），几何渲染在 buffer 左下
    // [0,S]² 子区域——renderResF = round(视口 × S) 即子区域 buffer 像素数（一个渲染像素 = 子区域内
    // 一个 buffer 像素）。取 round 对齐 quad 光栅实际覆盖：像素中心规则下覆盖 p ≤ W·S − 0.5、
    // 列数 = round(W·S)；取 floor 会在 W·S 非整数（窗口宽高非 4 倍数）时比实际少 1 列，该列被
    // 几何 / deferred_init 写入、锚点与统计十字却永远读不到。深度 / 统计十字的渲染域纹素
    // renderPixel：目标像素 x 的邻域锚点在渲染纹素 x·S 处（renderPixel = ivec2(uv × renderResF)）；
    // 重投影链走 closest.xy（渲染视场域归一化）、与 prevUv 数值域一致直接相减。S=1 时
    // renderPixel == pixel、上采样分支编译期不含，纯 TAA 逐位退化
#ifdef TAAU
    vec2 renderResF = floor(vec2(viewWidth, viewHeight) * RENDER_SCALE + 0.5);
    ivec2 renderRes = ivec2(renderResF);
    ivec2 renderPixel = clamp(ivec2(uv * renderResF), ivec2(0), renderRes - 1);
#else
    ivec2 renderRes = ivec2(viewWidth, viewHeight);
    ivec2 renderPixel = pixel;
#endif

    // 天空（closest.z >= 1：十字全空）不早退、与几何同路径时间累积（32 相位采样解析成亚像素抗锯齿，
    // 消除大气地平线高频边界锯齿）；重投影切换无穷远方向仅旋转链、锚点线性深度取哨兵（同一条置信
    // 公式）；边缘像素因 jitter 在天空 / 几何间翻转，由最近片元锚点邻域膨胀落到几何路径、不闪烁爬行
    float centerDepth = texelFetch(depthtex0, renderPixel, 0).r;
    vec3 closest = closestDepthCross(renderPixel, centerDepth, renderRes);
    bool isSky = closest.z >= 1.0;
    bool isHand = closest.z < TAA_HAND_DEPTH;
    // 当前帧：TAAU 走上采样（几何 +jitter 后像素含 center+j 处场景）；乘曝光进归一化工作域。
    // **半抖去抖（c13 / Kappa / Photon 三家一致）**：applyTAAJitter 在子区域缩放**之后**的 NDC 域
    // 注入 jitter，换算到 buffer 域的有效位移 = ±0.5 渲染纹素、与 S 无关（三家参考同语义）；解析端
    // 只补偿一半（uv·S + jitterUV·0.5，buffer 纹素域）——catmull 负瓣响应对采样相位高度敏感，
    // 全额去抖每帧「精确对齐」的样本携带完整相位噪声（静止高频抖动主源），半抖把帧间相位变化
    // 减半、保留的半个相位差经时间累积解析成 AA / 超分信息（与原生档半抖补偿同语义，两分支对齐）。
    // 注意半抖的正确写法是补偿加在 uv·S **之后**——旧式 (uv + jitterUV·0.5)·S 把补偿一并乘了 S，
    // S=0.5 时只剩全额的 1/4、每帧系统性错位。catmullRom5 的 texSize 传**纹理真实尺寸**
    //（viewWidth/Height——函数内部 position = uv×texSize 定位纹素；误传渲染分辨率会退化为全屏域
    // 恒等映射采到子区域外旧帧残留）；钳进子区域边缘 0.25 buffer texel——左 / 下缘即缓冲边缘，
    // 核半径 2 texel 的越界 tap 由引擎 clamp-to-edge 兜底（与 S=1 同款），右 / 上缘越界 tap 落进
    // 缓冲内上帧 TAA 残留（同视场位置、内容≈本帧）。余量刻意小：最左列目标像素的采样位低至
    // 0.25·S ≈ 0.19 buffer texel，边距 0.75 会让该列恒触底钳、相位压成定点失去时间抗锯齿
#ifdef TAAU
    vec2 upsampleUV = clamp(uv * RENDER_SCALE + jitterUV * 0.5,
                            0.25 / vec2(viewWidth, viewHeight),
                            RENDER_SCALE - 0.25 / vec2(viewWidth, viewHeight));
    vec3 currentColor = catmullRom5(colortex0, upsampleUV,
                                    vec2(viewWidth, viewHeight),
                                    TAAU_UPSAMPLE_SHARPNESS).rgb * exposure;
    // 与上采样核同源的置信度（角点 ~0.32 / 中心 1），供混合链门控
    float upsampleConfidence = catmullConfidence(fract(upsampleUV * vec2(viewWidth, viewHeight) - 0.5));
#else
    // 原生档半 jitter 补偿（c13 / 春雷同款）：几何 +jitter 后像素含 center+j 处场景，采样向 jitter
    // 方向偏一半——抗锯齿收敛与锐度折中
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
    float clipDistance;
    float clipGamma = mix(TAA_CLIP_GAMMA_MAX, TAA_CLIP_GAMMA, depthConf);
    vec3 historyWorking = clipHistoryToNeighborhood(history.rgb * exposure, renderPixel, clipGamma, exposure, renderRes, clipDistance);

    // 当前帧权重混合链（顺序参照 Photon：地板先立、门控后压，门控允许压破地板）：
    // ① 基础 + 运动收敛 + 解遮挡收敛（春v2 低配版公式）——TAAU 基础与原生档同取 0.05（Kappa 同值）：
    //    当前帧样本是相位噪声的注入端、base 即注入下限，防闪靠后续两级门控在稳定区压等效注入
#ifdef TAAU
    float blendBase = TAAU_BLEND_BASE;
#else
    float blendBase = TAA_BLEND_BASE;
#endif
    float blend = blendBase + velocityPx * TAA_BLEND_MOTION + (1.0 - depthConf) * TAA_BLEND_DISOCCCLUSION;
    blend = clamp(blend, TAA_BLEND_MIN, 1.0);
    if (isHand) blend = max(blend, TAA_BLEND_HAND_MIN); // 手部历史快收敛，防视角摆动拖影

    // ② TAAU 置信度门控：上采样落在纹素角点（插值过渡）时当前帧降权趋零、细节交还时间累积——
    //    角点插值值随相位两帧间漂移，按基础权重恒定注入正是静止高频细节闪烁的来源
#ifdef TAAU
    blend *= pow(upsampleConfidence, TAAU_CONFIDENCE_POWER);
#endif

    // ③ Karis 距离防闪（Kappa / Photon 同款）：历史稳居钳制盒内 = 与当前邻域一致，当前帧权重压向
    //    0（纯历史、不再注入相位噪声）；被截 / 濒边时 clipDistance → 0、正常收敛。静止场景由此
    //    收敛到零闪烁，运动 / 解遮挡不受影响（历史被截即归零）
    blend *= 1.0 - clipDistance;

    // ④ 偏心拒绝（Zombye）：重投影落点偏离历史纹素中心（= 有运动、历史采样为插值）时按比例抬高
    //    当前帧权重，削运动拖影 / 运动糊；静止时偏心因子 = 1 恒等、原生档同样受益
    vec2 pixelOffset = 1.0 - abs(2.0 * fract(historyUv * vec2(viewWidth, viewHeight)) - 1.0);
    float offcenterFactor = sqrt(pixelOffset.x * pixelOffset.y) * TAA_OFFCENTER_REJECTION + (1.0 - TAA_OFFCENTER_REJECTION);
    blend = 1.0 - (1.0 - blend) * offcenterFactor;

    // 除回归一化曝光：输出与历史存储均回到未曝光的线性域（曝光由 final 统一应用）
    return max(mix(historyWorking, currentColor, blend) / exposure, vec3(0.0));
}

#endif
#endif
