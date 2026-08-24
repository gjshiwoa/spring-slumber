// Bloom 上采样回卷 pass：composite_bloom_upsample（world0/composite9~12 入口，入口定义 BLOOM_LEVEL = 目标 tile 序号 3~0）
// 金字塔自粗向细逐级合并：tile BLOOM_LEVEL = 本级原始内容 × 级权重 + 上一 pass 已合并
// tile BLOOM_LEVEL+1 的 tent 放大 2 倍相加（lib/post/bloom.glsl 的 bloomUpsampleTile），
// 粗级模糊经逐级 tent 累积成连续衰减（每级仅 2 倍放大，无大倍率双线性的菱形网格 / 离散半径环）：
//   tile != BLOOM_LEVEL 的像素原样复制回写，非 tile 像素（tile 间隔与包围盒内边角）同样复制回写、
//   不 discard——BLOOM_LEVEL 0 兼写 colortex7 须光栅区域整写（见下），discard 会连座丢弃全部附件；
//   每 pass 重写整个图集包围盒，跨 pass 保值、对 OptiFine / Iris 的 main/alt 翻转语义免疫，同下采样链
//   （tile4 恒为原始下采样内容——composite12 测光依赖，绝不被本链覆盖）
// BLOOM_LEVEL == 0（composite12，上采样链末级）：colortex7 唯一写入者，光栅 quad 自图集包围盒
// 扩为「包围盒 ∪ 天空 view LUT 区域」的包围矩形（左条带），一 pass 兼管全部 colortex7 槽位——
// ping-pong 缓冲多写入者交替翻转会让彼此槽位读到隔帧旧面（无 flip.* 的引擎语义免疫方案）；
// colortex1 的 tile 逻辑对全部光栅像素照常执行（colortex7 槽位区域与 tile0 在 uv 上重叠——
// 1080p 下 LUT 完整落在 tile0 的 [0,0.25]² 内——两缓冲互不相干、各按自己的规则写）：
//   - 天空 view LUT（atmosphere/sky.glsl）：太阳 / 月亮半区各 200×100；帧常量、光源路径
//     光学深度与多次散射环境场在 vsh 预计算，低于地平线阈值的非活动光源整半区写 0，
//     其余 texel 求 Chapman 解析 + 环境场 MS 再散射；
//     deferred_init 全分辨率天空自此改 LUT 双线性采样、两半区和式
//   - 自动曝光寄生存储（春v2 同款 pass 设计）：曝光槽位（杂项簇 gutter，exposure.glsl 的
//     exposureTexel）测图集最粗 tile（tile4）对数平均亮度（春雷算法、固定 16 点核）、与槽位
//     上一帧曝光指数平滑后写回；
//   - 其余像素：包围盒内同位置读回透传保值（clear = false 跨帧存活），包围盒外光栅带
//     无槽位无读者、写 0 免回读；tile4 源安全：本 pass 读 colortex1 为上一 pass（composite11）
//     终态，tile4 自 composite8 写入后只被复制回写、恒为原始下采样内容，无同 pass 竞争
// DRAWBUFFERS 随输出缓冲不同下放入口文件（composite9~11 = 1、composite12 = 17），program 不携带以免展开后重复
// 场景合成与曝光应用、AgX、gamma 在 final 单 pass 完成
// vsh 把 quad 压缩到全图集包围盒（BLOOM_LEVEL 0 为上述并集包围矩形），只光栅化需要区域
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/atmosphere/sky.glsl"

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
    bool inTile = false;
    for (int k = 0; k < BLOOM_TILE_COUNT; k++) {
        vec4 rect = bloomTileRect(k);
        if (all(greaterThanEqual(vTexCoord, rect.xy)) && all(lessThanEqual(vTexCoord, rect.xy + rect.zw))) {
            if (k != BLOOM_LEVEL) {
                outColor = texelFetch(colortex1, pixel, 0);
            } else {
                vec2 tileLocal = (vTexCoord - rect.xy) / rect.zw;
                outColor = vec4(bloomUpsampleTile(BLOOM_LEVEL, tileLocal, pixel), 1.0);
            }
            inTile = true;
            break;
        }
    }

