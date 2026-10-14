// 屏幕空间反射 march（仅片段阶段；2026-10 自 lib/lighting/water.glsl 按功能拆分，git 历史含合并
// 形态）：**春雷 2D SSPT 移植**，2026-10 替换春v2 SSRT 指数步进 march。
// 移植自春雷 lib/lighting/screen_space_tracing.glsl 的 sstTrace 反射档（其 specular_screen_trace
// 消费——SSPT 家族的「2D」= 屏幕域步进，区别于其体素 3D PT；方案全文 plans/水面2DSSPT方案.md）：
// 视锥 clip 预裁剪 + 屏幕域均匀像素步进 + 屏域二分精修 + 命中验证（先精修后验证 + 方向一致性
// 信任因子，2026-10）+ 远平面兜底，替换原观察空间
// 指数步进 march（采样按屏幕覆盖分配——指数档把步数花在近场而远端步距拉成数百像素的缝隙；git
// 历史含完整形态）。命中输出 buffer 域 uv（TAAU 子区域 + jitter 折叠含于端点投影）；出渲染域 /
// 步数耗尽 / 验证失败返回 false（调用方回退天空）。
// 消费方：lib/water/surface.glsl（shadeWaterSurface 反射段——恒 march，曾在此处的 Fresnel 低值免
// march 门〔WATER_SSR_MIN_FRESNEL〕已按反馈移除〔2026-10，见 surface.glsl 反射段注〕）；命中段雾 = lib/water/reflection.glsl
// 的 waterReflectionHitFog（命中色雾化在反射侧完成，本文件只管追踪）。
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：constants.glsl（WATER_SSR_* /
// TAA_HAND_DEPTH / TAAU 的 EFFECTIVE_RENDER_SCALE）、uniforms.glsl（depthtex1 / gbufferProjection /
// viewWidth / viewHeight）、utils/noise.glsl（temporalBayer64 / applyJitter /
// applyInverseJitter——方向一致性验证的碰撞点去抖基底）、utils/space.glsl
//（screenToViewCanonical——方向一致性验证的碰撞点重建，2026-10 起）
// VOXY 另需 compat/voxy/scene.glsl：独立深度重建 / 最近不透明层；步进用负倒数视深。
#ifndef LIB_WATER_SSR_GLSL
#define LIB_WATER_SSR_GLSL

#ifdef STAGE_FRAGMENT

// 精确纹素深度采样（春雷 sstSampleCoord + sampleDepth1 同款）：连续坐标截断到纹素 + 钳边，
// texelFetch 免滤波歧义。入参 = **buffer 像素坐标**（2026-10 march 域像素化：waterSSR 端点一次
// ×viewport、每步 mix 直出像素坐标，免每步一次 uv×viewport 乘——线性映射与 mix 精确可交换，仅
// 浮点重结合的 ulp 级差异、由 bayer 相位 / TAA 吸收；shadeWaterSurface 命中深度取回处 ×viewport）
float waterSsrDepth(vec2 px) {
    ivec2 pixel = clamp(ivec2(px), ivec2(0), ivec2(viewWidth, viewHeight) - 1);
    float d = texelFetch(depthtex1, pixel, 0).r;
#ifdef VOXY
    // 手部不作 SSR 遮挡者：先剔除，免查两套深度与矩阵重建。
    if (d < TAA_HAND_DEPTH) return 1.0;
    vec2 jitterUv = taaJitterUV();
    vec2 fullUv = applyInverseJitter((vec2(pixel) + 0.5) / vec2(viewWidth, viewHeight), jitterUv);
    vec3 viewPos = screenToViewCanonical(fullUv, d);
    if (!voxyOpaqueBackgroundPosition(vec2(pixel) + 0.5, jitterUv, d, viewPos)) return 1.0;
    // 负倒数视深沿屏幕线段线性变化，保留远景精度，不压回原版 NDC 深度。
    return 1.0 / viewPos.z;
#else
    return d;
#endif
}
bool waterSsrValidDepth(float d) {
#ifdef VOXY
    return d < 0.0; // VOXY 档 = 负倒数视深；1 为无几何 / 手部。
#else
    return d < 1.0 && d >= TAA_HAND_DEPTH;
#endif
}
vec3 waterSsrViewPosition(vec2 bufferUv, float d, vec2 jitterUv) {
#ifdef VOXY
    // 直接用命中 buffer uv 选纹素，避免去抖再补抖的舍入跨越像素边界。
    vec2 bufferPx = bufferUv * vec2(viewWidth, viewHeight);
    ivec2 pixel = clamp(ivec2(bufferPx), ivec2(0), ivec2(viewWidth, viewHeight) - 1);
    float nativeDepth = texelFetch(depthtex1, pixel, 0).r;
    vec2 fullUv = applyInverseJitter((vec2(pixel) + 0.5) / vec2(viewWidth, viewHeight), jitterUv);
    vec3 viewPos = screenToViewCanonical(fullUv, nativeDepth);
    voxyOpaqueBackgroundPosition(vec2(pixel) + 0.5, jitterUv, nativeDepth, viewPos);
    return viewPos;
#else
    return screenToViewCanonical(applyInverseJitter(bufferUv, jitterUv), d);
#endif
}

