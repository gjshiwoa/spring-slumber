// 大气散射雾 / 空气透视（aerial perspective，宏 AERIAL_PERSPECTIVE 门控；设计全文见
// plans/地表大气散射方案.md）
// 物理式空气透视：finalColor = surface × T(viewDir, dist) + S(viewDir, dist)——S = 相机→表面
// 路径上大气再散射进视线的光（inscatter，加光项）、T = 同一路径透射率（表面衰减项）；观感上仍是
// 「远处 mix 向天光色」，但雾色随方向 × 距离 × 时刻连续变化：逆光发白（Mie 前向峰）、顺光偏蓝、
// 抬头散去、日落时山下暗山上亮（路径末端进入地球阴影）——正是边界雾「无光照方向性 / 无高度衰减」
// 已知限制要补的东西。与边界雾两段式分工（非替代）：aerial 管中近距物理空气感，boundary 兜
// 0.7~0.9·far 渲染边界硬融接（MC 视距内物理融合度上限低——水平 inscatter 渐近到天空色需数百 km
// 等效路径，far 端硬融接不可能由物理路径独立完成）。
// 供给形态 = 小 LUT（Hillaire 2020 aerial LUT 思想、地面玩家海拔近似恒定砍一维、Chapman 解析生成
// 砍 march）：colortex7 左下角原点 (0,0)、AERIAL_LUT_W × (AERIAL_LUT_H × AERIAL_LUT_SLICES)
// 纵向堆叠（方向 64×48 × 距离 4 档，天空盒预留区左下角至今空置）；RGBA16F：rgb = inscatter
//（含 MS 项、已乘 SKY_BRIGHTNESS、双光源和式），a = 透射率绿通道（标量，chromatic 透射为扩展点）。
// 生成端 = composite12（composite_bloom_upsample BLOOM_LEVEL 0）天空 LUT 重算 pass 的区域分支，
// 帧常量（observerRadius / horizon / 日月方向 / tauS / ambientField）复用天空 LUT 的 vsh varying、
// vsh 零新增；有效性 / 滞后一帧与天空 LUT 同源同批（同 pass 写入、vSkyLutValid 共用探针）。
// 消费端 = composite_fog（composite2）几何分支、applyBoundaryFog 之前；距离 / 方向与边界雾共用
// depthtex0 去抖重建。起始门（AERIAL_FOG_START / END）：约 far/3 内无雾、效果域 smoothstep 自零
// 渐入至 0.7·far 全强（见 applyAerialPerspective）。三条不变式（违反即地平线接缝 / double-scatter，机制见 constants.glsl
// AERIAL 分区与方案 §2）：①放大距离不放大密度（渐近 = 天空色）、雨天走距离域乘子；②∞ 档 =
// t = SKY_NO_HIT 的求值（地平线以上方向与 sky LUT 同参数同值，结构性融接）；③天空像素不施加
//（调用方 depth >= 1 分支在外）。删宏 = aerial 段编译剔除、composite12 该区域落入透传分支保值、
// composite_fog 回退纯边界雾——开关 / 数值分离纪律同 TAAU / RCAS
// 依赖由接入的 program 先行 include：constants.glsl（AERIAL_*、SKY_LIGHT_MIN_HEIGHT、
//   SKY_BRIGHTNESS、SKY_NO_HIT、SOLAR / MOON_IRRADIANCE）、uniforms.glsl（gaux4 = colortex7 /
//   isEyeInWater / rainStrength / far——起始门）、atmosphere.glsl（atmosphericRadiance）、sky.glsl
//   （skyViewLutZenithParam / skyViewLutAzimuthParam / lutParamToTexelCenter——方向参数化互逆组
//   单真源复用，采样端参数函数分辨率无关）、utils/space.glsl（viewToWorldDirection，
//   仅 applyAerialPerspective 需要）
#ifndef LIB_ATMOSPHERE_AERIAL_GLSL
#define LIB_ATMOSPHERE_AERIAL_GLSL

#ifdef AERIAL_PERSPECTIVE

