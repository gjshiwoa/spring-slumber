// 表面光照（线性空间，直接光物理化——春雷 shading.glsl 同构）：全部光项以辐照度汇总、末尾统一乘
// Lambert BRDF = albedo/π：
//   直射 E = vDirectIrradiance（vsh 帧数据：统一时间系统门控加权和 + 雨天衰减）× directTransmittance
//           （调用方传入；deferred_init 以相机高度近似、vsh 中算一次经 varying 复用）
//   天空环境光 / 方块光为辐照度形式（定量见 constants.glsl）；环境基色 = LUT 天顶色 ×
//   SKY_AMBIENT_BRIGHTNESS（vsh 探针，与渲染天空同源），雨天去饱和已在 vsh 预并入
// 直射另含 GGX 高光（DIRECT_SPECULAR，春雷 specularBrdfAnalytic 谱系——Schlick F × GGX D ×
//   Smith V 加性叠在漫反射之上，labPBR 高光贴图经 colortex4.ba 解包消费，见函数内注释）
// 阴影超距 / 出屏按全亮；晨昏主光源切换的阴影跳变由 vDirectIrradiance 同窗淡黑吸收
// 维度无天光（DIM_NO_DIRECT_LIGHT，下界 / 末地，2026-10）：直射项（wrap 余弦 / 阴影 / 天光门）
// 整段编译剔除、恒零——此前只经天光门乘零（计算照跑 + 押加载器 lmcoord 语义），实机反馈下界
// 疑似直射漏光后改结构性为零；光照退化为天空环境（lm.y⁴ 恒零）+ 方块光 + MIN_AMBIENT
// 帧数据取用（春v2 模式——lib 函数直接读 program 声明的同名 in 全局）：vLightDirection /
//   vDirectIrradiance / vSkyAmbient 由通用全屏 vsh 输出，接入方 fsh 须在本文件 include 之前声明
//   同名 in（未来前向 program 如 water 共享本函数时，由其 vsh 输出同名 varying）
// 仅片段阶段；依赖由接入的 program 先行 include：uniforms.glsl / constants.glsl（含 PI）/
//   utils/space.glsl（viewToWorldDirection / viewToRelativeWorld / remapSaturate）/
//   lighting/shadow.glsl（sampleShadowVisibility，SHADOW_SCREEN_SPACE 时兼 screenSpaceShadowVisibility）
#ifndef LIB_LIGHTING_GLSL
#define LIB_LIGHTING_GLSL

#ifdef STAGE_FRAGMENT

