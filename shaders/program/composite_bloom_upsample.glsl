// Bloom 上采样回卷 pass: composite_bloom_upsample（composite9~12 入口，入口定义 BLOOM_LEVEL = 目标 tile 3~0）
// 金字塔自粗向细逐级合并：tile BLOOM_LEVEL = 本级原始内容 × 级权重 + 上一 pass 已合并粗级的
// tent 放大 2 倍相加（bloomUpsampleTile），粗级模糊经逐级 tent 累积成连续衰减；每 pass 重写整个
// 图集包围盒（非 tile 像素复制回写、不 discard——BLOOM_LEVEL 0 兼写 colortex7 须区域整写），
// 跨 pass 保值、对 main/alt 翻转语义免疫、无需 flip.*；tile4 恒为原始下采样内容供 composite12 测光
// BLOOM_LEVEL == 0（composite12）：colortex7 唯一写入者，光栅 quad 自图集包围盒扩为「包围盒 ∪
// 天空 LUT 区域」的包围矩形、一 pass 兼管全部槽位（协议见 AGENTS.md 缓冲布局）。colortex1 的
// tile 逻辑对全部光栅像素照常执行——槽位区域与 tile0 在 uv 上重叠但两缓冲互不相干，outMisc 分支
// 不得干涉 outColor（否则 tile0 凿洞、final 放大后成屏幕黑矩形）：
//   - 天空 view LUT：日 / 月半区各 200×100 逐纹素重算（帧常量在 vsh 预计算经 varying 传入，
//     低于 SKY_LIGHT_MIN_HEIGHT 的非活动光源整半区写 0）
//   - 云层天空盒（CLOUDS_2D）：[0,256)² 八面体逐 texel getPlanarCloudsWorld 全量重算（与主天空
//     同一单真源；下行视线行星命中早退、只上半球付全额，≈ 天空 LUT 同级成本）——water 反射
//     未命中 SSR 侧经 sky.glsl 的 sampleCloudSkybox 单 fetch 消费的烘焙层，2026-10 接入；宏关时
//     该区域落入「其余透传」分支保值、消费侧同步编译剔除
//   - aerial 透视 LUT（AERIAL_PERSPECTIVE）：(460,0) 起 64×192（方向 64×48 × 距离 4 档纵向堆叠；
//     原址 (0,0) = 天空盒预留区左下角，2026-10 天空盒启用迁此）逐纹素重算
//    （lib/atmosphere/aerial.glsl 的 aerialLutTexel；帧常量复用天空 LUT 的 vsh varying、vsh 零新增；
//     宏关时该区域落入「其余透传」分支保值无害）→ composite_fog 消费
//   - 曝光槽位：tile4 对数平均测光 + 指数平滑写回
//   - 其余像素：包围盒内同位置读回透传（clear=false 跨帧保值），区域外光栅带写 0 免回读
// 云天空盒烘焙的帧数据（主导光源方向 / 直射辐照度 / 云高处透射率 / 天空环境基色）与通用全屏
// vsh 同名同式、在本 program vsh 段计算（见 VERTEX 段）
// DRAWBUFFERS 随输出不同下放入口文件（composite9~11 = 1、composite12 = 17），program 不携带
// vsh 把 quad 压缩到全图集包围盒（BLOOM_LEVEL 0 为上述并集包围矩形）；fsh 前半 / vsh 后半
//（云形状场的生成在 deferred 槽的 deferred_cloud_field、不涉本 pass）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/aerial.glsl"
#include "/lib/lighting/ambient.glsl"
#include "/lib/atmosphere/clouds.glsl"

VARYING vec2 vTexCoord;
#if BLOOM_LEVEL == 0
VARYING float vSkyObserverRadius;
VARYING vec3 vSkyHorizon;
VARYING vec3 vSkySunDirection;
VARYING vec3 vSkyMoonDirection;
VARYING vec3 vSkySunOpticalDepth;
VARYING vec3 vSkyMoonOpticalDepth;
VARYING vec3 vSkySunAmbientField;
VARYING vec3 vSkyMoonAmbientField;
#ifdef CLOUDS_2D
// 云天空盒烘焙帧数据（与通用全屏 vsh 同名同式，见 program/fullscreen_vsh.glsl）
VARYING vec3 vLightDirection;
VARYING vec3 vDirectIrradiance;
VARYING vec3 vCloudTransmittance;
VARYING vec3 vSkyAmbient;
#endif
#endif

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

