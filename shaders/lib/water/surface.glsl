// 前向水面框架主着色（仅片段阶段；2026-10 自 lib/lighting/water.glsl 按功能拆分，git 历史含合并
// 形态；方案移植自春v2 lib/water/*，前向组合式样见其 gbuffers_water 与 deferred21）。消费方：
//   gbuffers_translucent（water 入口，宏 WATER_SURFACE 由入口定义）——水面像素主着色；
//   （相机在水中的整屏水下雾在同拆的 lib/water/fog.glsl，由 composite_fog 消费）
// 组合式样：折射背景 →（水上）水雾吸收 + 满深 mix（波面漫反射起伏只调制雾色光照的直射项，见
// 函数内段注；曾同期接入的水体 SSS〔逆光透射相位，GDC 2011 fake translucency 谱系〕两轮调参后
// 逆光对齐带观感仍不自然、按反馈整体移除，git 历史含完整形态）→ Fresnel 混反射（SSR 命中取场景
// 色、未命中回退天空——天空 = LUT + 解析太阳盘 + 烘焙云层天空盒，见 lib/water/reflection.glsl）
// → 主导光源镜面高光。返回线性 HDR。
// **波面法线按几何面重定基（2026-10 竖直流面反射修复）**：高度场法线恒朝上（y = ε² 构造，波形
// 供给见 lib/water/waves.glsl），竖直流面（瀑布 / 水柱 / 陡坡流动水）直接拿它当着色法线 = 把竖直面
// 当水平镜——反射按「法线朝上」倒映天空 / 地平线、Fresnel 亦按掠射给满反射率（水柱镜面异常的
// 实测根因）。着色法线 = **朝空气侧定向的几何面法线 + 波面坡度扰动**（波法线相对 up 的偏差）：
// 水平面逐位恒等（up + (waveN − up) = waveN），竖直面得到「面法线 ± 波坡度」的侧向法线——反射 /
// Fresnel / 折射扰动 / 雾色起伏 / SSR 起点推离全部自然消费同一法线（见函数内「朝空气侧定向 /
// 重定基」段）。
// **波形采样点去抖**（函数开头，2026-10 远水反射闪烁修复）：抖动光栅下同一像素的 varying 世界
// 坐标帧间随 jitter 相位跳动（远水被掠射透视放大到远超波特征的量级 = 法线 / 反射方向帧间随机、
// TAA 收敛不住），故采样点一律换成未抖动像素中心视线与水面平面的交点（竖直流面〔瀑布 / 陡坡
// 流动水〕按几何面水平度门控跳过，2026-10——见函数内「竖直流面门控」段注）。
// **掠视角波幅衰减（2026-10 按反馈重调的水闪烁抑制；粗糙度 mask 于 2026-10-08 恢复，见 waves.glsl 头注）**：
// 波幅混入系数乘掠视衰减系数 = mix(1, |dot(视线, 水面几何法线)|, WAVE_GRAZE_STRENGTH)（水平水 =
// sin 仰角、裸点乘线性——点乘 1 完全粗糙 / 0 完全平坦；**玩家旋钮**：开关 WAVE_GRAZE_FADE +
// 强度 WAVE_GRAZE_STRENGTH，删宏 = 恒 1 全视角全波幅逐位回退）：掠视（平视地平线方向的远水：波
// 特征被 1/仰角透视放大到亚像素 = 闪烁带）趋平水、俯视（正对水面）全波幅；第一代 WAVE_FADE_*
// 距离淡出不分视角、高处俯视的远水被一并压平（嫌远水太平移除），第二代 smoothstep 窗
//（WAVE_GRAZE_LOW/HIGH）旋即按反馈简化为裸点乘线性档。系数在
// 视差 / 法线求值前算好（waveAmp）经参数供全部高度求值——衰减 0 时高度恒 1（平水基准）：法线差分
// 恒 up、视差 g0 = 0 自然跳过，法线 / 视差 / 水深起伏随系数一致收敛、无残留路径
// **水面视差（WAVE_PARALLAX）**：沿视线把着色点 march 到高度场隐式面（一阶预测 + 单次割线，
// 共 2 次高度求值），法线在位移后世界 xz 求值、SSR 起点 / 水深 / 折射守卫随位移后位置换算——
// 波场有立体感（视差正确的波峰波谷错位）；顶点位移仍为扩展点（本视差只移 shading 点、不动
// 光栅几何 / 深度）。
// **折射 / SSR 的背景一律取 colortex4 快照（gaux1，deferred_init 曝光归一化编码写入），不读
// gaux3 活缓冲**：两者均为位移采样、落点会踩进本 draw 的其他水像素——活缓冲上「未写 = deferred
// 背景 / 已写 = 合成水色」由光栅序逐片元掷签，位移带内帧间漂移 = 暗色裂缝 / 闪变带（2026-10 实机
// 修复）；快照是本 draw 写入前的稳定一帧，且解耦后背景恒为「不含水面的场景」= 折射的正确物理语义。
// 解码系数由接入方 vsh 计算（HEADROOM ÷ 曝光槽位值，与编码端同帧同槽）经参数传入。
// **直射可见性门控（2026-10「遮挡处水反高光仍在」修复；最简档）**：glint 的 pow 512 lobe 只看
// 反射方向、镜中日盘只看 LUT——对「直射光是否真的到达该水面点」一无所知，桥影 / 楼影 / 山影下的
// 水面太阳亮带照常渲染。门控 = **shadowtex1 单 tap 硬判定**（旧自研包「采样一次 shadowmap 决定
// 是否渲染水反太阳 / 高光」的同款思路）：tex1 只含不透明几何、水面自身不在其中（无自阴影痤疮——
// 湖底沿光向更远、比较天然通过），不透明遮挡者切断高光、玻璃 / 上层水面等透射遮挡不细究（按全亮
// 放行）。**不复用 sampleShadowVisibility**（6~12 tap PCF + 彩色阴影 + SS trace，对每水像素过重，
// 按性能反馈降级、git 历史含复用档完整形态）。可见性乘进本函数内的 directIrradiance 本地值——
// 雾色光照直射项 / SSR 命中段雾色 / glint / waterSkyReflection 的解析日盘与月盘全部消费同一值
//（天空环境项不门控：环境无对应遮蔽信息）。
// **天空回退随 lm.y 调暗（2026-10「暗处水面反射天空盒爆亮」修复）**：SSR miss 回退整支乘水顶点
// lm.y 的重映射 + 回线性门（WATER_REFL_SKY_GATE_*）——洞窟 / 室内水面不再镜像亮天空，见调用点
// 段注。
// 性能（波形 fetch 账目见 lib/water/waves.glsl 头注）：直射门控（2026-10 起）+1 次 shadowtex1
// texelFetch + 1 次比较（单 tap 硬判定）；march 像素域端点预缩放在 lib/water/ssr.glsl 内；暗水（lm.y ≤
// WATER_REFL_SKY_GATE_LOW）的 miss 像素整链跳过天空回退求值（miss 分支段注）。SSR 恒 march——
// 曾有的 Fresnel 低值免 march 门（WATER_SSR_MIN_FRESNEL）已按反馈移除（2026-10，反射段注），常量随删
// 依赖由接入的 program 先行 include（lib 文件不嵌套——**同拆四件先行引入**：lib/water/waves.glsl /
// lib/water/fog.glsl / lib/water/ssr.glsl / lib/water/reflection.glsl，后者又前置 atmosphere 三件
//〔sky / aerial / fog〕与 lib/water/fog.glsl）；另需 constants.glsl（WAVE_PARALLAX /
// WAVE_HEIGHT / WAVE_ROUGHNESS_MASK / WAVE_GRAZE_FADE / WAVE_GRAZE_STRENGTH〔波幅档 + 掠视角衰减开关 / 强度——
// 上述选项在波形消费链本文件侧，文件头注〕/
// WATER_DEJIT_MIN_UPNESS / WATER_REFRACTION_* / WATER_DIFFUSE_* / WATER_MIST_VISIBILITY /
// WATER_FOG 宏分区 / WATER_GLINT_* / WATER_REFL_SKY_GATE_* / WATER_UW_REFL_* /
// WATER_BG_SNAPSHOT_HEADROOM〔解码系数在 vsh〕 /
// DIRECT_SKYLIGHT_GATE_* / SHADOW_BIAS_* / DIM_NO_SHADOW / DIM_NO_DIRECT_LIGHT / TAAU 的
// EFFECTIVE_RENDER_SCALE）、uniforms.glsl（depthtex1 / gaux1〔背景快照〕/ shadowtex1 / 视口 / far /
// shadowDistance / shadowMapResolution / cameraPosition / isEyeInWater / gbufferProjection /
// gbufferModelView(Inverse)）、utils/color.glsl（srgbToLinear）、utils/noise.glsl
//（applyInverseJitter 参数版——去抖 / 折射 / 命中点的位置重建基底）、utils/space.glsl
//（viewToWorldDirection / viewToRelativeWorld / screenToViewCanonical / relativeWorldToShadowScreen）、
// lib/lighting/ambient.glsl（shadowTex1HardVisibility——直射门控的单 tap 读取端；唯一接入方
// gbuffers_translucent 的既有平铺序已满足，ambient 位于 water 链之前）
#ifndef LIB_WATER_SURFACE_GLSL
#define LIB_WATER_SURFACE_GLSL

