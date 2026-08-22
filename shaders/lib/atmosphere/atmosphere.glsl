// 大气物理核心：Chapman 闭式光学深度 + 保能量单次散射（零 raymarch / 零 LUT / 零纹理采样）
// 移植自 Shadertoy WcdSW4（MIT，John Payne 2024）https://www.shadertoy.com/view/WcdSW4 ，五处适配：
//   1. INFINITY = 1/0 改 SKY_NO_HIT = 1e30 哨兵（编译期除零在部分驱动上未定义），
//      视线终点 -> 大气顶的消光仅在有限 t 时计算（哨兵路径直接取 0，免 Inf/NaN 参数白算）
//   2. 视线对准太阳时 (e^-tauS - e^-(tauSp+tauV)) / (tauSp+tauV-tauS) 分子分母同归零
//      （MC 太阳每天正午过天顶必踩，float32 近太阳锥形区还会因消劫出噪点）——
//      拆成 e^-tauS * (1-e^-x)/x 并对小 |x| 走泰勒保形分支 1 - x/2
//   3. r^2 - R^2 改 (r-R)(r+R) 防消劫：换小尺度高度参数时原式有 ~10% 亮度抖动
//   4. float32 溢出防护（erfcx 负支 exp 上限 SKY_ERFCX_EXP_MAX + airMass 钳制 SKY_AIRMASS_MAX，
//      见函数注释）——原式 |b| 可达 r/H ~ 45，exp(b²) 溢出 Inf，夜晚 / 下视路径产生 NaN / 负值 / 超大值
//   5. 臭氧系数弃用原作调参、按 Chappius 吸收带真实截面重定形状（原系数 R>G 与真实光谱 G>R 相反，
//      地平线长路径红衰减过快、日出天空发黄）——数值与来源链接见 constants.glsl OZONE_EXTINCTION_COEFFICIENTS 注释
// 夜侧无需特判：太阳沉入地平线后 tauS 随 sun 路 airMass 饱和于 SKY_AIRMASS_MAX（取得足够高，
// energyIntegralRatio 残留的 ~1/tauS 尾巴在自动曝光上限内不可见，见 constants.glsl），天空自然归零（曙暮光带自然呈现）
// 依赖由接入的 program 先行 include（lib 文件不嵌套 include）：lib/common/globals/constants.glsl（大气常量、PI）
#ifndef LIB_ATMOSPHERE_GLSL
#define LIB_ATMOSPHERE_GLSL

// 缩放互补误差函数 e^(x^2) * erfc(x)，任意符号参量的有理逼近（Shadertoy 原式）
// 负参量分支的 exp 上限钳制（SKY_ERFCX_EXP_MAX）：|b| 可达 r/H ~ 45（Mie），b² ~ 2000，
// float32 下 exp 溢出 Inf 即夜晚 / 下视路径 NaN 的根源；真值超过 e^80 的光学深度早已全遮蔽，钳顶无损
float erfcx(float x) {
    float t  = abs(x);
    float t2 = t * t;
    float A = 0.56418958354775629 / (t + 2.06955023132914151);
    float B = (t2 + 2.71078540045147805 * t + 5.80755613130301624) / (t2 + 3.47954057099518960 * t + 12.06166887286239555);
    float C = (t2 + 3.47469513777439592 * t + 12.07402036406381411) / (t2 + 3.72068443960225092 * t + 8.44319781003968454);
    float D = (t2 + 4.00561509202259545 * t + 9.30596659485887898) / (t2 + 3.90225704029924078 * t + 6.36161630953880464);
    float E = (t2 + 5.16722705817812584 * t + 9.1266167673673262) / (t2 + 4.03296893109262491 * t + 5.13578530585681539);
    float F = (t2 + 5.95908795446633271 * t + 9.19435612886969243) / (t2 + 4.11240942957450885 * t + 4.48640329523408675);
    float y = A * B * C * D * E * F;

    if (x < 0.0)
        return 2.0 * exp(min(t2, SKY_ERFCX_EXP_MAX)) - y;
    else
        return y;
}

// 指数大气单条光路的闭式光学深度（Chapman 函数）
// r 路径起点距地心、z 路径方向对天顶的余弦、t 路径长度（SKY_NO_HIT = 到大气顶无穷远）、H 该介质尺度高度
// 密度模型为 r² 高斯：exp(-(r²-R²)/H²)，有效尺度高度 = H²/(2R)（Rayleigh 8.05km / Mie 1.54km / 臭氧 16.3km，
// 即地球真实量级——H 本身是大数值的参数化，不是物理尺度高度）
// 返回值钳制 [0, SKY_AIRMASS_MAX]：下视掠射分支两支 erfcx 巨值相消在 float32 下是符号不定的垃圾
//（负值 / NaN→经钳制收敛到边界）；钳顶 1e15 下 τ = βmax × 上限 ≈ 2.9e10 → exp(-τ) = 0——上限刻意远高于
// exp 归零所需：夜侧 sun 路饱和后 tauS 冻结，energyIntegralRatio 的 ~1/tauS 残尾会成为夜空亮度地板（见 constants.glsl）
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