#if BLOOM_LEVEL == 0
layout(location = 0) out vec4 outColor; // colortex1：tile 图集
layout(location = 1) out vec4 outMisc;  // colortex7：天空 LUT + 曝光槽位 + 其余透传
#else
layout(location = 0) out vec4 outColor;
#endif

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    // 本 pass 只更新 BLOOM_LEVEL，其余 tile 与间隔都是同位置透传；无需逐像素遍历全部 tile。
    // 保留原矩形函数与含边界判定，奇数分辨率 / 4 texel gutter 的布局语义不变。
    vec4 targetRect = bloomTileRect(BLOOM_LEVEL);
    bool inTargetTile = all(greaterThanEqual(vTexCoord, targetRect.xy))
                     && all(lessThanEqual(vTexCoord, targetRect.xy + targetRect.zw));
    if (inTargetTile) {
        vec2 tileLocal = (vTexCoord - targetRect.xy) / targetRect.zw;
        outColor = vec4(bloomUpsampleTile(BLOOM_LEVEL, tileLocal, pixel), 1.0);
    }

#if BLOOM_LEVEL == 0
    vec2 bloomBboxMax = bloomTileRectMax();
    bool inBloomBbox = all(lessThanEqual(vTexCoord, bloomBboxMax));
    bool inMiscBbox = all(lessThanEqual(vTexCoord, max(bloomBboxMax, bloomMiscRectMax())));

    // colortex1：tile 逻辑对所有像素照常执行——colortex7 槽位区域与 tile0 在 uv 上重叠，两缓冲
    // 互不相干、各按自己的规则写（outMisc 不得干涉 outColor，曾因此把 tile0 凿洞成屏幕黑矩形）；
    // 包围盒内非目标 tile 的像素复制回写，包围盒外光栅带（无读者）写 0 免回读
    if (!inTargetTile) outColor = inBloomBbox ? texelFetch(colortex1, pixel, 0) : vec4(0.0);

    // colortex7：天空 view LUT 区域（缓冲底边锚定）——太阳半区（pixel.y ∈ [100,200)）与月亮半区
    //（下方）各逐纹素重算（合计 ≈ 2% 屏幕成本）；MC 日月恰好相对，非活动半区整区写黑。
    // 维度极简档（DIM_NO_ATMOSPHERE，下界 / 末地）：LUT 不生成——inSkyLut 恒 false（条件求值
    // 编译剔除），区域落入「其余透传」分支保值（colortex7Clear = false、本维度无读者）；分支体
    // 引用的 vsh 帧常量 varying 照常输出（死分支消费、链接器剔除 fsh 侧 in）。CLOUDS_2D 云天空盒
    // 经宏整体不定义（constants.glsl 维度门控）。AERIAL_PERSPECTIVE 在下界经 FOG_UNIFIED_COLOR
    // 恢复定义（统一雾档，2026-10）、但 **aerial LUT 生成端在本门控下不编译**——统一雾不采样
    // LUT（fog 色常量 / 解析式），生成了也无消费者、白付天空 LUT 一成半~三成成本；末地两宏
    // 均不定义。下方 else-if 链随宏消失——首个 if 保留（条件恒 false）维持链结构
    bool inSkyLut = false;
#ifndef DIM_NO_ATMOSPHERE
    inSkyLut = pixel.y < 2 * SKYVIEW_LUT_H
            && pixel.x >= SKYVIEW_LUT_ORIGIN_X
            && pixel.x <  SKYVIEW_LUT_ORIGIN_X + SKYVIEW_LUT_W;