#if BLOOM_LEVEL == 0
    vec2 bloomBboxMax = bloomTileRectMax();
    bool inBloomBbox = all(lessThanEqual(vTexCoord, bloomBboxMax));
    bool inMiscBbox = all(lessThanEqual(vTexCoord, max(bloomBboxMax, bloomMiscRectMax())));

    // colortex1：tile 逻辑对所有像素照常执行——天空 LUT / 曝光槽位在 colortex7，其区域与
    // colortex1 的 tile0 在 uv 上重叠（1080p 下 LUT 完整落在 tile0 的 [0,0.25]² 内），但两缓冲
    // 互不相干、各按自己的规则写，outMisc 分支不得干涉 outColor（曾在此把 tile0 凿出 200×100
    // 的洞、final 放大 4 倍后成屏幕黑矩形）；包围盒内非 tile 像素复制回写，包围盒外光栅带
    // （无读者）写 0 免无谓回读
    if (!inTile) outColor = inBloomBbox ? texelFetch(colortex1, pixel, 0) : vec4(0.0);

    // colortex7：天空 view LUT 区域（左下角，缓冲底边锚定）——太阳半区（屏幕上方，
    // pixel.y ∈ [100,200)）与月亮半区（下方）各逐纹素重算 Chapman 解析（合计 ≈ 2% 屏幕成本）；
    // MC 日月恰好相对，白天月亮半区自然归零、夜晚反之，曙暮光时段两者并存
    if (pixel.y < 2 * SKYVIEW_LUT_H
     && pixel.x >= SKYVIEW_LUT_ORIGIN_X
     && pixel.x <  SKYVIEW_LUT_ORIGIN_X + SKYVIEW_LUT_W) {
        ivec2 localPos = ivec2(pixel.x - SKYVIEW_LUT_ORIGIN_X, pixel.y % SKYVIEW_LUT_H);
        bool sunHalf = pixel.y >= SKYVIEW_LUT_H;
        vec3 lightDirection = sunHalf ? vSkySunDirection : vSkyMoonDirection;
        vec3 lightOpticalDepth = sunHalf ? vSkySunOpticalDepth : vSkyMoonOpticalDepth;
        vec3 irradiance = sunHalf ? SOLAR_IRRADIANCE : MOON_IRRADIANCE;
        vec3 ambientField = sunHalf ? vSkySunAmbientField : vSkyMoonAmbientField;

        // 光源低于地平线约 8.6° 后整半区写黑：该区间散射在曝光上限内不可见，
        // 统一分支跳过每 texel 的 Chapman 视线路径与相函数求值；alpha 仍写专用标记表示 LUT 有效。
        vec3 skyColor = vec3(0.0);
        if (lightDirection.y > SKY_LIGHT_MIN_HEIGHT) {
            skyColor = skyViewLutTexel(localPos, vSkyObserverRadius, vSkyHorizon,
                                       lightDirection, lightOpticalDepth, irradiance, ambientField);
        }
        outMisc = vec4(skyColor, SKYVIEW_LUT_VALID_MARKER);
    } else if (pixel == exposureTexel()) {
        // 自动曝光寄生存储：仅槽位 1 texel 付测光成本
        outMisc = vec4(adaptedExposure(targetExposure(sceneAverageLuminance())), 0.0, 0.0, 1.0);
    } else {
        // 其余像素：包围盒内同位置读回透传保持既有内容（本 pass 是 colortex7 唯一写入者、
        // 区域整写保值），包围盒外光栅带无槽位无读者、写 0 免回读
        outMisc = inMiscBbox ? texelFetch(colortex7, pixel, 0) : vec4(0.0);
    }
#else
    // 非 tile 像素（间隔与包围盒内边角）复制回写：colortex7 包围盒整写不可 discard，
    // colortex1 侧这些纹素无读者、复制回写只增保值纪律不增语义
    if (!inTile) outColor = texelFetch(colortex1, pixel, 0);
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

    // LUT 帧常量：全屏 quad 各顶点写同值，片段阶段精确插值还原。
    // 光源方向、观察者地平线、起点 -> 光源的大气消光与多次散射环境场（atmosphere.glsl 的
    // skyAmbientField——48 节点光源锚定环带求积，一阶天光球面平均 × 几何级数 1/(1-ρ)）
    // 各帧只计算 3~4 次，不再由 40k 个 LUT texel 重复执行矩阵换算、sqrt/acos、三介质 Chapman
    // 与环境场求积；环境场与半区写黑同一阈值门控（低于地平线的光源无散射、场为 0）
    vSkyObserverRadius = EARTH_RADIUS + max(cameraPosition.y, 1.0);
    float altitudeTerm = max((vSkyObserverRadius - EARTH_RADIUS)
                           * (vSkyObserverRadius + EARTH_RADIUS), 0.0);
    float cosBeta = sqrt(altitudeTerm) / vSkyObserverRadius;
    float beta = acos(cosBeta);
    vSkyHorizon = vec3(cosBeta, beta, PI - beta);

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
#endif
    vec2 rectUv = quadUv * rectMax;
    pos.xy = (rectUv * 2.0 - 1.0) * pos.w;
    gl_Position = pos;
    vTexCoord = rectUv;
}

#endif
