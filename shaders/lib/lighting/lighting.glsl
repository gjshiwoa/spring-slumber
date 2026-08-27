// 表面光照（线性空间，直接光物理化——春雷 shading.glsl 同构）
// 全部光项以辐照度（与大气同量级）汇总，最后统一乘 Lambert BRDF = albedo/π：
//   直射 E = vDirectIrradiance（通用全屏 vsh 算好的大气顶辐照度——统一时间系统太阳 / 月亮门控
//           加权和，主光源切换处为黑过渡 + 雨天衰减）
//           × directTransmittance（调用方显式传入；deferred_init 以玩家 / 相机高度近似，
//           在全屏 vsh 中计算一次并经 varying 复用）
//   天空环境光 / 方块光为辐照度形式（constants.glsl 定量）；环境基色 = 天顶大气结果 ×
//   SKY_AMBIENT_BRIGHTNESS（vsh 探针 rgb，与渲染天空同源——色调 / 幅度一并物理自适应），
//   雨天去饱和已在 vsh 帧数据预并入（与逐像素标量乘法可交换）
// 阴影贴图超距 / 出屏按全亮（sampleShadowVisibility 返回 1，无回退门控）；晨昏主光源切换的阴影
// 跳变由 vDirectIrradiance 同窗淡黑吸收（辐照度乘 0，任何可见性值都不可见）
// 帧数据取用（春v2 模式——lib 函数直接读 program 声明的同名 in varying 全局）：
//   vLightDirection / vDirectIrradiance / vSkyAmbient——由通用全屏 vsh
//   （program/fullscreen_vsh.glsl）输出，接入方 fsh 须在本文件 include 之前
//   声明同名 in（未来前向 program 如 water 共享本函数时，由其 vsh 输出同名 varying）
// 仅片段阶段（函数体引用阴影采样）；依赖由接入的 program 先行 include（lib 文件不嵌套 include）：
//   lib/common/globals/uniforms.glsl、lib/common/globals/constants.glsl（光照 / 阴影常量、PI）、
//   lib/common/utils/space.glsl（viewToWorldDirection / viewToRelativeWorld）、
//   lib/lighting/shadow.glsl（sampleShadowVisibility）
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

    // 直射余弦的 SSS wrap 重映射（春v2 deferred5 同式）：cos = saturate((ndl + w) / (1 + w))，
    // w = SSS_WRAP_MAX × 强度——把明暗界拓宽到背光侧，薄叶透光使整株近均匀受光、明暗只由阴影贴图
    // 区分；同一强度线性缩放阴影软化半径（sampleShadowVisibility），w = 0 时退化为 max(ndl, 0)、
    // 非 SSS 表面行为不变
    float ndl = dot(normalWorld, lightDirWorld);
    float sssWrap = SSS_WRAP_MAX * sssStrength;
    float ndlWrapped = clamp((ndl + sssWrap) / (1.0 + sssWrap), 0.0, 1.0);

    // 直射光可见性：阴影贴图 PCF，门控用重映射后的余弦（背光 SSS 面也采样——阴影贴图把住穿墙漏光，
    // 自身叶片遮挡由 normal offset 推出 + SSS 附加软半径部分漏光）。超距 / 出屏由采样端返回 1
    //（贴图覆盖外按全亮）；晨昏主光源切换的阴影跳变由 vDirectIrradiance 同窗淡黑吸收，无回退门控
    vec3 shadowVis = ndlWrapped > 0.0
        ? sampleShadowVisibility(relativeWorldPos, normalWorld, ndl, distWorld, sssStrength)
        : vec3(0.0);

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
    vec3 blockIrradiance = TORCHLIGHT_COLOR * (lmPow4.x * 1.30 + lm.x * 0.02);

    // Lambert BRDF = albedo/π，全部辐照度一次相乘（直射余弦取 wrap 重映射值）
    return (albedo / PI) * (directIrradiance * (ndlWrapped * shadowVis)
                          + skyIrradiance + blockIrradiance + MIN_AMBIENT);
}

#endif

#endif