#endif
    if (inSkyLut) {
        ivec2 localPos = ivec2(pixel.x - SKYVIEW_LUT_ORIGIN_X, pixel.y % SKYVIEW_LUT_H);
        bool sunHalf = pixel.y >= SKYVIEW_LUT_H;
        vec3 lightDirection = sunHalf ? vSkySunDirection : vSkyMoonDirection;
        vec3 lightOpticalDepth = sunHalf ? vSkySunOpticalDepth : vSkyMoonOpticalDepth;
        vec3 irradiance = sunHalf ? SOLAR_IRRADIANCE : MOON_IRRADIANCE;
        vec3 ambientField = sunHalf ? vSkySunAmbientField : vSkyMoonAmbientField;

        // 光源低于地平线阈值后整半区写黑：该区间散射不可见，统一分支跳过 Chapman 求值；
        // alpha 仍写有效标记
        vec3 skyColor = vec3(0.0);
        if (lightDirection.y > SKY_LIGHT_MIN_HEIGHT) {
            skyColor = skyViewLutTexel(localPos, vSkyObserverRadius, vSkyHorizon,
                                       lightDirection, lightOpticalDepth, irradiance, ambientField);
        }
        outMisc = vec4(skyColor, SKYVIEW_LUT_VALID_MARKER);
    }
#ifdef CLOUDS_2D
    else if (pixel.x < SKYBOX_LUT_SIZE && pixel.y < SKYBOX_LUT_SIZE) {
        // 云层天空盒（八面体，[0,256)² 原点 (0,0)，反射烘焙路线）：每 texel 与主天空同一单真源
        // getPlanarCloudsWorld 全量求值（cloudSkyboxDir 逆映射方向；下行视线行星命中在函数内早退）
        //——rgb = 未预乘云色 / a = 不透明度（2026-10 契约：消费端标准 alpha 合成），water 反射
        // 未命中 SSR 侧单 fetch 消费
        outMisc = getPlanarCloudsWorld(cloudSkyboxDir(pixel), vLightDirection,
                                       vDirectIrradiance, vCloudTransmittance, vSkyAmbient);
    }
#endif
#if defined(AERIAL_PERSPECTIVE) && !defined(FOG_UNIFIED_COLOR) // 统一雾档（下界）不生成 aerial LUT：无采样端、生成了白付成本（见上方维度注释）
    else if (pixel.x >= AERIAL_LUT_ORIGIN_X && pixel.x < AERIAL_LUT_ORIGIN_X + AERIAL_LUT_W
          && pixel.y < AERIAL_LUT_H * AERIAL_LUT_SLICES) {
        // aerial 透视 LUT（(460,0) 起、sky-view 右侧水平续接，与既有槽位结构性互斥）：双光源和式
        //（主导门控后多数时间单光源，≈ 天空 LUT 成本的一成半~三成）；alpha = 路径透射率
        //（有效性标记由 sky LUT 半区 alpha 承担、本区域不写标记）
        outMisc = aerialLutTexel(ivec2(pixel.x - AERIAL_LUT_ORIGIN_X, pixel.y), vSkyObserverRadius, vSkyHorizon,
                                 vSkySunDirection, vSkySunOpticalDepth, vSkySunAmbientField,
                                 vSkyMoonDirection, vSkyMoonOpticalDepth, vSkyMoonAmbientField);
    }
#endif
    else if (pixel == exposureTexel()) {
        // 自动曝光寄生存储：仅槽位 1 texel 付测光成本
        outMisc = vec4(adaptedExposure(targetExposure(sceneAverageLuminance())), 0.0, 0.0, 1.0);
    } else if (pixel == PASS_ORDER_MARKER_TEXEL) {
        // pass 顺序标记复位（诊断，机制见 lib/common/pipeline/pass_order_marker.glsl）：deferred_init
        // 帧中写 1、此处帧末归零——下一帧 gbuffers 读 0 = deferred 之前执行；复位须在透传分支前
        //（透传会把 1 保留到下帧）
        outMisc = vec4(0.0);
    } else {
        // 其余像素：包围盒内同位置读回透传保持既有内容（本 pass 是 colortex7 唯一写入者、
        // 区域整写保值），包围盒外光栅带无槽位无读者、写 0 免回读
        outMisc = inMiscBbox ? texelFetch(colortex7, pixel, 0) : vec4(0.0);
    }
