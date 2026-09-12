// 阴影贴图采样核心（路线与分档依据见 AGENTS.md「阴影贴图」条 / constants.glsl 阴影分区）：
// 线性 distortion + shadowtex0 硬件比较黄金螺旋 PCF（temporal bayer 时域旋转，composite_taa
// 时间累积收敛为软阴影）+ shadowtex1 裸深度手动比较分离半透明遮挡、取 shadowcolor0 透射色
// 上彩色阴影（春v2 getColorShadow 同款）。扭曲 / 压缩换算在 utils/space.glsl（写读两侧共用）。
// PCSS 后路：tex1 保持裸深度，未来加 blocker search（读 tex1 浅于接收者的平均遮挡深度推半影
// 半径、替换常数半径）即升级，引擎配置零改动。
// 另含屏幕空间追踪阴影 screenSpaceShadowVisibility（SHADOW_SCREEN_SPACE 开关，方案见
// plans/屏幕空间追踪阴影方案.md）：近景接触细节 + 远景接管（贴图可见性在此 0.9D→D 淡出交接）
// 依赖由接入的 program 先行 include：constants.glsl / uniforms.glsl / utils/color.glsl（srgbToLinear）/
//   utils/space.glsl（shadowDistort / relativeWorldToShadowScreen / remapSaturate / screenToView）/
//   utils/noise.glsl（temporalBayer64 / applyJitter）
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
    vec3 visibility = visibilitySum / float(sampleCount);
#ifdef SHADOW_SCREEN_SPACE
    // 贴图淡出窗（屏幕空间追踪阴影接管的前提，春v2 同款）：0.9D 内逐位不变、D 处收敛全亮——无窗
    // 则 D 处贴图软影瞬间消失、噪声更大的屏幕空间影顶上，可见跳变；有窗则「SS 已在场（min）→ 贴图
    // 退场 → SS 独挑」连续交接。淡出必须向 1（lit）mix：直接乘 (1→0) 是把可见性乘向 0 = 全影，
    // 整环渐变压黑（实测「边界渐变描黑」的根因——可见性 0 = 阴影，与「淡出」意图正好相反）。
    // 开关关闭时逐位回硬切（无 SS 接管时不淡出，避免 D 前凭空丢影）
    visibility = mix(vec3(1.0), visibility,
                     remapSaturate(distWorld, SHADOW_SS_HANDOVER * shadowDistance, shadowDistance, 1.0, 0.0));
#endif
    return visibility;
}

// ---------------- 屏幕空间追踪阴影（SHADOW_SCREEN_SPACE，仅片段阶段） ----------------

