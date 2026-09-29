// 大气物理核心：Chapman 闭式光学深度 + 保能量单次散射 + 各向同性环境场多次散射（零 raymarch）
// 移植自 Shadertoy WcdSW4（MIT，John Payne 2024）https://www.shadertoy.com/view/WcdSW4 ，五处适配：
//   1. inf 改 SKY_NO_HIT = 1e30 哨兵（编译期 1/0 在部分驱动上未定义）
//   2. 视线对准太阳的 (e^-tauS - e^-(tauSp+tauV)) / (tauSp+tauV-tauS) 0/0——energyIntegralRatio 泰勒保形
//   3. r²-R² 改 (r-R)(r+R) 防消劫（换小尺度参数时原式有 ~10% 亮度抖动）
//   4. float32 溢出防护：erfcx 负支 exp 上限 + airMass 钳制（原式 |b| 可达 r/H ~ 45，exp(b²) 溢出
//      Inf——夜晚 / 下视路径 NaN 的根源；上限取值的依据见 constants.glsl 的 SKY_ERFCX_EXP_MAX / SKY_AIRMASS_MAX）
//   5. 臭氧系数弃用原作调参、按 Chappius 吸收带真实截面重定（原系数光谱形状 R>G 与真实相反、
//      日出天空发黄）——数值与来源见 constants.glsl
// 夜侧无需特判：太阳沉入地平线后 tauS 随 airMass 饱和、天空自然归零（曙暮光带自然呈现）
// 多次散射：二阶起近似为「各向同性环境辐射场」（Hillaire 2020 / Wrenninge 多阶近似的最低档）——
//   环境场量级 = 一阶散射天光球面方向平均 L̄₁（skyAmbientField 的 48 节点环带求积）× 截获比几何级数
//   1/(1-ρ)；视线端 MS 项 = ambientCapture × 环境场，路径量全部复用单次散射已算的 airMass。
//   数值验证：正午天光辐照度 ×1.07~1.26、天顶 ×1.10~1.17、反日侧暮光地平线 ×1.6~1.7、夜空地板不抬高
// 依赖由接入的 program 先行 include：constants.glsl（大气常量、PI）
#ifndef LIB_ATMOSPHERE_GLSL
#define LIB_ATMOSPHERE_GLSL

// 缩放互补误差函数 e^(x^2) * erfc(x)，任意符号参量的有理逼近（Shadertoy 原式；六系数连乘
// 折叠为单次除法——各因子 O(1) 无溢出，与原式最大相对差 7e-7；erfcx 是 LUT 生成端每 texel
// 最高频的函数）。负参量分支 exp 上限钳制 SKY_ERFCX_EXP_MAX：|b| 可达 r/H ~ 45，exp(b²) 溢出
// Inf 即夜晚 / 下视 NaN 的根源；真值超过 e^80 的光学深度早已全遮蔽，钳顶无损
float erfcx(float x) {
    float t  = abs(x);
    float t2 = t * t;
    float num = 0.56418958354775629
              * (t2 + 2.71078540045147805 * t + 5.80755613130301624)
              * (t2 + 3.47469513777439592 * t + 12.07402036406381411)
              * (t2 + 4.00561509202259545 * t + 9.30596659485887898)
              * (t2 + 5.16722705817812584 * t + 9.1266167673673262)
              * (t2 + 5.95908795446633271 * t + 9.19435612886969243);
    float den = (t + 2.06955023132914151)
              * (t2 + 3.47954057099518960 * t + 12.06166887286239555)
              * (t2 + 3.72068443960225092 * t + 8.44319781003968454)
              * (t2 + 3.90225704029924078 * t + 6.36161630953880464)
              * (t2 + 4.03296893109262491 * t + 5.13578530585681539)
              * (t2 + 4.11240942957450885 * t + 4.48640329523408675);
    float y = num / den;

    if (x < 0.0)
        return 2.0 * exp(min(t2, SKY_ERFCX_EXP_MAX)) - y;
    else
        return y;
}