#ifdef STAGE_FRAGMENT

// ---------------- 水面主着色（gbuffers_translucent 的 water 入口消费） ----------------

// viewPos           观察空间位置（vsh 未做几何位移，水面即原始几何；进入本函数后先经**去抖替换**
//                   ——未抖动像素中心视线与水面平面交点，见函数开头段注与文件头注——WAVE_PARALLAX
//                   再沿视线位移到波高隐式面，下游全部消费〔法线求值 xz / SSR 起点 / 水深 / 折射
//                   守卫〕用替换后值）
// waterColorSrgb    水几何顶点色 rgb（生物群系水色，sRGB——雾基色调制用）；**不含纹理色**：tex 只
//                   作 cutout 判定与几何剔除，纹样 + 贴图亮度混进雾基色会让雾色随水纹理动画起伏、
//                   并把贴图整体亮度带进雾（2026-09 按反馈改传 vColor.rgb）
// lm                remapLightmap 后光照图
// bgDecode          背景快照解码系数（WATER_BG_SNAPSHOT_HEADROOM ÷ 曝光，vsh 经曝光槽位计算——
//                   与 deferred_init 编码端同帧同槽，见文件头）
// faceNormalW       水面几何面世界法线（调用方经 vViewPos 屏幕导数先于 discard 求好传入——纪律同
//                   gbuffers_opaque；方向未定向，函数内朝空气侧定向后消费，见函数内段注）：①波面
//                   法线重定基的基面（竖直流面反射修复，文件头注）②反射背向回退与 SSR 起点推离的
//                   基面③去抖 / 视差的水平面门控（|faceNormalW.y| 低于 WATER_DEJIT_MIN_UPNESS 跳过）
// 帧数据（vsh 同名 varying 传入，与通用全屏 vsh 同语义）：日月 / 主导光源世界方向、地平线、
//   LUT 有效性、直射辐照度、天空环境基色、TAA jitter（uv 域）
vec3 shadeWaterSurface(vec3 viewPos, vec3 waterColorSrgb, vec2 lm,
                       vec3 sunDirWorld, vec3 moonDirWorld, vec3 lightDirWorld, vec3 horizon,
                       float skyLutValid, vec3 directIrradiance,
                       vec3 skyAmbient, float bgDecode, vec2 jitterUv, vec3 faceNormalW, float waveFootprint) {
    bool underwater = isEyeInWater == 1;

    // 几何面水平度（|faceNormalW.y|，定向只翻方向不改变绝对值）：去抖与视差两处水平面假设门控共用
    float faceUpness = abs(faceNormalW.y);

    // ---- 波形采样点去抖（2026-10 远水反射闪烁修复）----
    // 顶点经 applyTAAJitter 抖动光栅，同一屏幕像素 varying 插值出的水面点帧间随相位移动：幅度 =
    // ±0.5 渲染纹素的角差 × 该像素的世界足迹——近处毫米级，远水被掠射 1/仰角透视放大（一格到几十
    // 格、远超波特征 ~2.9 格）⇒ 波形采样点帧间落在无关波上：法线 / 反射方向帧间随机摆动，SSR 命中
    // 点、天空回退、镜中解析日盘逐帧翻转，TAA 方差钳制对这种帧间大变收敛不住 = 远水反射闪烁的主因
    //（近水足迹 << 波特征、法线帧间连续，故不闪）。去抖 = 未抖动投影的像素中心视线（deferred_init /
    // composite_fog 同款基底：像素 uv − jitter、TAAU 再 /S——与 applyJitter 严格互逆）与水面平面
    //（全局水平面假设，SSR 推离同款）求交替换 viewPos，下游全部「水面点」消费（视差 / 法线 worldXz /
    // SSR 起点 / 水深 / 折射守卫）随之稳定——相机静止时逐帧逐位一致，波形时间项照常流动。与原点的
    // 偏差 = 0.5 纹素角差在平面内的滑动（dot(up,·) 恒等 ⇒ y 不动，水面高度 / 视差基准不受影响）；
    // 瀑布等竖直流面在水平面假设下采样点横向偏移几格（平铺噪声无锚定特征、无感，换竖直流面同样
    // 稳定）。s ≤ 0 / ≥ far·4（掠射地平线极限带交点发散）退回原值——该窄带亚像素噪声本就交 TAA
    //（denom → 0 时 s = inf/NaN、比较天然 false，无需独立守卫）
    // 竖直流面门控（2026-10）：水平面假设在瀑布 / 陡坡流动水（几何面导数法线 · up 低于
    // WATER_DEJIT_MIN_UPNESS）上把交点横向搬离真实片元几格——波形采样无锚定无感（头注），但
    // viewPos 同时是 SSR march 起点，起点前移 = 反射从错误位置发出；此类面跳过去抖、保留真实
    // 片元位置（其残余 jitter 抖动交 TAA，与水平面 far 掠射带同一取舍）。水平静水（upness = 1）
    // 恒去抖、行为不变
    if (faceUpness >= WATER_DEJIT_MIN_UPNESS) {
        // 去抖基底（公式单真源 = noise.glsl 的 applyInverseJitter 参数版，与 deferred_init /
        // composite_fog 同式）
        vec2 dejitUv = applyInverseJitter(gl_FragCoord.xy / vec2(viewWidth, viewHeight), jitterUv);
        vec3 upV = mat3(gbufferModelView) * vec3(0.0, 1.0, 0.0); // 世界 up 的观察系向量
        vec3 dejitDir = normalize(screenToViewCanonical(dejitUv, 1.0)); // 未抖动像素中心视线
        float s = dot(upV, viewPos) / dot(upV, dejitDir); // 平面 dot(up,p) = dot(up,viewPos) 的射线参数
        if (s > 0.0 && s < far * 4.0) viewPos = dejitDir * s;
    }

    float distWorld = length(viewPos);
    vec3 viewDirW = normalize(viewToWorldDirection(viewPos));
    vec3 worldPos = viewToRelativeWorld(viewPos) + cameraPosition; // 平几何水面点（绝对世界系；去抖交点见上块——y 与抖动插值恒等，仅 xz 稳定化）
    // 直射门控的采样位置（相对世界系）：**视差前的平面点**（去抖 xz 顺带稳定采样点；tex1 不含
    // 水面自身，平面点即可、无需随视差下探的波谷点）
    vec3 relWorldShadow = worldPos - cameraPosition;

    // ---- 几何面法线朝空气侧定向（2026-10 竖直流面反射修复，文件头注）----
    // 定向基准 = 空气侧：水上（眼在空气）可见面的空气侧面向相机（dot 与视线同号即翻转）；水下（眼
    // 在水）边界的空气侧在相机背面（反向翻转）。水平面两侧该式均归 up——既有「波面法线 / Fresnel /
    // TIR 全按朝上法线」的约定逐位保持（水下稠侧公式按「眼在 −N 侧」取 cosI = −cosView，正是本定向）；
    // 竖直流面得到面向空气的侧向法线，供下方重定基 / 背向回退 / SSR 起点推离消费
    if ((dot(faceNormalW, viewDirW) < 0.0) == underwater) faceNormalW = -faceNormalW;

    // ---- 水面视差（WAVE_PARALLAX）：沿视线把水面点从平几何面 march 到波高场隐式面
    // y = 几何水面 + (波高 − 1)·WAVE_PARALLAX_HEIGHT——波高 1 = 平水基准；波高恒 ≤ 1 ⇒ 隐式面在
    // 几何水面以下（波谷下探、波峰贴面）。迭代 = 一阶预测 + 单次割线（波场平滑〔特征 ~2.9 格、
    // 默认摆幅 ~0.11 格〕，一阶交点 t = g0/(−视线.y) 已近收敛、割线收尾，共 2 次高度求值）；
    // 方向不入式——水上俯视（视线.y < 0）t > 0 沿视线前推、水下仰视（视线.y > 0）t < 0 回退向眼，
    // 同一公式自然分叉；g0 = 0（平水）整段跳过 = 逐位回退。位移后下游全部「水面点」消费换新值：
    // worldPos / worldXz（法线在位移后 xz 求值）、viewPos（SSR 起点 / 折射有效性守卫的连线端点）、
    // distWorld（折射距离衰减 / 水深 / SSR 推离——波谷下探水深变浅、吸收随之变弱，物理一致）；
    // 折射背景采样位仍锚本像素（位移点在同一条视线上、屏幕位置不变，法线扰动位移照旧）。
    // 竖直流面门控（与去抖同门，2026-10 竖直面修复）：隐式面是水平面下方的波高场，竖直流面上水平面
    // 假设无意义，且 |视线.y| ≈ 0 使一阶解饱和于 ±MAX_SHIFT——着色点 / SSR 起点沿视线在流面两侧整幅
    // 漂移（0.75 格）；跳过 = 回平几何着色（与去抖跳过同一取舍，水平静水 upness = 1 恒走视差）----

    // ---- 掠视角波幅衰减（2026-10 按反馈重调的水闪烁抑制，文件头注；粗糙度 mask 独立调制）----
    // 波幅混入系数 = WAVE_HEIGHT 档的 pow(·, 1.35) × 掠视衰减系数：|dot(视线, 水面几何法线)|
    //（裸点乘线性映射：1 完全粗糙 / 0 完全平坦）经 WAVE_GRAZE_STRENGTH 的 mix(1, dot, 强度) 内插
    //——强度 1（默认）= 裸点乘、中间值整体抬底（0.5 = 掠视水保留一半波幅）；删 WAVE_GRAZE_FADE
    // 宏 = 本段编译剔除、恒 1（全视角全波幅逐位回退）。点乘 0 时高度恒 1（平水基准：法线差分恒
    // up、下方视差段 g0 = 0 自然跳过，法线 / 视差 / 水深起伏随系数一致收敛）。faceNormalW 已朝
    // 空气侧定向、abs 兼容水上 / 水下两侧（水平水 = sin 仰角）；竖直流面按面法线取夹角——正对
    // 瀑布照常起波、侧掠趋平，与重定基 / Fresnel 消费的是同一根法线；视角源自去抖后的 viewPos
    //（帧间稳定，系数不随 jitter 相位抖动）
    float grazeFade = 1.0;
#ifdef WAVE_GRAZE_FADE
    grazeFade = mix(1.0, abs(dot(viewDirW, faceNormalW)), WAVE_GRAZE_STRENGTH);
#endif
    float waveAmp = pow(WAVE_HEIGHT, 1.35) * grazeFade;
#ifdef WAVE_ROUGHNESS_MASK
    // 恢复旧低频粗糙度 mask：视差前 / 去抖世界锚点一次求值，视差与法线共用。
    // mix(1, mix(1, h, mask), amp) = mix(1, h, amp * mask)，不改高度函数接口。
    waveAmp *= waterWaveRoughnessMask(worldPos.xz * WAVE_FREQUENCY);
#endif

#ifdef WAVE_PARALLAX
    if (faceUpness >= WATER_DEJIT_MIN_UPNESS) {
        // g = 采样点 y 相对隐式面的高差（> 0 在面上方）；g0 ≥ 0 恒成立（隐式面 ≤ 几何水面）
        float g0 = (1.0 - waterWaveHeight(worldPos.xz, waveAmp)) * WAVE_PARALLAX_HEIGHT;
        if (g0 > 0.0) {
            // 一阶交点（假定波高沿视线不变）：|视线.y| → 0 掠射发散为 ±∞、clamp 即饱和
            //（0/0 NaN 由 g0 > 0 门槛挡住）
            float t1 = clamp(g0 / (-viewDirW.y), -WAVE_PARALLAX_MAX_SHIFT, WAVE_PARALLAX_MAX_SHIFT);
            vec3 p1 = worldPos + t1 * viewDirW;
            float g1 = t1 * viewDirW.y
                     + (1.0 - waterWaveHeight(p1.xz, waveAmp)) * WAVE_PARALLAX_HEIGHT;
            // 割线精修：(0, g0) 与 (t1, g1) 两点连线的零点；分母趋 0（波高沿视线平行）→ ±∞ 同饱和
            float tShift = clamp(t1 * g0 / (g0 - g1), -WAVE_PARALLAX_MAX_SHIFT, WAVE_PARALLAX_MAX_SHIFT);
            worldPos += tShift * viewDirW;
            viewPos += tShift * normalize(viewPos); // 同一视线：世界方向回观察系 = normalize(viewPos)（纯旋转保长）
            distWorld = length(viewPos);
        }
    }
#endif

    // ---- 波形法线（世界差分，头注路线；在视差位移后的 worldXz 求值）+ 几何面重定基（文件头注）----
    // 高度场法线恒朝上（y = ε² 构造），竖直流面直接拿它当着色法线 = 把竖直面当水平镜（反射倒映天空 /
    // Fresnel 按掠射给满反射率——水柱镜面异常的根因）；重定基 = 朝空气侧定向的几何面法线 + 波面坡度
    // 扰动（波法线相对 up 的偏差），水平面恒等（up + waveN − up = waveN、逐位回退）、竖直面得「面
    // 法线 ± 波坡度」——下游反射 / Fresnel / 折射扰动 / 雾色起伏 / glint 全部自然消费同一法线
    vec2 worldXz = worldPos.xz;
    vec3 normalW = normalize(faceNormalW + (waterWaveNormalW(worldXz, waveAmp, waveFootprint) - vec3(0.0, 1.0, 0.0)));

    // ---- 直射可见性门控（2026-10「遮挡处水反高光仍在」修复；最简档 = 单 tap 硬判定）----
    // 桥影 / 楼影 / 山影下的水面不再渲染 glint / 镜中日盘 / 雾色直射分量。**不复用
    // sampleShadowVisibility**（6~12 tap PCF + 彩色阴影三分支 + SS trace，对每水像素过重，
    // 2026-10 按性能反馈降级）：shadowtex1（仅不透明深度）单 tap 硬判定——读取端 =
    // ambient.glsl 的 shadowTex1HardVisibility（与实体前向直射 forwardEntityShade 共用单真源）。
    // tex1
    // 不含水面自身（无自阴影痤疮：湖底在水面下方、沿光向更远，比较天然通过），不透明遮挡者
    // 切断高光、玻璃 / 上层水面等透射遮挡不细究（按全亮放行）；出屏 / 超 shadowDistance 按
    // 全亮（贴图覆盖外无内容）。up 小偏移 + z 域 SHADOW_BIAS_DEPTH 防岸壁穿出水面处的痤疮；
    // 硬边无软化 = glitter 门控的稳定硬切（去抖采样点逐帧恒定），交 TAA 时间累积
    float sunVis = 1.0;
#ifndef DIM_NO_SHADOW
    // 维度极简档（DIM_NO_SHADOW，下界 / 末地）无 shadowtex1 采样：sunVis 恒 1——直射项由天光门
    //（两维度 lm.y 恒 0）归零、无视觉路径，纯省 fetch。读取端 = ambient.glsl 的
    // shadowTex1HardVisibility（单 tap 硬判定，与实体前向直射 forwardEntityShade 共用单真源，
    // 机制注见上方门控段）
    if (distWorld <= shadowDistance) {
        sunVis = shadowTex1HardVisibility(relWorldShadow + vec3(0.0, SHADOW_BIAS_NORMAL, 0.0));
    }
#endif
    // 直射项统一消费此本地值（雾色 sunTint / 波面起伏 / 命中段雾色 / glint / 镜中日盘）；
    // 天空环境项不门控（环境遮蔽无对应信息，维持现状）。天光门（shadeSurface 同窗同式，constants.glsl
    // 直射天光门分区）：sunVis 一并乘 skyGate——雾色直射分量 / 命中段雾直射 / 镜中日 / 月盘
    //（下方 waterSkyReflection 的 sunVisibility 入参）在洞穴 / 深室内水面（lm.y ≈ 0）随直射泄漏
    // 一同归零；glint 另有更严的 lmGate（0.5→1.0 室内档）主导、行为不变
    float skyGate = smoothstep(DIRECT_SKYLIGHT_GATE_LOW, DIRECT_SKYLIGHT_GATE_HIGH, lm.y);
    skyGate *= skyGate;
    skyGate *= skyGate; // pow4 整形（shadeSurface 同款——窄窗起坡陡过渡硬，爬升推向窗上沿）
#ifdef DIM_NO_DIRECT_LIGHT
    // 维度无天光（下界 / 末地，2026-10）：直射统一本地值整段剔除（shadeSurface / forwardEntityShade
    // 同纪律——此前只经天光门乘零）——雾色直射分量 / 波面起伏 / 命中段雾直射 / glint 结构性为零；
    // sunVis / skyGate 仍供下方 waterSkyReflection 的 sunVisibility 实参（DIM 下该函数首行即返回
    // 常量维度天色、实参为死参，sunVis×skyGate = 0 亦无视觉路径）
    vec3 directIrradianceLit = vec3(0.0);
#else
    vec3 directIrradianceLit = directIrradiance * (sunVis * skyGate);
#endif

    // ---- 折射（春v2 waterRefractionCoord 的像素域改写）：波扰动（去基面 up）推背景采样位，
    // 距离衰减防远水拉扯；采样位钳在渲染子区域内（TAAU / SR_UPSCALE 区域外是上帧全屏残留）----
    vec2 viewSize = vec2(viewWidth, viewHeight);
#if defined(TAAU) || defined(SR_UPSCALE)
    vec2 regionMax = ceil(viewSize * EFFECTIVE_RENDER_SCALE) - 1.5;
#else
    vec2 regionMax = viewSize - 1.5;
#endif
    vec3 perturbV = mat3(gbufferModelView) * (normalW - vec3(0.0, 1.0, 0.0));
    // 位移符号随视角分叉（2026-10，与下方守卫同批）：Snell 向量式的透射切向分量 = eta × 入射
    // 切向分量（方向不变、只缩放）——同一波面法线下水上俯视与水下仰视的切向位移方向相反；
    // (normalW − up) 是按水上俯视入射（≈ −up）折算的切向代理，水下仰视（入射 ≈ +up）与其反号
    // → 翻号保持两侧相对方向物理一致（全局符号沿用春v2 既有约定，水上逐位不变）
    float refractSign = underwater ? 1.0 : -1.0;
    vec2 offsetPx = clamp(perturbV.xy * (refractSign * WATER_REFRACTION_STRENGTH * viewHeight / (distWorld + 0.5)),
                          vec2(-WATER_REFRACTION_MAX * viewHeight), vec2(WATER_REFRACTION_MAX * viewHeight));
    vec2 samplePx = clamp(gl_FragCoord.xy + offsetPx, vec2(0.5), regionMax);
    vec2 sampleFullUv;
    float bgDepth;
    {
        // 去抖基底与 deferred_init / composite_fog 同式（applyInverseJitter 参数版单真源）
        sampleFullUv = applyInverseJitter(samplePx / viewSize, jitterUv);
        bgDepth = texelFetch(depthtex1, ivec2(samplePx), 0).r;
    }
    vec3 bgViewPos = screenToViewCanonical(sampleFullUv, bgDepth);

    // 折射有效性守卫（春v2 useRefract，2026-10 视角分向）：折射落点与水面点的连线须穿向透射
    // 介质一侧——水上视角背景在水下（世界 y < −0.01：拽到岸壁上沿 / 桥面等水面以上几何时退回
    // 本像素直采，避免「背景被拽上岸」）、水下仰视背景在水上（y > +0.01 的镜像条件：拽回水下
    // 几何同样直采）。旧版只写水上条件：水下仰视的透射背景恒在水面以上 → 守卫恒触发 → 透过
    // 水面的折射扰动被整体禁用（水下无 Snell 窗波动，2026-10 检查发现修复）
    float bgDirY = dot(normalize(viewToWorldDirection(bgViewPos - viewPos)), vec3(0.0, 1.0, 0.0));
    if (bgDepth < 1.0 && (underwater ? bgDirY < 0.01 : bgDirY > -0.01)) {
        bgDepth = texelFetch(depthtex1, ivec2(gl_FragCoord.xy), 0).r;
        sampleFullUv = applyInverseJitter(gl_FragCoord.xy / viewSize, jitterUv);
        bgViewPos = screenToViewCanonical(sampleFullUv, bgDepth);
        samplePx = gl_FragCoord.xy;
    }
    // 背景色 bilinear（折射扭曲的平滑过渡）；gaux1 = colortex4 背景快照（编码 × 解码见文件头——
    // 位移落点踩进本 draw 其他水像素时读到的恒是写入前的稳定场景，裂缝根治）
    vec3 color = textureLod(gaux1, samplePx / viewSize, 0.0).rgb * bgDecode;

    // ---- 水雾（水上视角；水下路径的雾由 composite_fog 按眼到水面距离结算、此处不施）----
    float deep = max(length(bgViewPos) - distWorld, 0.0); // 水深 ≈ 相机距背景 − 相机距水面（春v2 同式）
#ifdef WATER_FOG
    if (!underwater) {
        // 雾基色 = 常量混生物群系水色（顶点色），不含纹理色（见入参注释）
        vec3 fogBase = clamp(mix(WATER_FOG_COLOR, srgbToLinear(waterColorSrgb), WATER_FOG_BIOME_MIX),
                             vec3(0.0), vec3(1.0));
        // 波面漫反射起伏（春v2 lightFactor 的重组，2026-10）：旧式「三项和整体 × mix(1, N·L, 0.5)」把
        // 天空环境 / 地板一并压平、且正午 N·L 实际波动仅 ±3%（波面倾角 ~24°）——水面「光照平」的
        // 根源；重组为起伏只调制直射项——乘进 directIrradiance 入参，waterFogLitColor 内 sunTint 随之
        // 缩放（skyAmbient / MIN_AMBIENT 平稳：波谷也在收天空光），pow 提对比（低角度太阳下 N·L 分布
        // 更宽、波面明暗自然更强）
        float sunLift = mix(1.0, pow(clamp(dot(normalW, lightDirWorld), 0.0, 1.0), WATER_DIFFUSE_POWER),
                            WATER_DIFFUSE_STRENGTH);
        vec3 fogLit = waterFogLitColor(fogBase, directIrradianceLit * sunLift, skyAmbient, WATER_FOG_SUN_SCALE, WATER_FOG_SKY_SCALE,
                                       WATER_FOG_BRIGHTNESS)
                    * clamp(lm.y, 0.0, 1.0);
        color *= exp(-(vec3(1.0) - fogBase) * deep * WATER_FOG_TRANSMIT);
        color = mix(color, fogLit, clamp(deep / WATER_MIST_VISIBILITY, 0.0, 1.0));
    }
#endif

    // ---- 反射：SSR 命中取场景色，未命中 / 出屏走天空回退（屏幕边缘向天空回退淡出已按反馈移除，
    // 2026-10——0.1 uv 带宽观感过宽：命中整段取快照色、出屏即 miss 硬切向天空，边缘带交 TAA
    // 收敛；git 历史含完整形态）----
    vec3 reflDirW = reflect(viewDirW, normalW);
    // 反射方向背向回退（水上视角，2026-10）：波面坡度在掠射视角下会把反射向量压到几何面背侧（与
    // 几何面法线点积 ≤ 0）——物理上该射线扎回相邻波面成波间多次散射、照不到湖底；不处理则 SSR march
    // 顺着 depthtex1（含水下几何、不含水面）把折射里已见的湖底再当反射画一遍（同一信息双重计费 +
    //「空气侧反射照见水下」的非法光路）。检测到背向即整支丢弃波面扰动、直接改用几何面法线与视线形成
    // 的镜面反射方向——该方向恒在几何面的空气侧（视线自空气侧入射、镜像同侧），且同一视角下回退方向
    // 逐像素恒定、不随波场逐帧摆动；两入参均已归一、reflect 保长无需再归一。基面 2026-10 竖直流面修复
    // 起为朝空气侧定向的**几何面法线**（水平面 = 世界 up、行为逐位不变；竖直流面在面法线平面内镜像——
    // 掠射瀑布照见面前的岸壁 / 水潭而非倒映天空）。曾为「世界 y 抬到 WATER_REFL_MIN_UP 后归一」的
    // 地平线钳制档（2026-10 按反馈改为顶点法线回退、常量随删，git 历史含完整形态）。水下视角不检测
    // ——TIR 反射合法射向水体另一侧（镜像水下世界，竖直流面上亦然）。reflDirV 由回退后 reflDirW 旋转
    // 取得（reflect 与旋转可交换、两侧消费同一方向）
    if (!underwater && dot(reflDirW, faceNormalW) <= 0.0) {
        reflDirW = reflect(viewDirW, faceNormalW);
    }
    vec3 reflDirV = mat3(gbufferModelView) * reflDirW;
    float fresnel = waterFresnel(viewDirW, normalW, underwater);
    bool lutValid = skyLutValid > 0.5;

    vec3 reflColor = vec3(0.0);
    vec2 hitUv;
    // SSR 恒 march（免门）：此处曾有的 Fresnel 低值免 march 门（WATER_SSR_MIN_FRESNEL 0.03 ≈ 离法线
    // ~53° 锥，锥内跳过 march 直走天空回退）已按反馈移除（2026-10）——门的前提「锥内反射贡献
    // ≤ ~3%、俯视反射向量朝上大概率出屏 miss」在有高近景的场景（崖壁 / 湖边大树 / 沿岸建筑）不
    // 成立：锥内反射射线穿屏内景物、有真实命中，跳过 = 确定性误杀成天空色（近法线视角 Fresnel
    // 权重虽小，天空回退是 HDR 值、混入后仍可见），水面正下方「半径 ≈ 1.33 × 眼高的圆形区域恒
    // 镜天空」即其症状；锥内真正的出屏 miss 由回退分支自然处理。恒 march 后掠射侧行为逐位不变，
    // 近水侧新增的 march 成本多为出屏短段（视锥裁剪即终结）。常量随删，git 历史含完整形态
    float ssrConfidence = 0.0;
    float hitDepth;
    bool ssrHit = waterSSR(viewPos, reflDirV, distWorld, faceNormalW, hitUv, ssrConfidence, hitDepth);
    if (ssrHit) {
        // 命中色亦取背景快照（gaux1）：反射射线打到 depthtex1 上是湖底等不透明几何时，命中像素
        // 可能覆着本 draw 的水面——活缓冲同款竞态、快照恒为写入前场景
        reflColor = textureLod(gaux1, hitUv, 0.0).rgb * bgDecode;
        // 命中段雾（waterReflectionHitFog，头注见上）：命中 uv 重建命中点——去抖基底与折射背景
        // 同式（hitUv 为 buffer 域）；hitDepth 复用 SSR 验证的命中纹素深度，
        // 最终 UV 舍入跨纹素时由 SSR 内部补采样，保持旧深度取样语义
        vec2 hitFullUv = applyInverseJitter(hitUv, jitterUv); // 去抖基底同式（hitUv 为 buffer 域）
        vec3 hitViewPos = screenToViewCanonical(hitFullUv, hitDepth);
        waterReflectionHitFog(reflColor, viewPos, worldPos.y, hitViewPos, lm,
                              sunDirWorld, moonDirWorld, horizon, lutValid,
                              directIrradianceLit, skyAmbient);
    }
    if (!ssrHit || ssrConfidence < 1.0) {
        vec3 fallbackColor;
        // 天空回退随水顶点 lm.y 调暗（2026-10「暗处水面反射天空盒爆亮」修复；两级整形见
        // constants.glsl 的 WATER_REFL_SKY_GATE_*）：LUT 天空 + 云天空盒是天空条件的帧级内容、对
        // 「该水面是否敞向天空」一无所知——洞窟 / 室内水面的 SSR miss 回退恒镜像亮天空（爆亮根源）。
        // 门 = lm.y 的 [WATER_REFL_SKY_GATE_LOW, 1] 重映射到 [0,1]（水上暗处〔屋檐 / 桥下 / 洞口〕
        // 水面 lm.y 常停在 0.1~0.3 残余天光而非真 0——天空盒是 HDR，线性乘 10~30% 的亮度经 AgX 后
        // 依旧明晃晃，重映射把残余段压死）再过 srgbToLinear 同值的幂**回到线性域**（lm 光照级是
        // 感知域刻度、被门控的回退色是线性域 HDR）。乘在 waterSkyReflection 返回**之后**——函数内
        // 的镜中地平线边界雾带同为天空色，暗处须一并压暗（先门后雾会被雾色重新抬亮，顺序不可倒）。
        // 方块光不参与：火把照亮的室内水面照旧不应镜像天空；日 / 月盘已有更严的 skyGate（smoothstep
        // 门、与直射泄漏同窗）、叠加乘无害；SSR 命中侧不受影响（快照场景色自带正确光照）。
        // **门值为 0 时整链跳过（2026-10 性能）**：lm.y ≤ WATER_REFL_SKY_GATE_LOW 时 gate 恒 0、
        // 回退色被精确乘成 0——waterSkyReflection（两次 sky LUT 参数化 + fetch、日 / 月盘、云盒、
        // 镜中边界雾 LUT）无论求值为何都归零，跳过求值与「求值后 ×0」严格等价（乘 0 语义），
        // 洞窟 / 深室内水面的 miss 像素省全链 ~4 fetch + 2 acos；暗水区域空间连贯、warp 整体走跳过侧
        float skyReflGate = pow(remapSaturate(lm.y, WATER_REFL_SKY_GATE_LOW, 1.0, 0.0, 1.0),
                                WATER_REFL_SKY_GATE_GAMMA);
        if (skyReflGate > 0.0) {
            // sunVisibility 乘天光门（skyGate 定义见上——洞穴水面不镜像日 / 月盘，与直射泄漏同门）
            fallbackColor = waterSkyReflection(reflDirW, sunDirWorld, moonDirWorld, horizon, lutValid,
                                           sunVis * skyGate) * skyReflGate;
        } else {
            fallbackColor = vec3(0.0);
        }
        // 水下 TIR miss 回退压暗（WATER_UW_REFL_DIM × TINT）：水下反射方向朝下射回水体，
        // waterSkyReflection 对向下方向采到的是 LUT 下半区钳制辉光（+ 云盒边缘串色）——量级反超
        // 直接天空，镜面带观感「比天空还亮」；物理上应为被水下雾吸收的深水镜像。DIM 压亮度、TINT
        // 仿水体吸收把灰白辉光拉向蓝青（纯亮度缩放后发灰）。只压本回退色——Fresnel 权重与 SSR
        // 命中的真实镜像不动（见常量注）；0 值分支乘后仍精确 0
        if (underwater) fallbackColor *= WATER_UW_REFL_DIM * WATER_UW_REFL_TINT;
        reflColor = mix(fallbackColor, reflColor, ssrConfidence);
    }
    color = mix(color, reflColor, fresnel);

    // ---- 主导光源镜面高光（春v2 WATER_REFLECT_HIGH_LIGHT 的 lobe 化）：SSR 命中侧恒补——
    // 未命中侧的天空回退已含解析日 / 月盘（其镜像即是波面太阳 / 月亮），再加 lobe 会双重日月
    //（与春v2 的 `!ssrTargetSampled` 门控镜像：其 LUT 天空不含日盘、glint 补未命中侧，本包日 / 月
    // 盘都在天空回退内、方向反转。夜间未命中侧的月光带 = 镜中月盘 × Fresnel + LUT 月辉光——
    // 曾因月盘未画而「未命中侧补月 lobe」的分支已随月盘接入移除，行为对齐太阳侧）----
    if (ssrHit) {
        float glint = pow(clamp(dot(reflDirW, lightDirWorld), 0.0, 1.0), WATER_GLINT_EXP);
        float lmGate = remapSaturate(lm.y, 0.5, 1.0, 0.0, 1.0); // 室内水面不闪（春v2 lightmapMask 同锚点）
        color += directIrradianceLit * (glint * lmGate * fresnel * WATER_GLINT_BRIGHTNESS * ssrConfidence);
    }
    return color;
}

#endif

#endif