// 沿主光源方向对 depthtex1（不透明深度）的世界空间 ray march，一档追踪兼两职：近景补接触细节
//（normal offset / PCF 模糊吃掉的小影）、远景接管（贴图 0.9D→D 淡出后为唯一阴影源，视距远超
// shadowDistance）。机制春v2 谱系（其 screenSpaceShadow + deferred5 调用点）、公式自研重写——
// 世界域均匀步（步距随长度自动缩放：近 trace 5 cm、远 trace 1.25 格，各自匹配该距离下亚像素化的
// 细节尺度）+ 每步透视精确投影（免端点插值的掠射透视失真，ALU 被 fetch 延迟掩盖）+ 3D 距离窗命中
//（掠射光下山体遮挡深度差趋零、深度窗必漏；3D 距离正确度量射线漂到表面后方多远）。适用范围 /
// SSS 渐入 / min 合成在调用方 shadeSurface（lighting.glsl）。
// viewPos    观察空间位置（shadeSurface 传入）
// normalView 观图空间单位法线（起点法向偏移用）
// distWorld  相机距离：驱动长度 / 起点偏移 / 厚度三条 remap 曲线
float screenSpaceShadowVisibility(vec3 viewPos, vec3 normalView, float distWorld) {
    // 与阴影贴图渲染 / vLightDirection 同一光源（vsh 即由它旋转到世界系）——接触阴影补的是贴图
    // 判定，同光源才自洽；晨昏切换黑过渡窗口内即便瞬时不一致，直射辐照度双 0、结果不可见
    vec3 lightDirView = normalize(shadowLightPosition);

    // 距离 remap 族（春v2 谱系锚点、格）：长度近接触尺度 → 远山体尺度；起点偏移与厚度窗同向增长、
    // 自身表面排除的裕度随窗宽自动放大；厚度四次曲线 x = (dist/D)⁴ 自下锚起陡升——紧口径保持到
    // dist ≈ D·(5/D)^¼ ≈ 0.45D（中景接触细节要紧窗防薄几何误命中），接管区放到 THICKNESS_FAR
    // 容山体起伏与屏幕域步距透视放大
    const float DIST_ANCHOR = 5.0; // 长度 / 起点偏移的近端距离锚 + 厚度曲线的下锚（格，机制内建值）
    float rayLength = remapSaturate(distWorld, DIST_ANCHOR, shadowDistance,
                                    SHADOW_SS_LENGTH_NEAR, SHADOW_SS_LENGTH_FAR);
    float startBias = remapSaturate(distWorld, DIST_ANCHOR, shadowDistance, 0.01, 0.1);
    float thickness = remapSaturate(pow(distWorld / shadowDistance, 4.0),
                                    DIST_ANCHOR / shadowDistance, 1.0,
                                    SHADOW_SS_THICKNESS_NEAR, SHADOW_SS_THICKNESS_FAR);

    // 起点沿光向 + 法向各推 startBias（春v2 同款配对）
    vec3 origin = viewPos + (lightDirView + normalView) * startBias;

    float dither = temporalBayer64(gl_FragCoord.xy);
    float stepLen = rayLength / float(SHADOW_SS_STEPS);

    for (int i = 0; i < SHADOW_SS_STEPS; i++) {
        vec3 p = origin + lightDirView * ((float(i) + dither) * stepLen);

        // 每步透视精确投影 → 全视场 uv（gbufferProjection 为全视场 FOV 矩阵）。clip.w ≤ 0 即射线
        // 走到相机后方（t 单调递增、后续步同样）：w 为负时透视相除符号翻转，uv 可能落回 [0,1] 内
        // 伪命中，必须先行终止
        vec4 clip = gbufferProjection * vec4(p, 1.0);
        if (clip.w <= 0.0) break;
        vec2 uv = clip.xy / clip.w * 0.5 + 0.5;

        // buffer 域换算（TAAU：uv·S + jitter，applyJitter 已按 TAAU 补全）与 deferred_init 去抖
        // 基底 (像素uv − vJitter)/S 严格互逆；出屏即 break——后续命中在屏外不可见，继续算无意义
        vec2 bufUv = applyJitter(uv);
        if (any(lessThan(bufUv, vec2(0.0))) || any(greaterThan(bufUv, vec2(1.0)))) break;

        float depth = textureLod(depthtex1, bufUv, 0.0).r;
        if (depth >= 1.0) continue;           // 天空 texel 不遮挡（TAAU 子区域外为每帧清屏值、同判）
        if (depth < TAA_HAND_DEPTH) continue; // 手部深度经 MC_HAND_DEPTH 重映射、重建失真会伪命中

        // 场景点重建与射线点同域（全视场 uv + 本帧投影，与 deferred_init 位置重建同一去抖纪律）；
        // 命中 = 场景点比射线点近（径向前后序，排除自身表面——浮出表面的射线点投到屏上、命中
        // texel 的表面在其后方更深处）且 3D 距离在厚度窗内。二值命中即返回，软度全部交给
        // dither 64 相位 + composite_taa 时间累积（与 PCF 低档同一收敛机制）
        vec3 scene = screenToView(vec3(uv, depth));
        if (dot(scene, scene) < dot(p, p) && distance(scene, p) < thickness) return 0.0;
    }
    // D 外整体缩放（春v2 ×0.9 微减弱接管区噪声的观感旋钮——语义是远处整体轻微调光〔lit 值 ×0.9〕，
    // 非「阴影变浅」；默认 1.0 恒等、编译期常量折叠）
    float visibility = remapSaturate(distWorld, SHADOW_SS_HANDOVER * shadowDistance, shadowDistance,
                                     1.0, SHADOW_SS_FAR_SCALE);

    // 渲染边界淡出：远边界带是掠射视角，径向前后序对海拔变化只有二阶敏感——命中判定退化为厚度窗
    // 内的噪声翻转，dither + TAA 把逐像素随机命中平均成沿边界的渐变压暗（春v2 同参数有雾掩盖、
    // 本包无雾直接暴露）。按「距渲染边界接近度」把可见性向 1（lit）mix（far 随视距自适应）：
    // 边界带回退无影、接管主体（0.9D → EDGE_START·far）不受影响。同样必须 mix 向 1——曾因乘向
    // (1→0) 的方向反转实测「边界外全黑」（乘到 0 = 全影），可见性语义 0/1 两个方向差一位就是
    // 描黑与全黑之别
    float edgeFade = remapSaturate(distWorld, SHADOW_SS_EDGE_START * far, SHADOW_SS_EDGE_END * far,
                                   1.0, 0.0);
    return mix(1.0, visibility, edgeFade);
}

#endif

#endif