// 指数大气单条光路的闭式光学深度（Chapman 函数）
// r 路径起点距地心、z 路径方向对天顶的余弦、t 路径长度（SKY_NO_HIT = 到大气顶无穷远）、H 尺度高度
// 密度模型与有效尺度高度说明见 constants.glsl。返回值钳制 [0, SKY_AIRMASS_MAX]：下视掠射分支
// 两支 erfcx 巨值相消在 float32 下是符号不定的垃圾（钳制收敛到边界）；钳顶取值的依据见 constants.glsl
float airMass(float r, float z, float t, float H) {
    float a = 0.5 * sqrt(PI) * H * exp(-(r - EARTH_RADIUS) * (r + EARTH_RADIUS) / (H * H));
    float b = r * z / H;

    if (t > 1e29) // 哨兵即无穷远（调用方只传 SKY_NO_HIT 或有限行星命中距离）
        return clamp(a * erfcx(b), 0.0, SKY_AIRMASS_MAX);

    float c = t / H + b;
    float d = exp(min(b * b - c * c, SKY_ERFCX_EXP_MAX));

    if (z >= 0.0 || t + r * z >= 0.0)
        return clamp(a * (erfcx(b) - d * erfcx(c)), 0.0, SKY_AIRMASS_MAX);
    else
        return clamp(a * (d * erfcx(-c) - erfcx(-b)), 0.0, SKY_AIRMASS_MAX);
}

// (e^-a - e^-b) / (b - a) 的保形实现：b -> a（视线对准太阳）时极限为 e^-a
// 小 |x| 走泰勒 1 - x/2，免分子分母同归零的 0/0 与消劫
float energyIntegralRatio(float a, float b) {
    float x = b - a;
    if (abs(x) < 1e-4)
        return exp(-a) * (1.0 - x * 0.5);
    return (exp(-a) - exp(-b)) / x;
}

// Rayleigh 相函数（前后对称）
float rayleighPhase(float mu) {
    return 3.0 / (16.0 * PI) * (1.0 + mu * mu);
}

// Henyey-Greenstein 单叶（分母幂 1.5 写作 d·sqrt(d)——与 pow 等价且免 exp2/log2，d > 0 恒成立）
float henyeyGreensteinPhase(float mu) {
    float d = 1.0 + MIE_PHASE_G1 * MIE_PHASE_G1 - 2.0 * MIE_PHASE_G1 * mu;
    return 1.0 / (4.0 * PI) * (1.0 - MIE_PHASE_G1 * MIE_PHASE_G1) / (d * sqrt(d));
}

// Draine 相函数（HG 的各向异性修正，较强后向瓣；幂 1.5 同样写作 d·sqrt(d)）
float drainePhase(float mu) {
    float d = 1.0 + MIE_PHASE_G2 * MIE_PHASE_G2 - 2.0 * MIE_PHASE_G2 * mu;
    return (1.0 - MIE_PHASE_G2 * MIE_PHASE_G2) * (1.0 + MIE_PHASE_A * mu * mu)
         / (4.0 * (1.0 + (MIE_PHASE_A * (1.0 + 2.0 * MIE_PHASE_G2 * MIE_PHASE_G2)) / 3.0) * PI * d * sqrt(d));
}

// Mie 相函数：HG(g1) 与 Draine(g2, a) 按权重 w 混合（Shadertoy 原调参；g / a 参数由
// constants.glsl 的 MIE_PHASE_* 常量内嵌进两相函数，调用点单参）
float miePhase(float mu) {
    return mix(henyeyGreensteinPhase(mu),
               drainePhase(mu),
               MIE_PHASE_W);
}

// 视线与行星球面相交距离，未命中返回 SKY_NO_HIT
// r 起点距地心、z 视线天顶余弦（下视且相交时返回正距离，上视与掠射恒未命中）
float planetHitDistance(float r, float z) {
    // r²z² - (r²-R²)：把接近地表时的大数相减改写为 (r-R)(r+R)，
    // 避免地平线附近判别式在 float32 下丢失有效位。
    float altitudeTerm = (r - EARTH_RADIUS) * (r + EARTH_RADIUS);
    float d = r * r * z * z - altitudeTerm;
    if (d < 0.0)
        return SKY_NO_HIT;

    float root = sqrt(d);
    float t1 =  root - r * z;
    float t2 = -root - r * z;
    t1 = t1 < 0.0 ? SKY_NO_HIT : t1;
    t2 = t2 < 0.0 ? SKY_NO_HIT : t2;
    return min(t1, t2);
}