// ---------------- 生成端（composite12 / composite_bloom_upsample BLOOM_LEVEL 0） ----------------

// aerial LUT texel → (inscatter × SKY_BRIGHTNESS, 透射率)：localPos.x ∈ [0, AERIAL_LUT_W) 方位、
// localPos.y ∈ [0, AERIAL_LUT_H × SLICES)（天顶行 = y % H、距离档 = y / H，档 0~2 有限等效距离、
// 末档 ∞）。方向反参数化与 sky.glsl skyViewLutTexel 的局部系构造同式（「光源水平投影 = +X、光源
// 位于 XY 平面内」——球对称大气的散射只依赖 (vzc, szCos, mu)，与真实方位仅差绕天顶旋转）、分辨率
// 独立；参数化公式与 skyViewLutTexel 成对维护。方向不做地平线钳制（aerial 是真实视线的有限路径
// 几何，含下视；下视远距的虚拟钻地由 atmosphericRadianceSingle 内 rP 钳贴地防护）。方位锚 =
// 主导光源（与采样端同一判定）：交接发生在主导者沉入 SKY_LIGHT_MIN_HEIGHT 时、另一侧已接棒，
// LUT 值本身连续（同物理），参数化重排经 TAA 吸收。双光源和式（散射积分对光源线性、不分半区），
// 各光源低于阈值跳过求值（与天空 LUT 非活动半区写黑同一纪律）；次光源 = 锚的反向（MC 日月恰好
// 相对）。tauS / ambientField 为 composite12 vsh 预计算的同名帧数据（与天空 LUT 生成端同源）
vec4 aerialLutTexel(ivec2 localPos, float observerRadius, vec3 horizon,
                    vec3 sunDirection, vec3 sunOpticalDepth, vec3 sunAmbientField,
                    vec3 moonDirection, vec3 moonOpticalDepth, vec3 moonAmbientField) {
    int slice = localPos.y / AERIAL_LUT_H;
    int row   = localPos.y - slice * AERIAL_LUT_H;

    // 纹素中心参数（采样端 skyViewLutAzimuthParam / skyViewLutZenithParam 的逆映射，
    // 公式与 skyViewLutTexel 成对维护）
    float azimuthParam = float(localPos.x) / float(AERIAL_LUT_W - 1);
    float zenithParam  = float(row) / float(AERIAL_LUT_H - 1);

    float beta = horizon.y;
    float zenithHorizon = horizon.z;
    float vzc;
    if (zenithParam < 0.5) {
        float q = 1.0 - 2.0 * zenithParam;
        vzc = cos(zenithHorizon * (1.0 - q * q));
    } else {
        float q = 2.0 * zenithParam - 1.0;
        vzc = cos(zenithHorizon + beta * (q * q));
    }
    float vzSin = sqrt(max(1.0 - vzc * vzc, 0.0));

    float lvCos = 1.0 - 2.0 * azimuthParam * azimuthParam;
    float lvSin = sqrt(max(1.0 - lvCos * lvCos, 0.0));

    // 方位锚 = 主导光源（采样端 sampleAerialLut 同一判定，两端联动）；局部系构造同 skyViewLutTexel
    bool sunAnchored = sunDirection.y > SKY_LIGHT_MIN_HEIGHT;
    vec3 anchorWorld = sunAnchored ? sunDirection : moonDirection;
    float szCos = clamp(anchorWorld.y, -1.0, 1.0);
    float szSin = sqrt(max(1.0 - szCos * szCos, 0.0));
    vec3 localAnchor = vec3(szSin, szCos, 0.0);
    vec3 localSun  = sunAnchored ?  localAnchor : -localAnchor; // 次光源 = 锚的反向（日月恰好相对）
    vec3 localMoon = sunAnchored ? -localAnchor :  localAnchor;

    // 距离档：末档 ∞（天空渐近、与 sky LUT 同构——不变式②）；有限档为等效路径米数
    float t = slice < AERIAL_LUT_SLICES - 1 ? AERIAL_DIST_SLICES[slice] : SKY_NO_HIT;

    vec3 origin = vec3(0.0, observerRadius, 0.0);
    vec3 dirLocal = vec3(vzSin * lvCos, vzc, vzSin * lvSin);
    vec3 inscatter = vec3(0.0);
    // 透射率与光源无关（tauV 只依赖 origin/direction/t），任一活动光源的调用带回即可；
    // 日月恰好相对、双侧同时低于阈值的构型不存在，防御初值 1（无衰减）仅兜底
    vec3 transmittance = vec3(1.0);
    if (sunDirection.y > SKY_LIGHT_MIN_HEIGHT) {
        inscatter += atmosphericRadiance(origin, dirLocal, dirLocal, localSun,
                                         sunOpticalDepth, t, SOLAR_IRRADIANCE,
                                         sunAmbientField, transmittance);
    }
    if (moonDirection.y > SKY_LIGHT_MIN_HEIGHT) {
        vec3 transMoon;
        inscatter += atmosphericRadiance(origin, dirLocal, dirLocal, localMoon,
                                         moonOpticalDepth, t, MOON_IRRADIANCE,
                                         moonAmbientField, transMoon);
        if (sunDirection.y <= SKY_LIGHT_MIN_HEIGHT) transmittance = transMoon; // 日光分支未跑才取月侧带回
    }
    return vec4(inscatter * SKY_BRIGHTNESS, transmittance.g);
}