// 命中验证（春雷 sstValidateHit 同式变体）：场景表面视深须落在「交点射线深 ±（整步跨度 × BIAS +
// TOLERANCE）」带内——前景剪影（表面远比射线更靠近相机）判伪命中拒收 = 屏幕空间反射边缘拉丝的
// 根治。**分子与带宽分置（2026-10 调序配套）**：分子 = 精修交点的穿透深 |rayD − sceneD|（连续表面随
// 亚像素区间收敛而减小）——旧序分子 = 候选过冲
//（随 bayer 相位均匀分布 [0, 步长]）⇒ residual 在 [0, 1/BIAS] 逐帧波动 = 命中 confidence 翻转
// 的反射噪点根源；带宽 = 整步跨度（bandLo / bandHi = 上一步 → 候选步的射线深）× `WATER_SSR_HIT_BIAS`
// + 固定松弛量 `WATER_SSR_HIT_TOLERANCE`，与旧序逐位同宽容度（剪影拒收阈值不变——曾试收敛区间
//〔1/16 步长〕作带宽的更严档被否：对掠射打到岸线 / 剪影边缘等深度不连续处的真命中过严）。
// TOLERANCE 春雷原档 0.05、按反馈多轮调参回落 0.1：过紧时命中判定在阈值边缘随 dither 相位逐帧
// 翻转即反射噪点。视深 = 前向距离（格），典则透视闭式（screenToViewCanonical 的 z 行取负，
// shadow.glsl 步内场化同款；projC / projD 由调用方传入）
float waterSsrHitConfidence(float rayDepthW, float bandLoZ, float bandHiZ, float sceneDepthW, float projC, float projD) {
#ifdef VOXY
    float rayD   = -1.0 / rayDepthW;
    float bandLo = -1.0 / bandLoZ;
    float bandHi = -1.0 / bandHiZ;
    float sceneD = -1.0 / sceneDepthW;
#else
    float rayD   = projD / (rayDepthW  * 2.0 - 1.0 + projC);
    float bandLo = projD / (bandLoZ    * 2.0 - 1.0 + projC);
    float bandHi = projD / (bandHiZ    * 2.0 - 1.0 + projC);
    float sceneD = projD / (sceneDepthW * 2.0 - 1.0 + projC);
#endif
    float band = abs(bandHi - bandLo) * WATER_SSR_HIT_BIAS + WATER_SSR_HIT_TOLERANCE;
    float residual = abs(rayD - sceneD) / max(band, 1e-5);
    return 1.0 - smoothstep(WATER_SSR_CONFIDENCE_START, 1.0, residual);
}