// 地平线方向钳制（春雷 ClampDirToHorizon 同款、+Y 天顶系简化式）：低于观察者地平线的方向投影到
// 水平面后重抬到与地球（EARTH_RADIUS）正好相切的观察者地平线切线仰角——方位保留、只抬高度；
// 天底方向（水平分量近零）方位退化取 +X 基准（与 sky.glsl skyViewLutAzimuthParam 的退化基准一致）。
// out clamped 标记方向被钳制：精确切线使 planetHitDistance 判别式在精确数学下 = 0、float 舍入噪声
// 令命中判定掷硬币（海拔 <= 0 的水平钳制分支更会 t = 0 → airMass = 0 → 黑纹素），调用方对钳后
// 射线一律按未命中处理（切线与地表仅切于一点、继续走向大气顶）。消费纪律：散射路径
//（airMass / tauSp 端点几何）用返回值，相位函数用原方向（mu 的角向变化是地平线
// 以下天空的明暗来源）；观察者位于地表及以下时切线不存在、退化为钳到水平
vec3 clampDirectionToHorizon(float observerRadius, vec3 dirWorld, out bool clamped) {
    float horizonCos = observerRadius > EARTH_RADIUS
        ? -sqrt(max((observerRadius - EARTH_RADIUS) * (observerRadius + EARTH_RADIUS), 0.0)) / observerRadius
        : 0.0;

    clamped = dirWorld.y < horizonCos;
    if (!clamped)
        return dirWorld;

    vec2 horizontal = dirWorld.xz;
    float hLen = length(horizontal);
    horizontal = hLen < 1e-4 ? vec2(1.0, 0.0) : horizontal / hLen;
    float horizonSin = sqrt(max(1.0 - horizonCos * horizonCos, 0.0));
    return vec3(horizontal.x * horizonSin, horizonCos, horizontal.y * horizonSin);
}

// 起点沿给定方向到大气顶的 RGB 消光光学深度；球对称大气只依赖起点半径与方向天顶余弦。
// composite12 的 LUT 生成端在 vsh 中对太阳 / 月亮各算一次，经 varying 传入全部 LUT texel；
// 表面直射光的 solarTransmittance 同样复用，避免三套系数表达式漂移。
vec3 opticalDepthToSpace(float r, float z) {
    return RAYLEIGH_SCATTERING_COEFFICIENTS  * airMass(r, z, SKY_NO_HIT, RAYLEIGH_SCALE_HEIGHT)
         + MIE_EXTINCTION_COEFFICIENTS       * airMass(r, z, SKY_NO_HIT, MIE_SCALE_HEIGHT)
         + OZONE_EXTINCTION_COEFFICIENTS     * airMass(r, z, SKY_NO_HIT, OZONE_SCALE_HEIGHT);
}

// 各向同性辐射场沿视线路径的散射截获比：散射反照率 × (1 - e^(-tauV))，即一束各向同性
// 辐射沿该视线穿行时被再散射出的份额（多次散射视线端的核心量）
// 分母 max 防御 t = 0 的地面垂直下视线（三介质 airMass 同时归零的 0/0）；rayleighView +
// mieView <= tauV 恒成立（臭氧纯吸收、Mie 消光 >= 散射），结果恒 ∈ [0,1]，tauV 巨大时
// exp 归零、退化为散射反照率
vec3 ambientCapture(vec3 rayleighView, vec3 mieView, vec3 tauV) {
    vec3 scatterAlbedo = (rayleighView + mieView) / max(tauV, vec3(1e-8));
    return scatterAlbedo * (vec3(1.0) - exp(-tauV));
}