// Henyey-Greenstein 单叶
float henyeyGreensteinPhase(float mu, float g) {
    return 1.0 / (4.0 * PI) * (1.0 - g * g) / pow(1.0 + g * g - 2.0 * g * mu, 1.5);
}

// Draine 相函数（HG 的各向异性修正，较强后向瓣）
float drainePhase(float mu, float g, float a) {
    return (1.0 - g * g) * (1.0 + a * mu * mu)
         / (4.0 * (1.0 + (a * (1.0 + 2.0 * g * g)) / 3.0) * PI * pow(1.0 + g * g - 2.0 * g * mu, 1.5));
}

// Mie 相函数：HG(g1) 与 Draine(g2, a) 按权重 w 混合（Shadertoy 原调参）
float miePhase(float mu) {
    return mix(henyeyGreensteinPhase(mu, MIE_PHASE_G1),
               drainePhase(mu, MIE_PHASE_G2, MIE_PHASE_A),
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

// 起点沿给定方向到大气顶的 RGB 消光光学深度；球对称大气只依赖起点半径与方向天顶余弦。
// composite12 的 LUT 生成端在 vsh 中对太阳 / 月亮各算一次，经 varying 传入全部 LUT texel；
// 表面直射光的 solarTransmittance 同样复用，避免三套系数表达式漂移。
vec3 opticalDepthToSpace(float r, float z) {
    return RAYLEIGH_SCATTERING_COEFFICIENTS  * airMass(r, z, SKY_NO_HIT, RAYLEIGH_SCALE_HEIGHT)
         + MIE_EXTINCTION_COEFFICIENTS       * airMass(r, z, SKY_NO_HIT, MIE_SCALE_HEIGHT)
         + OZONE_EXTINCTION_COEFFICIENTS     * airMass(r, z, SKY_NO_HIT, OZONE_SCALE_HEIGHT);
}

// 单次散射天光（线性 HDR，未乘 SKY_BRIGHTNESS）
// origin 相机地心系位置、direction 视线方向（世界系，须归一化）、lightDirection 光源方向（同系归一化，太阳 / 月亮通用）、
// t 视线行星命中距离（SKY_NO_HIT = 朝天）、lightOpticalDepth 为起点沿光源方向到大气顶的消光
//（LUT 生成端在 vsh 中预计算）、irradiance 大气顶光源辐照度（SOLAR_IRRADIANCE / MOON_IRRADIANCE）
vec3 atmosphericRadiance(vec3 origin, vec3 direction, vec3 lightDirection,
                         vec3 lightOpticalDepth, float t, vec3 irradiance) {
    vec3  zenith = normalize(origin);
    float r   = length(origin);
    float z   = dot(direction, zenith);
    float zS  = dot(lightDirection, zenith);
    float mu  = dot(lightDirection, direction);

    // 视线路径（相机 -> t）的各介质 air mass：散射项与消光项共用（Rayleigh 散射 = 消光，Mie 消光 = 散射 × 1.11）
    vec3 rayleighView = RAYLEIGH_SCATTERING_COEFFICIENTS  * airMass(r, z, t, RAYLEIGH_SCALE_HEIGHT);
    vec3 mieView      = MIE_SCATTERING_COEFFICIENTS       * airMass(r, z, t, MIE_SCALE_HEIGHT);
    vec3 ozoneView    = OZONE_EXTINCTION_COEFFICIENTS     * airMass(r, z, t, OZONE_SCALE_HEIGHT);
    vec3 tauV = rayleighView + mieView * 1.11 + ozoneView;

    // 起点沿光源方向到大气顶的消光（日落红化的来源）；同一半区所有 texel 共用 vsh 预计算值。
    vec3 tauS = lightOpticalDepth;

    // 视线终点沿太阳方向到大气顶的消光，天空射线（未命中）取 0
    vec3 tauSp = vec3(0.0);
    if (t < 1e29) {
        float rP  = sqrt(t * t + 2.0 * z * r * t + r * r);
        float zSp = (zS * r + mu * t) / rP;
        tauSp = opticalDepthToSpace(rP, zSp);
    }

    // 保能量单次散射：视线路径上「被照亮部分」的加权（0/0 保形见 energyIntegralRatio）
    vec3 scatter;
    scatter.r = energyIntegralRatio(tauS.r, tauSp.r + tauV.r);
    scatter.g = energyIntegralRatio(tauS.g, tauSp.g + tauV.g);
    scatter.b = energyIntegralRatio(tauS.b, tauSp.b + tauV.b);

    return irradiance * (rayleighView * rayleighPhase(mu) + mieView * miePhase(mu)) * scatter;
}

// 太阳直射透过率（0~1，天顶白、地平线偏红、地平线下归零）
// 已接入 lighting.glsl 直射光：直射辐照度 = 大气顶辐照度（SOLAR / MOON_IRRADIANCE）× 本函数，
// origin 取表面点海拔（逐像素，光照库构造）；direction 须归一化
vec3 solarTransmittance(vec3 origin, vec3 direction) {
    vec3  zenith = normalize(origin);
    float r = length(origin);
    float z = dot(zenith, direction);

    return exp(-opticalDepthToSpace(r, z));
}

#endif