// ---------------- 采样端（composite_fog 几何分支） ----------------

// 单档 fetch：方向参数 → 半纹素内缩局部 uv（lutParamToTexelCenter 同款纪律——相邻 texel 是同
// 方向不同距离，防跨档条带串色）→ 切片平移 → 缓冲 uv 双线性。textureLod 0 显式（colortex7 无 mip）；
// 采样位置的去抖方向已含当前帧 jitter 相位（与 deferred_init 天空采样同构，facet 交由 TAA 抹平）
vec4 aerialLutFetch(vec2 param, int slice) {
    vec2 texel = 1.0 / vec2(textureSize(gaux4, 0));
    vec2 localUv = vec2(lutParamToTexelCenter(param.x, float(AERIAL_LUT_W)),
                        lutParamToTexelCenter(param.y, float(AERIAL_LUT_H)));
    vec2 rectOrigin = vec2(0.0, float(slice * AERIAL_LUT_H)) * texel;
    vec2 rectSize = vec2(float(AERIAL_LUT_W), float(AERIAL_LUT_H)) * texel;
    return textureLod(gaux4, rectOrigin + localUv * rectSize, 0.0);
}

// 世界方向（归一化）+ 等效路径距离 → vec4(inscatter, 透射率)；tEff = 真距 × AERIAL_DIST_SCALE ×
// 雨天乘子（调用方算好）。档间按线性距离权重 lerp（inscatter 未饱和段近似线性于 t）；tEff 超过
// 档 2 后向 ∞ 档按 w = 1 − S2/t 收尾：无穷远无法作线性 lerp 端点（无穷分母 w 恒 0），直接跳 ∞ 档
// 会在档 2 距离环上留不连续；w 在 t = S2 处 0（与 slice2 段连续）、t → ∞ 收敛 1（渐近不变式），
// 剩余路径比例的物理直觉。档 0 以下向相机线性归零（见函数内注释）
vec4 sampleAerialLut(vec3 dirWorld, float tEff, vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon) {
    // 方位锚与生成端同一判定（两端联动）；参数函数复用 sky 的互逆组（分辨率无关、单真源）
    vec3 anchorLight = sunDirWorld.y > SKY_LIGHT_MIN_HEIGHT ? sunDirWorld : moonDirWorld;
    vec2 param = vec2(skyViewLutAzimuthParam(dirWorld, anchorLight),
                      skyViewLutZenithParam(dirWorld, horizon));

    if (tEff < AERIAL_DIST_SLICES[0]) {
        // 档 0 以下：LUT 层无起始阈值、向相机原点线性归零（t = 0 时 inscatter 0 / 透射率 1）——
        // 起始门在 applyAerialPerspective 的效果域（far/3），小 far 时渐入带前段仍落入本分支。
        // 首代「tEff < 档 0 整段跳过」在起始距离环上留一档 LUT[S0] 的亮度阶（世界系固定环、随
        // 地形移动，平滑地面上可见，2026-09 按反馈移除）；短路径 inscatter ∝ t、1−T ∝ t，线性
        // 外推即物理一阶近似；单 fetch（无档间 lerp）
        vec4 s0 = aerialLutFetch(param, 0);
        float w = tEff / AERIAL_DIST_SLICES[0];
        return vec4(s0.rgb * w, mix(1.0, s0.a, w));
    }
    if (tEff >= AERIAL_DIST_SLICES[2]) {
        float w = clamp(1.0 - AERIAL_DIST_SLICES[2] / tEff, 0.0, 1.0);
        return mix(aerialLutFetch(param, 2), aerialLutFetch(param, AERIAL_LUT_SLICES - 1), w);
    }
    if (tEff < AERIAL_DIST_SLICES[1]) {
        float w = (tEff - AERIAL_DIST_SLICES[0]) / (AERIAL_DIST_SLICES[1] - AERIAL_DIST_SLICES[0]);
        return mix(aerialLutFetch(param, 0), aerialLutFetch(param, 1), w);
    }
    float w = (tEff - AERIAL_DIST_SLICES[1]) / (AERIAL_DIST_SLICES[2] - AERIAL_DIST_SLICES[1]);
    return mix(aerialLutFetch(param, 1), aerialLutFetch(param, 2), w);
}