// 单次散射天光（线性 HDR，未乘 SKY_BRIGHTNESS）——多次散射环境场 skyAmbientField 的求积
// 也调用本函数（不得改调含 MS 的 atmosphericRadiance：环境场会把 MS 再折进自身、双计）
// out viewCapture = 本视线的各向同性散射截获比（atmosphericRadiance 的 MS 项与 skyAmbientField
// 的截获比 ρ 统计共用一份 airMass，免二次求值）
// direction 与 phaseDirection 分离（春雷 GetSkyView 的 rayDir / phaseDir 同款语义）：direction 走
// 散射路径（airMass / tauSp 端点几何，地平线钳制时传钳后方向）、phaseDirection 只进相函数 mu（传
// 未钳制的原始方向，保地平线以下的角向明暗）；不钳制的调用方两参传同一方向即逐位等价
// origin 相机地心系位置、direction 视线方向（世界系，须归一化）、lightDirection 光源方向（同系归一化，太阳 / 月亮通用）、
// t 视线路径长度（SKY_NO_HIT = 到大气顶无穷远；天空 LUT 传行星命中距离、aerial LUT 传有限等效
// 距离——含 tauSp 端点几何的有限路径积分原生支持）、lightOpticalDepth 为起点沿光源方向到大气顶的
// 消光（LUT 生成端在 vsh 中预计算）、irradiance 大气顶光源辐照度（SOLAR_IRRADIANCE / MOON_IRRADIANCE）
// out viewCapture = 本视线的各向同性散射截获比（atmosphericRadiance 的 MS 项与 skyAmbientField 的
// 截获比 ρ 统计共用一份 airMass，免二次求值）；out viewTransmittance = exp(−tauV) 视线路径透射率
//（aerial LUT 的表面衰减项；tauV 只依赖 origin/direction/t、与光源无关，多光源调用返回同值）
vec3 atmosphericRadianceSingle(vec3 origin, vec3 direction, vec3 phaseDirection, vec3 lightDirection,
                               vec3 lightOpticalDepth, float t, vec3 irradiance,
                               out vec3 viewCapture, out vec3 viewTransmittance) {
    vec3  zenith = normalize(origin);
    float r   = length(origin);
    float z   = dot(direction, zenith);
    float zS  = dot(lightDirection, zenith);
    float mu  = dot(lightDirection, phaseDirection);
    float muRay = dot(lightDirection, direction);

    // 视线路径（相机 -> t）的各介质 air mass：散射项与消光项共用（Rayleigh 散射 = 消光，Mie 消光 = 散射 × 1.11）
    vec3 rayleighView = RAYLEIGH_SCATTERING_COEFFICIENTS  * airMass(r, z, t, RAYLEIGH_SCALE_HEIGHT);
    vec3 mieView      = MIE_SCATTERING_COEFFICIENTS       * airMass(r, z, t, MIE_SCALE_HEIGHT);
    vec3 ozoneView    = OZONE_EXTINCTION_COEFFICIENTS     * airMass(r, z, t, OZONE_SCALE_HEIGHT);
    vec3 tauV = rayleighView + mieView * 1.11 + ozoneView;

    // 起点沿光源方向到大气顶的消光（日落红化的来源）；同一半区所有 texel 共用 vsh 预计算值。
    vec3 tauS = lightOpticalDepth;

    // 视线终点沿太阳方向到大气顶的消光，天空射线（未命中）取 0；zSp 端点几何跟射线方向
    //（muRay 而非相位 mu——dot(lightDir, P̂) 的几何关系属于路径，不属于角分布）。
    // rP 钳贴地：aerial LUT 的等效路径是「沿视线方向走 t_eff 米」（放大语义），下视远距时虚拟
    // 终点半径会低于 EARTH_RADIUS（虚拟钻地）——钳到地表使 tauSp 取贴地端点（下视远处的端点
    // 消光，日落俯视时「山下雾暗、山上雾亮」分层的来源）；天空 LUT 的行星命中路径终点本就在
    // 地表附近、本钳制为无操作
    vec3 tauSp = vec3(0.0);
    if (t < 1e29) {
        float rP  = sqrt(t * t + 2.0 * z * r * t + r * r);
        rP = max(rP, EARTH_RADIUS);
        float zSp = (zS * r + muRay * t) / rP;
        tauSp = opticalDepthToSpace(rP, zSp);
    }

    // 保能量单次散射：视线路径上「被照亮部分」的加权（0/0 保形见 energyIntegralRatio）
    vec3 scatter;
    scatter.r = energyIntegralRatio(tauS.r, tauSp.r + tauV.r);
    scatter.g = energyIntegralRatio(tauS.g, tauSp.g + tauV.g);
    scatter.b = energyIntegralRatio(tauS.b, tauSp.b + tauV.b);

    viewCapture = ambientCapture(rayleighView, mieView, tauV);
    viewTransmittance = exp(-tauV);
    return irradiance * (rayleighView * rayleighPhase(mu) + mieView * miePhase(mu)) * scatter;
}