// 表面光照主入口
// albedo     线性反照率
// normalView 观图空间法线（单位向量——decodeOctahedral 出口已归一化，viewToWorldDirection
//            的 mat3 为纯旋转保长度，函数内免重复 normalize；调用方须传单位法线）
// lm         重映射后的光照图（x = 方块光，y = 天空光），见 common/pipeline/gbuffer_data.glsl remapLightmap
// viewPos    观察空间位置（deferred_init 由去抖 NDC + depthtex1 重建）——仅直射有贡献且启用阴影时
//            换算 relativeWorldPos（阴影采样共用，免重复矩阵乘）
// directTransmittance 调用方预计算的大气直射透射率
// sssStrength 次表面散射强度 [0,1]（materialSSSStrength：植被 = VEGETATION_SSS_STRENGTH 硬编码、其余 = 0）——
//            分别线性缩放 wrap 重映射量（SSS_WRAP_MAX）与阴影软化半径（shadow.glsl），
//            0 = 普通表面走原 max(ndl, 0) 路径
// specularMap labPBR 高光贴图原值（colortex4.ba 解包：r = 感知光滑度、g = 线性金属度、b/a 现无消费者）——
//            仅 DIRECT_SPECULAR 时消费（直射 GGX 高光，F0 在函数内与 albedo 组合）；无该宏 /
//            DIM_NO_DIRECT_LIGHT 时为死参
vec3 shadeSurface(vec3 albedo, vec3 normalView, vec2 lm, vec3 viewPos, vec3 directTransmittance,
                  float sssStrength, vec4 specularMap) {
    // mat3 纯旋转保持单位长度（入参见函数头契约），免 normalize
    vec3 normalWorld = viewToWorldDirection(normalView);

#ifndef DIM_NO_DIRECT_LIGHT
    vec3 lightDirWorld = vLightDirection; // 世界系阴影主光源方向（vsh 帧数据）

    // 直射余弦的 SSS wrap 重映射（春v2 同式）：cos = saturate((ndl + w) / (1 + w))，w = SSS_WRAP_MAX ×
    // 强度——把明暗界拓宽到背光侧（薄叶透光使整株近均匀受光、明暗只由阴影贴图区分）；同一强度线性
    // 缩放阴影软化半径；w = 0 时退化为 max(ndl, 0)、非 SSS 表面行为不变
    float ndl = dot(normalWorld, lightDirWorld);
    float sssWrap = SSS_WRAP_MAX * sssStrength;
    float ndlWrapped = clamp((ndl + sssWrap) / (1.0 + sssWrap), 0.0, 1.0);

    // 天光门（2026-10，constants.glsl 直射天光门分区）：lm.y 经 smoothstep 窗 [0.05, 0.10] 映 0~1
    // 再 pow4 整形（连乘实现、同 lmPow4 纪律免 pow 调用——窄窗内 smoothstep 起坡陡、过渡带硬，
    // pow4 把爬升推向窗上沿、暗侧平缓趋零）后乘进直射项——阴影贴图超距 / SS 追溯不可达处按全亮
    // 放行的直射泄漏由天光兜底（洞穴 / 深室内 lm.y ≈ 0 直射归零，露天 ≥ 2 级天光满额）；SSS 随
    // 直射项同门（透光是直射的子项）
    float skyGate = smoothstep(DIRECT_SKYLIGHT_GATE_LOW, DIRECT_SKYLIGHT_GATE_HIGH, lm.y);
    skyGate *= skyGate;
    skyGate *= skyGate;

    // 只在直射确有贡献时采阴影：零天光 / 零 wrap 余弦下直射严格为零，连带免世界位置重建、
    // PCF 与 SS trace（2026-10 低风险优化）。SSS 仍以 wrap 后余弦门控，不能改用原始 ndl。
    // 保留 smoothstep + pow4 的原门形状；环境光 / 方块光不受此分支影响。
    // 直射 GGX 高光（DIRECT_SPECULAR）同住本分支内——零贡献像素免付其 ~40 ALU
    vec3 directTerm = vec3(0.0);
    vec3 directSpecular = vec3(0.0);
    if (skyGate > 0.0 && ndlWrapped > 0.0) {
        // 玩家相对位置（完整逆视图含平移）：供阴影采样，不能直接归一化作视向量。
        // 旧版原点可在脚部，新版亦可能含视角晃动偏移；眼点不保证是此空间的零点
        vec3 relativeWorldPos = viewToRelativeWorld(viewPos);
#ifndef DIM_NO_SHADOW
        // 距离曲线以实际眼点为中心；relativeWorldPos 的原点在旧版可为脚部。
        float distWorld = length(viewPos);

        vec3 shadowVis = sampleShadowVisibility(relativeWorldPos, normalWorld, ndl, distWorld,
                                               sssStrength, lm.y);

#ifdef SHADOW_SCREEN_SPACE
        // 屏幕空间追踪阴影（shadow.glsl，min 合成只加暗——乘会把 PCF 半影与 SS 半影叠乘过暗）：
        // 适用范围（春v2 结构、锚点外推）——近景（< NEAR_BOUNDARY·D）只 trace 向光非 SSS：薄叶透光
        // 是植被观感的立身之本，沿光向的自遮挡 trace 会把背光辉光整体抹黑；远景（接管区）向光或 SSS
        // 均 trace：0.9D 外树冠必须有影、透光观感让位——SSS 结果在 NEAR_BOUNDARY→HANDOVER 从 1.0
        // 渐入全效（HANDOVER = 贴图淡出窗起点，0.7 / 0.9 / 1.0 三锚点交接链）。背光非 SSS 永不
        // trace：其 wrap 余弦 = 0、直射本就为 0，纯省成本。贴图可见性门在 min 语义下排除全影像素
        //（D 外贴图恒 1、门自然放行 = 接管区照常 trace）；彩色阴影取最大通道判全影，不透明遮挡者
        // 命中把 rgb 整体压 0（玻璃后另有不透明物 = 全影）、玻璃自身不在 depthtex1、透射色语义保留
        bool nearRange = distWorld < SHADOW_SS_NEAR_BOUNDARY * shadowDistance;
        bool traceable = nearRange ? (ndl > 0.0 && sssStrength <= 0.0)
                                   : (ndl > 0.0 || sssStrength > 0.0);
        if (traceable && max(max(shadowVis.x, shadowVis.y), shadowVis.z) > SHADOW_SS_GATE) {
            float ssVis = screenSpaceShadowVisibility(viewPos, normalView, distWorld);
            float sssFade = sssStrength > 0.0
                ? remapSaturate(distWorld, SHADOW_SS_NEAR_BOUNDARY * shadowDistance,
                                SHADOW_SS_HANDOVER * shadowDistance, 0.0, 1.0)
                : 1.0;
            shadowVis = min(shadowVis, vec3(mix(1.0, ssVis, sssFade * SHADOW_SS_STRENGTH)));
        }
#endif
#else
        // 无阴影贴图但保留直射（DIM_NO_SHADOW 单独成立时）：可见性恒 1——现无维度落在该组合
        //（下界 / 末地的直射已被 DIM_NO_DIRECT_LIGHT 整段剔除、主世界阴影贴图恒在），保留作门控正交性
        vec3 shadowVis = vec3(1.0);
#endif

        // 大气顶辐照度 × 调用方传入的透射率；乘法顺序与原路径相同。
        directTerm = vDirectIrradiance * directTransmittance * skyGate * (ndlWrapped * shadowVis);

#ifdef DIRECT_SPECULAR
        // 直射 GGX 高光（春雷 specularBrdfAnalytic 谱系，单次散射、无 msEnergy LUT——粗糙面略暗于
        // 春雷全量档，低配取舍）：加性叠在漫反射之上（金属 F0 取 albedo 着色、diffuse 不做金属度
        // 衰减）。内层门 ndl > 0 用原始余弦——SSS wrap 拓宽到背光侧的像素无正面镜面（春雷同守卫，
        // 亦防 ndl < 0 乘出负光）；ndv > 0 排除贴图法线在掠射处背向视线的像素
        // 观察空间原点才是实际眼点：表面→眼睛先在观察系求方向，再仅旋转到世界轴向。
        // 等价于 normalize(gbufferModelViewInverse[3].xyz - relativeWorldPos)，
        // 但不做两位置相减，避免旧版地面处眼高抵消与掠射 NdotV 正负翻转。
        vec3 viewDirWorld = viewToWorldDirection(-normalize(viewPos));
        float ndv = dot(normalWorld, viewDirWorld);
        if (ndl > 0.0 && ndv > 0.0) {
            // labPBR 解码：α = (1−r)²（感知→线性）钳下限防 D 分母爆炸；金属度 g 线性
            float specAlpha = clamp((1.0 - specularMap.r) * (1.0 - specularMap.r), SPECULAR_ALPHA_MIN, 1.0);
            vec3 f0 = mix(vec3(0.04), albedo, clamp(specularMap.g, 0.0, 1.0));

            vec3 halfDir = normalize(viewDirWorld + lightDirWorld);
            // GGX D（春雷 distributionGgx 同式：sin²θ 以叉积模平方直取，ndh→1 无精度消减）
            float ndh = clamp(dot(normalWorld, halfDir), 0.0, 1.0);
            vec3 nCrossH = cross(normalWorld, halfDir);
            float alpha2 = specAlpha * specAlpha;
            float dDenom = dot(nCrossH, nCrossH) + alpha2 * ndh * ndh; // sin²θ + α²cos²θ
            float dGgx = alpha2 / (PI * dDenom * dDenom);
            // Smith 相关可见性 V（春雷 visibilitySmithGgxCorrelated 同式；ndl / ndv 已由门保证 > 0）
            float viewMask = ndl * sqrt(ndv * ndv * (1.0 - alpha2) + alpha2);
            float lightMask = ndv * sqrt(ndl * ndl * (1.0 - alpha2) + alpha2);
            float visibility = 0.5 / max(viewMask + lightMask, 1e-10);
            // Schlick F（pow5 连乘免 pow 调用，同 skyGate pow4 纪律）
            float vdh = clamp(dot(viewDirWorld, halfDir), 0.0, 1.0);
            float grazing = 1.0 - vdh;
            grazing *= grazing;
            grazing *= grazing;
            grazing *= 1.0 - vdh;
            vec3 fresnel = f0 + (vec3(1.0) - f0) * grazing;

            // 与漫反射直射项同源同门（辐照度 / 透射率 / 天光门 / 阴影可见性〔彩色——彩色玻璃
            // 下高光随之染色〕），辐照度 × NdotL 形式同春雷；整项不经 albedo/π（镜面非漫反射）
            directSpecular = vDirectIrradiance * directTransmittance * skyGate * (ndl * shadowVis)
                           * fresnel * (dGgx * visibility) * DIRECT_SPECULAR_STRENGTH;
        }
#endif
    }
#else
    // 维度无天光（DIM_NO_DIRECT_LIGHT，下界 / 末地，2026-10）：直射项**整段编译剔除**——此前只经
    // 天光门（lm.y 恒 0）乘零归零：wrap 余弦 / 天光门 / 相对世界重建照跑，且正确性押在加载器
    // lmcoord 语义上（实机反馈下界疑似直射漏光后改结构性为零）；SSS 为直射子项随之消失（两维度
    // 标记恒空、强度本就为 0），直射 GGX 高光同段剔除。directTransmittance / sssStrength /
    // specularMap 入参与 viewPos 的直射侧消费成为死参、由调用方 / 链接器自然剔除
    vec3 directTerm = vec3(0.0);
    vec3 directSpecular = vec3(0.0);
#endif

    // 光照图幂曲线：两分量统一 pow 4（连乘实现——平方再平方，免 pow 调用）
    vec2 lmPow4 = lm * lm;
    lmPow4 *= lmPow4;

    // 天空环境光：上半球亮、下半球暗的半球近似（辐照度形式）；天顶色的幅度 / 色调
    // 与雨天去饱和已在 vsh 帧数据基色预并入（与逐像素标量乘法可交换，数学等价）
    float hemisphere = 0.6 + 0.4 * clamp(normalWorld.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyIrradiance = vSkyAmbient * (lmPow4.y * hemisphere);

    // 方块光（火把、萤石等），近距离衰减用幂曲线近似（辐照度形式）；线性小地板用原始 lm.x
    vec3 blockIrradiance = TORCHLIGHT_COLOR * (lmPow4.x * TORCHLIGHT_NEAR_SCALE + lm.x * TORCHLIGHT_FLOOR_SCALE);

    // Lambert BRDF = albedo/π，全部辐照度一次相乘（直射余弦取 wrap 重映射值）；直射 GGX 高光
    // 加性叠在其上（镜面项非漫反射、不经 albedo/π）
    return (albedo / PI) * (directTerm + skyIrradiance + blockIrradiance + MIN_AMBIENT) + directSpecular;
}

#endif

#endif