#else
    // 非目标 tile 的像素（其他级与间隔）复制回写：保持 main/alt 翻转下的完整图集；
    // colortex7 包围盒整写不可 discard，两路输出互不干涉
    if (!inTargetTile) outColor = texelFetch(colortex1, pixel, 0);
#endif
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    vec4 pos = ftransform();
    vec2 quadUv = pos.xy / pos.w * 0.5 + 0.5;
    // quad 压缩到全图集包围盒（复制回写须覆盖所有 tile 与 colortex7 槽位，春雷 / c13 同款技巧）；
    // BLOOM_LEVEL 0 兼写天空 LUT 区域（缓冲底边）——扩为两区域的包围矩形，条带内非槽位像素 fsh 写 0
    vec2 rectMax = bloomTileRectMax();
#if BLOOM_LEVEL == 0
    rectMax = max(rectMax, bloomMiscRectMax());

    // LUT 帧常量：全屏 quad 各顶点写同值、片段阶段精确插值还原——光源方向 / 地平线几何 /
    // 光源路径消光 / MS 环境场（skyAmbientField）每帧仅 3~4 次，不再由 40k LUT texel 重复执行；
    // 环境场与半区写黑同一阈值门控（低于地平线的光源无散射、场为 0）。地平线几何与通用全屏 vsh
    // 的 vHorizon 共用 ambient.glsl 的 observerHorizonGeometry 单真源（曾各处手抄同式）
    vSkyObserverRadius = EARTH_RADIUS + max(cameraPosition.y, 1.0);
    vSkyHorizon = observerHorizonGeometry();

    vSkySunDirection = sunDirectionWorld();
    vSkyMoonDirection = moonDirectionWorld();
    vSkySunOpticalDepth = opticalDepthToSpace(vSkyObserverRadius, vSkySunDirection.y);
    vSkyMoonOpticalDepth = opticalDepthToSpace(vSkyObserverRadius, vSkyMoonDirection.y);
    vSkySunAmbientField = vSkySunDirection.y > SKY_LIGHT_MIN_HEIGHT
        ? skyAmbientField(vSkyObserverRadius, vSkySunDirection, vSkySunOpticalDepth, SOLAR_IRRADIANCE)
        : vec3(0.0);
    vSkyMoonAmbientField = vSkyMoonDirection.y > SKY_LIGHT_MIN_HEIGHT
        ? skyAmbientField(vSkyObserverRadius, vSkyMoonDirection, vSkyMoonOpticalDepth, MOON_IRRADIANCE)
        : vec3(0.0);

#ifdef CLOUDS_2D
    // —— 云天空盒烘焙帧数据（与通用全屏 vsh 同名同式，见 program/fullscreen_vsh.glsl——直射
    // 辐照度取值实现已收敛进 ambient.glsl 的 frameDirectIrradiance 单真源）——
    // 主导光源方向 / 直射辐照度（门控加权和 + 雨衰减）/ 云高处透射率 / 天空环境基色；探针读到的
    // LUT 为上帧本 pass 写入面——与 deferred_init 消费同批同滞后，云光照色调自动同源
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));
    vDirectIrradiance = frameDirectIrradiance(sin(sunAngle * TAU), vSkyMoonDirection.y);
    vCloudTransmittance = exp(-opticalDepthToSpace(EARTH_RADIUS + CLOUDS_2D_HEIGHT, vLightDirection.y));
    float cloudSkyLutValid; // 探针有效性在此不消费（烘焙无条件执行，无效帧探针乱一帧由 TAA 吸收）
    vSkyAmbient = skyAmbientColor(cloudSkyLutValid);
#endif
#endif
    vec2 rectUv = quadUv * rectMax;
    pos.xy = (rectUv * 2.0 - 1.0) * pos.w;
    gl_Position = pos;
    vTexCoord = rectUv;
}

#endif