// 总入口：color 就地施加空气透视（surface × T + S）。viewPos 为去抖重建的观察空间位置（几何
// 像素）；天空像素由调用方分支在外（不变式③）。早退链 = 水下（与边界雾同一纪律）→ LUT 无效
//（首帧 / 缓冲重建，跳过 = 恒等）→ 近距（fade = 0，公式值恰为 0 的恒等跳过、零 fetch）。
// **起始距离门（2026-09 按反馈接入）**：AERIAL_FOG_START（far/3）内无雾、smoothstep 至
// AERIAL_FOG_END（0.7·far = BOUNDARY_FOG_START 接力锚）全强——fade 乘在「原表面 vs 雾化结果」
// 的 mix 上（T / S 随 fade 同步缩放，半 fade = 部分雾）；smoothstep 起点系数恒 0 且零斜率（C1）、
// 环内外值同为 0——与首代「早退 = 0 / 环外立刻满档 LUT[S0]」的值阶环不同构（sampleAerialLut
// 内注释的教训），起始距离环结构性不可见；渐满点后远端强度与门前逐位相同（SCALE 调定的观感
// 不受影响）。渐入带内几何像素成本 = 档 0 以下 1 fetch、档间 lerp 2 fetch + 1 smoothstep
void applyAerialPerspective(inout vec3 color, vec3 viewPos,
                            vec3 sunDirWorld, vec3 moonDirWorld, vec3 horizon, bool lutValid) {
    if (isEyeInWater != 0 || !lutValid) return;

    float distWorld = length(viewPos);
    // 起始门系数：效果域（非 tEff 偏移——不动档位映射与渐近不变式②，远端强度不变）
    float fade = smoothstep(far * AERIAL_FOG_START, far * AERIAL_FOG_END, distWorld);
    if (fade <= 0.0) return;

    // 等效路径 = 真距 × 放大 × 雨天加浓（距离域乘子，保渐近不变式①——密度域调制禁用）
    float tEff = distWorld * AERIAL_DIST_SCALE * (1.0 + AERIAL_RAIN_BOOST * rainStrength);

    vec4 aerial = sampleAerialLut(normalize(viewToWorldDirection(viewPos)), tEff,
                                  sunDirWorld, moonDirWorld, horizon);
    color = mix(color, color * aerial.a + aerial.rgb, fade);
}

#endif

#endif