// 起点到碰撞点的方向一致性信任因子（2026-10 接入）：碰撞点 = 命中纹素 xy + 场景深度经
// screenToViewCanonical 重建的视空间点（与 surface.glsl 命中点重建同式同纹素、单真源一致）——
// 真实命中时表面交点即射线与表面的公共点，重建点必在射线路径近旁（偏差 = 深度量化 / 纹素足迹 /
// refine 残留的尺度，夹角 ~1-5°）；剪影 / 深度跳变类伪命中的表面不在路径上、重建点大幅偏离
// 射线（夹角无界）。dot(起点→碰撞点, 步进方向) ≥ `WATER_SSR_DIR_MIN_DOT` 完全信任、低于则
// smoothstep 归零——「起点到碰撞点的方向和步进方向相差过大则不信任」，乘进命中 confidence
//（因子 0 即验证失败、march 终结走天空回退）。零新增 fetch（碰撞纹素深度已在验证路径上 fetch）。
// **只施加于 i ≥ 1 的中远途候选**：march 首步候选（起步即碰撞类）在调用点豁免本因子——其
// 「起点 → 碰撞点」基线趋零、方位由量化噪声主导，2026-10「折角天空线」实机确认全置信误杀
//（见 march 内注）。总开关 WATER_SSR_DIR_TRUST（constants.glsl，默认启用）删定义 = 全程恒信任
//（含 i ≥ 1）的诊断 A/B 档
float waterSsrDirectionTrust(vec3 origin, vec3 dir, vec2 hitPx, float sceneZ) {
#ifndef WATER_SSR_DIR_TRUST
    return 1.0;
#else
    vec3 hitView = waterSsrViewPosition(hitPx / vec2(viewWidth, viewHeight), sceneZ, taaJitterUV());
    vec3 toHit = hitView - origin;
    float dirDot = dot(toHit / max(length(toHit), 1e-4), dir);
    return smoothstep(WATER_SSR_DIR_MIN_DOT, 1.0, dirDot);
#endif
}

// 半空间裁剪（春雷 clipHalfSpace 同款，Liang-Barsky）：f(t) = f0 + fd·t 在约束 f ≥ 0 下的参数
// 区间收窄；fd ~ 0（射线与边界平行）按 f0 定恒在内 / 恒在外
bool waterSsrClipHalfSpace(float f0, float fd, inout float tEnter, inout float tExit) {
    if (abs(fd) < 1e-6) return f0 >= 0.0;
    float t = -f0 / fd;
    if (fd > 0.0) tEnter = max(tEnter, t);
    else          tExit  = min(tExit, t);
    return tEnter <= tExit;
}

// 远平面出口判定（春雷 exitsFarPlane 同款）：fd = (w − z) 方向分量 < 0 才朝远平面接近；出口参数
// 落在裁剪区间内且出口点 xy 在锥内（|x| ≤ w、|y| ≤ w）——从侧平面出屏的射线不触发远平面兜底
bool waterSsrExitsFarPlane(vec4 cs, vec4 cd, float tEnter, float tExit) {
    float fd = cd.w - cd.z;
    if (fd >= 0.0) return false;
    float tFar = (cs.z - cs.w) / fd;
    if (tFar < tEnter || tFar > tExit) return false;
    vec4 p = cs + cd * tFar;
    return p.w >= max(abs(p.x), abs(p.y));
}

