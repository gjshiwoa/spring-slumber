// 前向半透明（完整处理）: gbuffers_translucent
// water 入口。本程序是该 draw 的全部几何——水 **与玻璃 / 冰等其余半透明方块**（translucent 地形
// 同一 draw）：经 mc_Entity（block.properties 的 block.8 = 水 / 流动水，与 shadow pass 焦散同一
// 判定源）以 flat varying vIsWater 运行时分流：
//   水（vIsWater）：**前向水面框架**（lib/water/surface.glsl 的 shadeWaterSurface〔2026-10 自
//     lib/lighting/water.glsl 按功能拆分为 lib/water/*：waves / fog / ssr / reflection / surface〕，方案移植自
//     春v2 lib/water/*，组合式样见其 gbuffers_water / deferred21）——水波高度场 + 世界差分法线
//     （deferred21 路线、不走局部 TBN）+ 水面视差（WAVE_PARALLAX：着色点沿视线一阶 + 割线 march
//     到波高隐式面，法线 / SSR 起点 / 水深换用位移后位置）+ 折射（**colortex4 背景快照**〔gaux1，
//     deferred_init 曝光归一化编码——位移落点踩进本 draw 其他水像素时活缓冲是光栅序竞态、实机
//     水面裂缝的根因，2026-10 修〕+ depthtex1 背景深度）+ 水雾（彩色吸收 + 满深 mix）+ 反射（SSR
//     命中色同取快照，未命中回退天空 LUT + 解析太阳盘 + **烘焙云层
//     天空盒**
//     ——colortex7 八面体槽位单 fetch、composite12 帧末烘焙，不在反射路径重算云）经 Fresnel 混合；
//     直射分量（glint / 镜中日盘 / 雾色直射项）经**阴影可见性门控**（shadowtex1 单 tap 最简硬判定，
//     lib/water/surface.glsl 内联——桥影 / 山影下的水面不再渲染水反太阳 / 高光，2026-10 修复）；输出整像素最终合成色 + **alpha 1.0** 写
//     colortex6；**水分支不 fetch 图集**（2026-10 性能：texcolor 无消费者、cutout 判定原版水贴图
//     alpha ~0.75+ 恒不触发，fetch 与判定一并免掉——fetch / 判定移入玻璃分支，见 fsh 注）**colortex6 交 ROP 硬件 alpha 混合直写**（blend 行不配置、2026-10 注释移除——本 draw 恒在
//     deferred 之后、无打包路径要保护，引擎对半透明 draw 的默认 alpha 混合即所需状态；兼容性标准化阶段曾为春v2 逐缓冲显式行
//     〔`blend.gbuffers_water = off` + `.colortex6 = SRC_ALPHA ...`〕、复刻默认态后简化回落）：水的全部合成在着色器内完成（背景读 gaux1 快照、不依赖 dst），ROP
//     srcAlpha/1−srcAlpha 下 src×1 + dst×0 = 精确替换——与关混合直写逐位等价，手动水面框架与
//     ROP 混合兼容（曾以为不兼容而整 draw 关混合、玻璃被迫改手动 mix——同 draw 重叠片段的
//     读改写竞态 = 玻璃叠玻璃 / 玻璃与水交叠处逐帧闪烁，2026-10 修复回归）
//   其余半透明（玻璃等）：光照图轻量着色（forwardLightmapShade，与简单半透明同式）后直通
//     (lit, alpha)、引擎 ROP 原子合成进 colortex6（FORWARD_HW_BLEND 同款回归——同 draw 内重叠
//     半透明片段按提交序正确叠层、跨 draw 链式叠加正确；不再 fetch gaux3，「读正在写的 colortex6」
//     取舍随之消失）
// pass 顺序标记自适应（lib/common/pipeline/pass_order_marker.glsl，vsh 判定经 flat varying 下传）：
//   「之后」= 上述两路（恒此路径——水族在 OptiFine / Iris 均恒 deferred 后）；「之前」为防御位
//   （不可达）：不写 gbuffer、colortex6 随写 0（deferred_init 全屏覆盖）
// 已知取舍：水的折射 / SSR 取背景快照、与本 draw 写入解耦（无竞态）；ROP 叠层按提交序（vanilla
//   半透明同款——chunk 网格序固定、稳定不闪，仅远近层序可能非物理）；快照 / 折射背景不含本 draw
//   的玻璃等半透明（水下的玻璃不进水的折射背景、被后绘水整像素替换的玻璃不可见——手动框架固有）
// 单附件 DRAWBUFFERS:6（下放入口文件）；fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT /
// STAGE_VERTEX 选择编译哪一半。帧数据 varying（日月方向 / 直射辐照度 / 地平线 / LUT 有效性 /
// 天空环境基色）在自身 vsh 输出、与通用全屏 vsh 同名同式（带自定义 vsh 的 pass 帧数据纪律）；
// **不输出 vCloudTransmittance**（反射云经烘焙天空盒消费、烘焙端 composite12 自带帧数据；通用
// 全屏 vsh 的同名 varying 是 deferred_init 的云着色用）；不依赖 clouds.glsl / bloom.glsl
//（2026-09 随「反射不硬算云」移除、2026-10 烘焙路线接回时仍保持——采样端函数在 sky.glsl、
// 其八面体编码依赖 packing.glsl 由本程序平铺引入）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/pipeline/material_texture.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/pipeline/pass_order_marker.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/aerial.glsl"
#include "/lib/atmosphere/fog.glsl"
#include "/lib/lighting/ambient.glsl"
// 水面前向框架（2026-10 自 lib/lighting/water.glsl 按功能拆分，lib 不嵌套、按依赖序平铺）：
// 波形 → 水雾 → SSR march → 反射取色（前置 water/fog 与 atmosphere 三件〔sky / aerial / fog，
// 已在上方引入〕）→ 主入口
#include "/lib/water/waves.glsl"
#include "/lib/water/fog.glsl"
#include "/lib/water/ssr.glsl"
#include "/lib/water/reflection.glsl"
#include "/lib/water/surface.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos;    // 水面 / 玻璃着色的位置基底（观察空间；几何无位移）
VARYING vec2 vJitter;     // TAA jitter（uv 域）——折射采样位的去抖基底（composite_fog 同式消费）
VARYING vec3 vSunDirection;   // 帧数据：与通用全屏 vsh 同名同语义（世界系归一）
VARYING vec3 vMoonDirection;
VARYING vec3 vLightDirection;
VARYING vec3 vDirectIrradiance;
VARYING vec3 vSkyAmbient;
VARYING vec3 vHorizon;
flat VARYING float vSkyLutValid;   // 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）
flat VARYING float vBgDecodeScale; // 背景快照解码系数（HEADROOM ÷ 曝光槽位值——与 deferred_init 编码端同帧同槽，lib/water/surface.glsl 头注）
flat VARYING float vAfterDeferred; // pass 顺序判定 0/1
flat VARYING float vIsWater;       // mc_Entity 水判定 0/1（block.8，与 shadow pass 焦散同源）

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