// 各向同性环境场（多次散射源项）：一阶天光球面平均 L̄₁ × 截获比几何级数 1/(1-ρ)，
// 调用端直接乘 ambientCapture 即得视线 MS 项；composite12 的 vsh 每帧每光源一次（48 节点 × ~10
// airMass，相对 40k LUT texel 可忽略）、经 varying 传入。求积节点锚定光源方向（等立体角环带、
// 带间黄金角错位）：太阳移动时节点图案随光源整体旋转，不随太阳位置错相跳变（残余为 ±10% 静态
// 偏差，进游戏并入 SKY_MS_STRENGTH 校准）；夜侧 L̄₁ 继承 tauS 饱和归零、MS 随光源熄灭。
// observerRadius / lightOpticalDepth 由 composite12 vsh 预计算（与 LUT 生成端同源）
vec3 skyAmbientField(float observerRadius, vec3 lightWorld,
                     vec3 lightOpticalDepth, vec3 irradiance) {
    // 光源锚定正交基（光源近天顶时换基准轴，免叉积退化）
    vec3 axisU = normalize(cross(abs(lightWorld.y) < 0.9 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0),
                                 lightWorld));
    vec3 axisV = cross(lightWorld, axisU);
    vec3 origin = vec3(0.0, observerRadius, 0.0);

    vec3 fieldSum   = vec3(0.0);
    vec3 captureSum = vec3(0.0);
    for (int band = 0; band < SKY_MS_QUAD_BANDS; band++) {
        // 等立体角环带：Δcosθ = 2 / 环带数，环带中心 cosθ ∈ (2band+1)/BANDS 关于 0 对称
        float cosTheta = 1.0 - (float(band) + 0.5) * (2.0 / float(SKY_MS_QUAD_BANDS));
        float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));
        for (int j = 0; j < SKY_MS_QUAD_AZIMUTHS; j++) {
            float phi = (float(j) + 0.5) * (TAU / float(SKY_MS_QUAD_AZIMUTHS))
                      + float(band) * GOLDEN_ANGLE;
            vec3 dir = lightWorld * cosTheta
                     + (axisU * cos(phi) + axisV * sin(phi)) * sinTheta;
            float t = planetHitDistance(observerRadius, dir.y);
            vec3 capture;
            vec3 captureTrans; // 透射率 out 占位（环境场只消费 capture）
            // 求积方向两参同值（环境场是球面平均的物理量，不钳制——地平线下的暗贡献本就应计入）
            fieldSum += atmosphericRadianceSingle(origin, dir, dir, lightWorld, lightOpticalDepth,
                                                  t, irradiance, capture, captureTrans);
            captureSum += capture;
        }
    }
    float weight = 1.0 / float(SKY_MS_QUAD_BANDS * SKY_MS_QUAD_AZIMUTHS);
    vec3 rho = clamp(captureSum * weight, vec3(0.0), vec3(SKY_MS_CAPTURE_MAX));
    return fieldSum * weight / (vec3(1.0) - rho);
}

// 单次 + 多次散射天光（线性 HDR，未乘 SKY_BRIGHTNESS）：单次散射 + 各向同性环境场沿视线
// 的再散射（ambientCapture × ambientField × SKY_MS_STRENGTH，强度 0 = 退回纯单次散射）；
// ambientField = skyAmbientField 的预计算值（vsh 每帧每光源一次、经 varying 传入），
// direction / phaseDirection 的分离语义与 atmosphericRadianceSingle 一致（钳制路径 + 未钳制相位）；
// out viewTransmittance = 视线路径透射率（aerial LUT 消费，透传自 atmosphericRadianceSingle）
vec3 atmosphericRadiance(vec3 origin, vec3 direction, vec3 phaseDirection, vec3 lightDirection,
                         vec3 lightOpticalDepth, float t, vec3 irradiance,
                         vec3 ambientField, out vec3 viewTransmittance) {
    vec3 viewCapture;
    vec3 single = atmosphericRadianceSingle(origin, direction, phaseDirection, lightDirection,
                                            lightOpticalDepth, t, irradiance, viewCapture, viewTransmittance);
    return single + viewCapture * ambientField * SKY_MS_STRENGTH;
}

// 太阳直射透过率（0~1，天顶白、地平线偏红、地平线下归零）：直射辐照度 = 大气顶辐照度 × 本函数；
// deferred_init 取 vsh 相机高度近似调用（经 vDirectTransmittance varying），逐表面点路径保留此入口
vec3 solarTransmittance(vec3 origin, vec3 direction) {
    vec3  zenith = normalize(origin);
    float r = length(origin);
    float z = dot(zenith, direction);

    return exp(-opticalDepthToSpace(r, z));
}

#endif
