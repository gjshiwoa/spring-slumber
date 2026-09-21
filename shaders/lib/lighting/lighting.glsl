// 表面光照（线性空间，直接光物理化——春雷 shading.glsl 同构）：全部光项以辐照度汇总、末尾统一乘
// Lambert BRDF = albedo/π：
//   直射 E = vDirectIrradiance（vsh 帧数据：统一时间系统门控加权和 + 雨天衰减）× directTransmittance
//           （调用方传入；deferred_init 以相机高度近似、vsh 中算一次经 varying 复用）
//   天空环境光 / 方块光为辐照度形式（定量见 constants.glsl）；环境基色 = LUT 天顶色 ×
//   SKY_AMBIENT_BRIGHTNESS（vsh 探针，与渲染天空同源），雨天去饱和已在 vsh 预并入
// 阴影超距 / 出屏按全亮；晨昏主光源切换的阴影跳变由 vDirectIrradiance 同窗淡黑吸收
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
// viewPos    观察空间位置（deferred_init 由去抖 NDC + depthtex1 重建）——函数内部统一换算一次
//            relativeWorldPos（阴影采样共用，免重复矩阵乘）
// directTransmittance 调用方预计算的大气直射透射率
// sssStrength 次表面散射强度 [0,1]（materialSSSStrength：植被 = VEGETATION_SSS_STRENGTH 硬编码、其余 = 0）——
//            分别线性缩放 wrap 重映射量（SSS_WRAP_MAX）与阴影软化半径（shadow.glsl），
//            0 = 普通表面走原 max(ndl, 0) 路径
vec3 shadeSurface(vec3 albedo, vec3 normalView, vec2 lm, vec3 viewPos, vec3 directTransmittance,
                  float sssStrength) {
    // mat3 纯旋转保持单位长度（入参见函数头契约），免 normalize
    vec3 normalWorld = viewToWorldDirection(normalView);
    vec3 lightDirWorld = vLightDirection; // 世界系阴影主光源方向（vsh 帧数据）

    vec3 relativeWorldPos = viewToRelativeWorld(viewPos);
    float distWorld = length(relativeWorldPos);

    // 直射余弦的 SSS wrap 重映射（春v2 同式）：cos = saturate((ndl + w) / (1 + w))，w = SSS_WRAP_MAX ×
    // 强度——把明暗界拓宽到背光侧（薄叶透光使整株近均匀受光、明暗只由阴影贴图区分）；同一强度线性
    // 缩放阴影软化半径；w = 0 时退化为 max(ndl, 0)、非 SSS 表面行为不变
    float ndl = dot(normalWorld, lightDirWorld);
    float sssWrap = SSS_WRAP_MAX * sssStrength;
    float ndlWrapped = clamp((ndl + sssWrap) / (1.0 + sssWrap), 0.0, 1.0);

    // 直射光可见性：阴影贴图 PCF，门控用重映射后的余弦（背光 SSS 面也采样——穿墙漏光由阴影贴图把住）
    vec3 shadowVis = ndlWrapped > 0.0
        ? sampleShadowVisibility(relativeWorldPos, normalWorld, ndl, distWorld, sssStrength)
        : vec3(0.0);

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

    // 直射辐照度：大气顶辐照度 × 调用方传入的大气透射率。deferred_init 使用玩家 / 相机高度
    // 近似全部表面海拔，并在全屏 vsh 中每帧仅计算 3~4 次。
    vec3 directIrradiance = vDirectIrradiance * directTransmittance;

    // 光照图幂曲线：两分量统一 pow 4（连乘实现——平方再平方，免 pow 调用）
    vec2 lmPow4 = lm * lm;
    lmPow4 *= lmPow4;

    // 天空环境光：上半球亮、下半球暗的半球近似（辐照度形式）；天顶色的幅度 / 色调
    // 与雨天去饱和已在 vsh 帧数据基色预并入（与逐像素标量乘法可交换，数学等价）
    float hemisphere = 0.6 + 0.4 * clamp(normalWorld.y * 0.5 + 0.5, 0.0, 1.0);
    vec3 skyIrradiance = vSkyAmbient * (lmPow4.y * hemisphere);

    // 方块光（火把、萤石等），近距离衰减用幂曲线近似（辐照度形式）；线性小地板用原始 lm.x
    vec3 blockIrradiance = TORCHLIGHT_COLOR * (lmPow4.x * TORCHLIGHT_NEAR_SCALE + lm.x * TORCHLIGHT_FLOOR_SCALE);

    // Lambert BRDF = albedo/π，全部辐照度一次相乘（直射余弦取 wrap 重映射值）
    return (albedo / PI) * (directIrradiance * (ndlWrapped * shadowVis)
                          + skyIrradiance + blockIrradiance + MIN_AMBIENT);
}

#endif

#endif