// DRAWBUFFERS 在入口文件：单附件 colortex6（引擎混合开——水 alpha 1 = ROP 精确替换、玻璃 alpha 直通叠层）
layout(location = 0) out vec4 outColor; // colortex6：水 = (折射 + 水雾 + 反射, 1.0)；玻璃等 = (lit, alpha)

void main() {
    // Precompute material gradients before discard or divergent branches.
    vec2 duv1 = dFdx(vTexCoord);
    vec2 duv2 = dFdy(vTexCoord);

    // 水面几何面世界法线（vViewPos 屏幕导数 → 世界导数法线；导数先于 discard 集中求好——纪律同
    // gbuffers_opaque，discard 后 quad 内幸存像素导数未定义；方向未定向、由 shadeWaterSurface 朝
    // 空气侧定向）：①波面法线重定基与反射背向回退 / SSR 起点推离的基面——高度场波法线恒朝上，
    // 竖直流面（瀑布 / 水柱）直接当着色法线 = 把竖直面当水平镜（2026-10 修复，见 lib 头注）；②去抖 /
    // 视差的水平面门控（|法线.y| 低于 WATER_DEJIT_MIN_UPNESS 跳过——竖直流面上水平面交点横向搬离
    // 真实几何）；玻璃分支不消费（编译器按分支剔除）
    vec3 waterDpdx = dFdx(vViewPos);
    vec3 waterDpdy = dFdy(vViewPos);
    vec3 waterFaceNormalW = viewToWorldDirection(normalize(cross(waterDpdx, waterDpdy)));
    float waveFootprint = max(length(viewToWorldDirection(waterDpdx).xz),
                              length(viewToWorldDirection(waterDpdy).xz));

    // TAAU 子区域外片元剔除（机制见 noise.glsl 的 outsideRenderRegion；半透明混合本无 Early-Z 顾虑）
    if (outsideRenderRegion()) discard;

    if (vAfterDeferred > 0.5) {
        // deferred 之后（恒此路径）：按 vIsWater 分流，两路共用引擎 ROP 混合（srcAlpha/1−srcAlpha）；
        // 图集 fetch 与 cutout 判定随之下放各分支——水分支整体免 fetch（见下）
        vec2 lm = remapLightmap(vLmcoord);
        if (vIsWater > 0.5) {
            // 水面框架（lib/water/surface.glsl；水面不消费 texcolor 的颜色 / alpha——雾基色调制只取
            // **顶点色**（生物群系水色）：texture(tex) 的纹样与整体亮度不进雾色（混入会让雾色随水
            // 纹理动画起伏并整体偏亮，2026-09 按反馈改传 vColor.rgb），可见色全部来自
            // 折射背景 + 雾 + 反射）。**不 fetch 图集（2026-10 性能）**：fetch 对水分支的唯一消费者
            // 是恒不触发的 cutout 判定——原版水贴图 alpha ~0.75+、永不低于 ALPHA_CUTOUT 0.1（低
            // alpha 水贴图的资源包会从「掏洞」变「正常着水」，后者语义更合理）；整像素最终色 +
            // alpha 1.0——ROP 下 ×1 + dst×0 = 精确替换
            vec3 composited = shadeWaterSurface(vViewPos, vColor.rgb, lm,
                                                vSunDirection, vMoonDirection, vLightDirection, vHorizon,
                                                vSkyLutValid, vDirectIrradiance,
                                                vSkyAmbient, vBgDecodeScale, vJitter, waterFaceNormalW, waveFootprint);
            outColor = vec4(composited, 1.0);
        } else {
            // 其余半透明（玻璃 / 冰 / 蜂蜜等）：图集 fetch 与 cutout 判定在本分支内（水分支免 fetch
            // 的对偶面；fetch 位于 discard 后——隐式 LOD 导数取自 quad 的 varying、helper invocation
            // 语义与 translucent_simple 的 before 路径采样同款）；轻量光照后直通 (lit, alpha)、引擎
            // ROP 原子合成（FORWARD_HW_BLEND 同款——同 draw 内重叠半透明片段按提交序正确叠层；手动
            //「fetch 背景 + mix」的读改写在重叠片段间是竞态、逐帧闪烁，玻璃叠玻璃 / 玻璃与水交叠实测）
            vec4 color = sampleMaterialTexture(tex, vTexCoord, duv1, duv2) * vColor;
            if (color.a < CUTOUT_REF) discard; // cutout 透贴（引擎参考值钳制，constants.glsl 的 CUTOUT_REF）
            vec3 lit = forwardLightmapShade(srgbToLinear(color.rgb), lm, vSkyAmbient);
            outColor = vec4(lit, color.a);
        }
    } else {
        // deferred 之前（防御位、恒不可达）：alpha 0 = ROP 下 no-op（旧「随写 0」形态属关混合时代）；
        // deferred_init 全屏覆盖，不写 colortex4/5（时机不可达故从简——不 fetch 图集，color 无消费者）
        outColor = vec4(0.0);
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

// mc_Entity 声明须用 attribute 而非 in——生态标准形态（Complementary / Photon 同款），老 OptiFine
// 对 in 声明的自定义属性不绑定（显式标记静默失效的根因，AGENTS.md「gbuffer 打包与物品标记」条）
attribute vec4 mc_Entity;

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vJitter = taaJitterUV();

    // ---- 帧数据（与通用全屏 vsh 同名同式，见 program/fullscreen_vsh.glsl——取值实现已收敛进
    // lib/lighting/ambient.glsl 的 frameDirectIrradiance / observerHorizonGeometry 单真源）----
    vSunDirection = normalize(viewToWorldDirection(sunPosition));
    vMoonDirection = normalize(viewToWorldDirection(moonPosition));
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));

    // 直射辐照度：门控加权和 + 雨衰减（统一时间系统；切换瞬间双 0 黑过渡）
    vDirectIrradiance = frameDirectIrradiance(sin(sunAngle * TAU), vMoonDirection.y);

    // 观察者地平线几何（fullscreen_vsh 同式）
    vHorizon = observerHorizonGeometry();

    // 天空环境基色探针 + LUT 有效性（lib/lighting/ambient.glsl，与通用全屏 vsh 同一实现）
    float lutValid;
    vSkyAmbient = skyAmbientColor(lutValid);
    vSkyLutValid = lutValid;

    // 背景快照解码系数：与 deferred_init 编码端同帧读同一曝光槽位（gaux4 = colortex7 杂项簇，
    // validity 判定与通用全屏 vsh 的 vExposure 同式——两端同分支回退 1.0、成对一致）
    float bgExposure = texelFetch(gaux4, EXPOSURE_TEXEL, 0).r;
    bgExposure = (bgExposure > 1e-4 && bgExposure < 1e4) ? bgExposure : 1.0;
    vBgDecodeScale = WATER_BG_SNAPSHOT_HEADROOM / bgExposure;

    // pass 顺序判定一次（vsh 顶点级，fsh 经 flat varying 消费）
    vAfterDeferred = isAfterDeferred() ? 1.0 : 0.0;
    // 水判定（block.properties block.8 = water / flowing_water；玻璃等未映射方块 -1、hand 等入口
    // mc_Entity 未绑定取 0，均不命中——回退链 hand_water → water 落入本程序时自然走玻璃路径）
    vIsWater = mc_Entity.x == BLOCK_WATER ? 1.0 : 0.0;
}

#endif