// 屏域二分精修（原版固定 4 次；VOXY 最多 12 次，区间 <= 0.125 buffer px 时早退）：在 (lo, hi] 内夹逼命中点，保持「面后侧」端点
//（hi 侧）为返回值；门控与 march 同款（非天空、非手部才算遮挡）。sa / sb 与 march 同域
//（xy = buffer 像素域；原版 z = NDC，VOXY z = 负倒数视深）。hiDepth 未知：原版 -1、VOXY 1。
// 每次 hi 收缩时复用本次 zm；最终 hi 对应深度一并返回，免调用方重复 fetch。
float waterSsrRefine(vec3 sa, vec3 sb, float lo, float hi, float hiDepth, out float refinedDepth) {
    refinedDepth = hiDepth;
#ifdef VOXY
    // LOD 远景精修至亚像素；不影响原版固定四次读取的成本。
    // 比较平方距离，免循环内 sqrt。
    float intervalLengthSq = dot(sb.xy - sa.xy, sb.xy - sa.xy);
    for (int j = 0; j < 12; j++) {
        if (intervalLengthSq * (hi - lo) * (hi - lo) <= 0.015625) break;
#else
    for (int j = 0; j < 4; j++) {
#endif
        float mid = (lo + hi) * 0.5;
        vec3 spm = mix(sa, sb, mid);
        float zm = waterSsrDepth(spm.xy);
        if (waterSsrValidDepth(zm) && spm.z > zm) {
            hi = mid;
            refinedDepth = zm;
        } else {
            lo = mid;
        }
    }
    return hi;
}

// 2D SSPT 主入口：沿反射方向对 depthtex1（仅不透明）屏幕域 march。屏幕段 = 视锥裁剪（未抖动
// 投影 = 真视锥；jitter / TAAU 缩放只动 xy、z 不受影响）∪ TAAU 子区域 alpha 域再裁剪（域外深度
// 为每帧 clear 值 1，白跑）后的可见部分——两端点各投影一次、xy 经 applyJitter 仿射折叠进 buffer
// 域，段内线性插值即逐点折叠（投影映射保直线、z 沿 NDC 段线性插值精确）；步距恒定于屏幕像素
//（实际渲染区域最短边 ÷ WATER_SSR_SHORT_EDGE_STEPS 定标）、**不限步数走完整段**（到屏幕 / 视锥边缘
// 为止——春雷 traceFullScreen 同语义）
bool waterSSR(vec3 viewPos, vec3 reflDirView, float distWorld, vec3 faceNormalW, out vec2 hitBufUv, out float hitConfidence, out float hitDepth) {
    hitBufUv = vec2(0.0);
    hitConfidence = 0.0;
    hitDepth = 1.0; // miss 默认值；命中时复用精修验证纹素的深度
    // reflDirView 已是单位向量（调用点：reflect(单位, 单位) 保长 + mat3 刚体旋转保长，shadeWaterSurface
    // 两侧来源均已归一）——直传免一次 rsqrt（2026-10 性能；即使非单位，clip 域参数化对长度自洽）
    vec3 dir = reflDirView;
    // 自相交推离沿**几何面法线**（调用方传入、朝空气侧定向——水平面即世界 up 的观察系向量，竖直
    // 流面为侧向；2026-10 竖直流面修复起为真实面法线，此前框架全局按水平面处理、up 即「顶点法线」
    // 的精确等价，2026-10 自波面法线改）而非波面法线：推离职责纯几何——把起点抬离水面平面（march
    // 所对的 depthtex1 不含水自身，伪命中风险是波谷下方浅水湖底 / 水线岸壁 / 流面背后的岩壁，推离沿
    // 面法线即恒定的离面间隙——竖直流面上沿 up 推只会贴面滑动、不产生离面位移）；波面法线随波场逐
    // 像素摆动 + 随时间动画，起点跟着逐帧漂移 = 反射时域噪点（本不该存在、却要 TAA 收敛）。幅度沿用
    // 春v2 距离自适应档：随距离线性放大（远距深度量化变粗、像素足迹变大）至 ~20 格处饱和
    // 复用推离已有的面法线旋转；自适应角度不再额外乘矩阵。
    vec3 faceNormalView = mat3(gbufferModelView) * faceNormalW;
    vec3 origin = viewPos + faceNormalView * clamp(distWorld / 60.0, 0.01, 0.33);

    // ---- 视锥裁剪：clip 空间 6 半空间（w ± xyz 三轴），t 沿观察空间射线参数 ----
    vec4 cs = gbufferProjection * vec4(origin, 1.0);
    vec4 cd = gbufferProjection * vec4(dir, 0.0);
    float tEnter = 0.0;
#ifdef VOXY
    // 远景不受原版 far 截断；用 Voxy 视距限制有限射线，只裁 xy 与近面。
    float tExit = max(float(vxRenderDistance) * 16.0, far) * 2.0;
    if (!waterSsrClipHalfSpace(cs.w + cs.z, cd.w + cd.z, tEnter, tExit)) return false;
    const int clipAxes = 2;
#else
    float tExit = 1e20;
    const int clipAxes = 3;
#endif
    for (int i = 0; i < clipAxes; i++) {
        if (!waterSsrClipHalfSpace(cs.w + cs[i], cd.w + cd[i], tEnter, tExit) ||
            !waterSsrClipHalfSpace(cs.w - cs[i], cd.w - cd[i], tEnter, tExit)) return false;
    }
    if (tExit <= tEnter) return false;
#ifdef VOXY
    bool farPlaneExit = true; // 有限远端同样验证，避免末步漏掉远景。
#else
    bool farPlaneExit = waterSsrExitsFarPlane(cs, cd, tEnter, tExit);
#endif

    // ---- 端点投影 + buffer 域折叠（春雷对 clip 域施加抖动、此处对窗口 uv 施加——仿射等价）----
    // 投影线性性：复用裁剪已有的 cs / cd，免两次重复矩阵乘法。
    vec4 clip0 = cs + cd * tEnter;
    vec4 clip1 = cs + cd * tExit;
    if (abs(clip0.w) < 1e-8 || abs(clip1.w) < 1e-8) return false;
    vec3 s0 = vec3(clip0.xy / clip0.w * 0.5 + 0.5, clip0.z / clip0.w * 0.5 + 0.5);
    vec3 s1 = vec3(clip1.xy / clip1.w * 0.5 + 0.5, clip1.z / clip1.w * 0.5 + 0.5);
#ifdef VOXY
    // 倒数视深与 xy 同样可在屏幕线段上线性插值，不受原版 far / 近面精度影响。
    s0.z = -1.0 / clip0.w;
    s1.z = -1.0 / clip1.w;
#endif
    s0.xy = applyJitter(s0.xy);
    s1.xy = applyJitter(s1.xy);

    // ---- TAAU / SR_UPSCALE 子区域（无两者时即全屏 [0,1]²，顺带清 jitter 越界的半纹素尾差）alpha 域裁剪 ----
#if defined(TAAU) || defined(SR_UPSCALE)
    vec2 limit = renderRegionScale();
#else
    vec2 limit = vec2(1.0);
#endif
    vec2 segDelta = s1.xy - s0.xy;
    float aEnter = 0.0;
    float aExit = 1.0;
    for (int i = 0; i < 2; i++) {
        if (!waterSsrClipHalfSpace(s0[i],             segDelta[i],         aEnter, aExit) ||
            !waterSsrClipHalfSpace(limit[i] - s0[i], -(segDelta[i]),      aEnter, aExit)) return false;
    }
    if (aExit <= aEnter) return false;

    // ---- 可见段重定基 + 均匀像素步进参数（春雷 traceFullScreen 同式：不限步数走完可见段）。
    // 步距统一随实际渲染区域最短边定标（含 TAAU / SR；1080p 1x → 27 px/步）
    // ⇒ 可见段长度与步距同随分辨率缩放，最坏步数 ≈ 对角线 ÷ 最短边 × 本值 ≈ 2.3 × 40 ≈ 92
    // 射线长度与步距同乘渲染比例，降低比例仍保持相同的追踪密度 ----
    vec3 sa = mix(s0, s1, aEnter);
    vec3 sb = mix(s0, s1, aExit);
    // march 域换 buffer 像素域（2026-10 性能）：端点一次 ×viewport，每步 mix 直出 texelFetch 的
    // 像素坐标、免每步一次 uv×viewport 乘；z 保持 NDC。线性映射与 mix 精确可交换，仅浮点重结合
    // 的 ulp 级差异（bayer 相位 / TAA 吸收）
    vec2 viewSize = vec2(viewWidth, viewHeight);
    vec3 saPx = vec3(sa.xy * viewSize, sa.z);
    vec3 sbPx = vec3(sb.xy * viewSize, sb.z);
    vec2 limitPx = limit * viewSize;
    float rayPixLen = length(sbPx.xy - saPx.xy);
    if (rayPixLen < 1e-5) return false;
    float pixelsPerStep = min(limitPx.x, limitPx.y) / WATER_SSR_SHORT_EDGE_STEPS;
#ifdef WATER_SSR_ADAPTIVE_STRIDE
    // 入射余弦 = |V·N|：V 来自实际眼点观察位置，N 是推离使用的稳定面法线。
    // distWorld 由调用方传入 length(viewPos)，复用它免额外 normalize / sqrt。
    // 一条 ray 内步距固定；低于 LOW 完全保留 40 档，最高仅 ×1.25。
    // 本段只改变角度步距；短段下限由下方独立开关承载，精修 / 信任度 / 终结规则不变。
    float incidence = clamp(abs(dot(viewPos, faceNormalView)) / max(distWorld, 1e-5), 0.0, 1.0);
    float strideWeight = smoothstep(WATER_SSR_STRIDE_ANGLE_LOW, WATER_SSR_STRIDE_ANGLE_HIGH, incidence);
    pixelsPerStep *= 1.0 + WATER_SSR_STRIDE_MAX_EXTRA * strideWeight;
#endif
#ifdef WATER_SSR_SHORT_SEGMENT_SAMPLES
    // 经裁剪的短屏幕段至少有 3 个相位采样位置，防止整段仅 1~2 点而逐帧漏采。
    // 必须在角度放粗之后限制步距；长段 min 保留原值，不新增最低世界追踪距离。
    // 零长 / 退化段已在上方早退；原命中 / 验证失败即终结，不强迫命中后补够 3 次。
    pixelsPerStep = min(pixelsPerStep, rayPixLen / WATER_SSR_SHORT_SEGMENT_MIN_STEPS);
#endif
    int stepCount = max(int(ceil(rayPixLen / pixelsPerStep)), 1);
    float stepAlpha = min(pixelsPerStep / rayPixLen, 1.0);

    // 视深换算系数（验证用，典则闭式）
    float projC = gbufferProjection[2].z;
    float projD = gbufferProjection[3].z;

    float alpha = stepAlpha * temporalBayer64(gl_FragCoord.xy); // 64 相位 × TAA 时间累积（春雷 STBN 同职责）
    float lastGood = 0.0;
    bool aborted = false;
    bool hit = false;
    float hitAlpha = 0.0;
    ivec2 hitDepthPixel = ivec2(0);
    ivec2 maxPixel = ivec2(viewWidth, viewHeight) - 1;

    for (int i = 0; i < stepCount && alpha <= 1.0; i++) {
        vec3 sp = mix(saPx, sbPx, alpha);
        // 浮点尾差防线（alpha 域裁剪已保证段内）
        if (any(lessThan(sp.xy, vec2(0.0))) || any(greaterThan(sp.xy, limitPx))) { aborted = true; break; }

        float sceneZ = waterSsrDepth(sp.xy);
        // 手部深度经 MC_HAND_DEPTH 重映射、重建失真会伪命中（shadow.glsl 同排除）
        if (waterSsrValidDepth(sceneZ) && sp.z > sceneZ) {
            // 先二分精修、再合法性验证（2026-10 调序，旧序「候选验证 → 通过才精修」）：验证在
            // **交点纹素**上做——旧序验证的是候选步进点（过冲一个步长的射线深 + 候选像素场景深），
            // 与最终取色 / 命中重建纹素（精修交点）不同纹素，掠射大步长下二者场景深差可达数百格 =
            // 验证与取色脱节；调序后验证 / 取色 / 深度重建同一纹素。**带宽维持整步跨度**（上一步 →
            // 候选步的射线深差 × BIAS + TOLERANCE，与旧序逐位同宽容度、剪影拒收阈值不变——曾试
            //「收敛区间跨度〔1/16 步长〕作带宽」的更严档被否：对掠射打到岸线 / 剪影边缘等深度
            // 不连续处的真命中过严），分子换成精修交点的穿透深（连续表面随亚像素区间
            // 收敛而减小）——旧序分子 = 候选过冲（随 bayer
            // 相位均匀分布 [0, 步长]）⇒ residual 在 [0, 1/BIAS] 逐帧波动 = 命中 confidence 翻转
            // 的反射噪点根源。代价 = 验证失败的剪影候选也付原版 4 次 / VOXY 最多 12 次 refine fetch（VOXY 亚像素区间早退）（每 march 至多一个
            // 候选、有界）
            float sceneZHit;
            float alphaRefined = waterSsrRefine(saPx, sbPx, lastGood, alpha, sceneZ, sceneZHit);
            vec3 spHit = mix(saPx, sbPx, alphaRefined);
            // 方向一致性信任（waterSsrDirectionTrust，2026-10）：碰撞表面不在射线路径近旁
            //（剪影 / 深度跳变类伪命中）→ 因子归零 = 不信任，与深度验证相乘联合把关。
            // **首步候选豁免（2026-10「折角天空线」实机修复）**：i == 0 的候选 = 起步即碰撞类
            //——法线折角 / 水线带（视差 + 去抖把起点推进相邻几何）的立即命中，其精修交点落在
            // 起点自身纹素 / 折角边界纹素上，「起点 → 碰撞点」基线长度趋零、重建点方位由深度量化
            // 与纹素分类主导，夹角无意义地无界 → 全置信误杀成确定性天空回退（沿折角的直线天空色，
            // 实机 A/B 确认：恒信任后消失）。首步候选跳过方向验证、仍受深度带验证把关（前景剪影
            //「表面远比射线更靠近相机」类正是深度带的职责域，防拉丝不损失）；i ≥ 1 的中远途候选
            // 基线充分长、重建方位可信，方向验证照常。诊断开关 WATER_SSR_DIR_TRUST（constants.glsl）
            // 注释 = 全程恒信任（含 i ≥ 1）
            float candidateConfidence = waterSsrHitConfidence(spHit.z,
                                                              mix(saPx.z, sbPx.z, lastGood),
                                                              mix(saPx.z, sbPx.z, alpha),
                                                              sceneZHit, projC, projD);
            // 深度信任度为零时最终必拒收，免碰撞点重建 / normalize / 角度判定。
            // 首步豁免与原判定保持不变，接受域和置信度不变。
            if (candidateConfidence > 0.0)
                candidateConfidence *= (i == 0 ? 1.0 : waterSsrDirectionTrust(origin, dir, spHit.xy, sceneZHit));
            if (candidateConfidence > 0.0) {
                hitConfidence = candidateConfidence;
                hitAlpha = alphaRefined;
                hitDepth = sceneZHit;
                hitDepthPixel = clamp(ivec2(spHit.xy), ivec2(0), maxPixel);
                hit = true;
            }
            aborted = true; // 命中（已精修）或验证失败都终结 march（春雷同款：剪影伪命中不再继续走）
            break;
        }
        lastGood = alpha;
        alpha += stepAlpha;
    }

    // ---- 远平面兜底（春雷 traceFarPlane）：未中断且出口为远平面（不限步数下整段恒走完——
    // 春雷全屏档同语义）、出口像素有不透明几何且在射线前方（验证把关——前景剪影仍拒收）；
    // 与 march 候选同款「先精修后验证」（2026-10 调序，见上注），验证纹素 = 精修交点----
    if (!hit && !aborted && farPlaneExit) {
        float sceneZ;
#ifdef VOXY
        float alphaRefined = waterSsrRefine(saPx, sbPx, lastGood, 1.0, 1.0, sceneZ);
#else
        float alphaRefined = waterSsrRefine(saPx, sbPx, lastGood, 1.0, -1.0, sceneZ);
#endif
        vec3 spExit = mix(saPx, sbPx, alphaRefined);
        // 远端 hi 尚未采样；只有精修全程未更新 hi 时补读，不能复用无效占位。
#ifdef VOXY
        if (sceneZ == 1.0) sceneZ = waterSsrDepth(spExit.xy);
#else
        if (sceneZ < 0.0) sceneZ = waterSsrDepth(spExit.xy);
#endif
        float candidateConfidence = 0.0;
        // 原路径先算信任度再判几何；反过来门控可免天空 / 手部 / 面前候选的验证成本。
        if (waterSsrValidDepth(sceneZ) && spExit.z >= sceneZ) {
            candidateConfidence = waterSsrHitConfidence(spExit.z,
                                                        mix(saPx.z, sbPx.z, lastGood),
                                                        sbPx.z, sceneZ, projC, projD);
            if (candidateConfidence > 0.0)
                candidateConfidence *= waterSsrDirectionTrust(origin, dir, spExit.xy, sceneZ);
        }
        if (waterSsrValidDepth(sceneZ) && spExit.z >= sceneZ && candidateConfidence > 0.0) {
            hitConfidence = candidateConfidence;
            hitAlpha = alphaRefined;
            hitDepth = sceneZ;
            hitDepthPixel = clamp(ivec2(spExit.xy), ivec2(0), maxPixel);
            hit = true;
        }
    }

    if (!hit) return false;
    hitBufUv = clamp(mix(saPx, sbPx, hitAlpha).xy, vec2(0.0), limitPx) / viewSize;
    // uv 除法再乘视口的 float 舍入可能跨整像素边界；仅这种罕见情况补 fetch，
    // 保留旧调用方按最终 hitBufUv 取深度的语义，通常命中直接复用验证深度。
    ivec2 returnedPixel = clamp(ivec2(hitBufUv * viewSize), ivec2(0), maxPixel);
    if (any(notEqual(returnedPixel, hitDepthPixel))) hitDepth = waterSsrDepth(hitBufUv * viewSize);
    return true;
}

#endif

#endif
