// 不透明 gbuffer（实体）: gbuffers_opaque_entities
// 与 gbuffers_opaque 的区别: 叠加 entityColor（受伤红闪等实体着色）后再写入 gbuffer
// 按 pass 顺序标记自适应（lib/common/pipeline/pass_order_marker.glsl，vsh 判定经 flat varying 下传）：
//   deferred 之前（引擎常规位）：MRT 写 colortex4/5（布局同 gbuffers_opaque 头部注释），colortex6
//     随写 0（colortex6 的 per-buffer 混合下 alpha 0 = 精确 no-op；deferred_init 全屏覆盖）——
//     原有行为；colortex4/5 打包整像素写入由程序级 blend off 保护
//   deferred 之后（引擎变体防御位，Iris 拆分实体绘制等的半透明实体由此走）：简单光照
//     （forwardEntityShade，lib/lighting/ambient.glsl——直射 + 天光 + 方块光：直射项对齐
//     shadeSurface 的公式与帧数据，阴影取 shadowtex1 单 tap 最简硬判定〔水面直射门控同款〕；
//     与「之前」路径的延迟光照实体同屏时日落红化 / 量级一致）后输出直通 (lit, alpha)、
//     colortex6 经 **per-buffer 硬件 alpha 混合**原子合成
//     （shaders.properties `blend.gbuffers_entities.colortex6 = SRC_ALPHA ONE_MINUS_SRC_ALPHA
//     ZERO ONE`〔春v2 逐缓冲格式〕；曾为「gaux3 fetch 背景 + mix 写回」手动 mix——读正在写的
//     附件在个别驱动未定义 + 同 draw 重叠竞态，2026-10 兼容性标准化移除，与 textured 族
//     after 路径同款）；colortex4/5 本分支不写——gbuffer 读者（deferred_init 几何分支）只读
//     depthtex1 < 1 像素、该区域每帧被不透明 gbuffers 先行整写，遗留内容活不到读者面前
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半
// SR 超分实体运动矢量（SR_ENTITY_VELOCITY = SR_UPSCALE + Iris at_velocity 扩展开启，constants.glsl）：
// 经 RENDERTARGETS 增写 colortex31（rg = at_velocity 重投影的实体 MV、b = 1 实体层标记）。
// **两路路径都写实体 MV**（2026-10 修复）：「之后」路径在 deferred_init 之后绘制，写 0 会踩掉
// 其已写入的相机 MV（无从兜底）→ 相机运动时这些实体在超分侧零运动、拖影；写实体自身 MV则
// 两时序均正确。「之前」路径的写入由 deferred_init 的 b 标记读回保留；discard 片元不写——
// 「之前」= clear 0 交 deferred_init 覆写、「之后」= 保留相机 MV。
// 取值实现 = space.glsl 的 srEntityMotionVector；blend.gbuffers_entities 程序级 off 覆盖 colortex31
//（数据写入、不得混合——per-buffer 行只覆盖 colortex6，无需新增配置）

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/pipeline/material_texture.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/pipeline/pass_order_marker.glsl"
#include "/lib/common/pipeline/material.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/lighting/ambient.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos;
VARYING vec3 vSkyAmbient; // 天空环境辐照度基色（vsh 探针一次取好；同通用全屏 vsh 的同名 varying 语义）
VARYING vec3 vLightDirection;   // 帧数据（与通用全屏 vsh 同名同语义）：「之后」路径直射项的光向 / 辐照度 /
VARYING vec3 vDirectIrradiance; // 透射率——vsh 一次算好，fsh 经同名 varying 消费（带自定义 vsh 的
VARYING vec3 vDirectTransmittance; // pass 帧数据纪律，gbuffers_translucent 同款）
flat VARYING float vAfterDeferred; // pass 顺序判定 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）
#ifdef SR_ENTITY_VELOCITY
VARYING vec3 vVelocity;     // at_velocity 直传（vsh 声明采集、fsh 经上一帧投影重投影）
VARYING vec4 vClipTrue;     // 无抖动 clip 位置（jitter 注入前、未除 w——2026-10 修复：NDC 域量以
                            // vec2 varying 传会被透视矫正插值弄错〔已除 w 的量再插值不精确、w 变化的
                            // 大三角形内部误差数像素〕，传仿射量精确、fsh 内除回取无抖动全视场 uv）
#endif

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

// 引擎输出指令必须直接检查 SR 注入宏，不能依赖派生 SR_* 宏：OptiFine 1.12 的
// MacroState 连失活分支中的 #define 也登记，会误认 SR 已启用；GLSL 预处理器却
// 正确跳过该定义。否则 DRAWBUFFERS 被漏扫（旧引擎不识别 RENDERTARGETS）。
#if defined(SR_INSTALLED) && defined(SR_SHOULD_APPLY_SCALE) && SR_SHOULD_APPLY_SCALE == 1 && defined(SR_IRIS_EXT_VELOCITY) && SR_IRIS_EXT_VELOCITY == 1
/* RENDERTARGETS: 4,5,6,31 */
#else
/* DRAWBUFFERS:456 */
#endif

layout(location = 0) out vec4 outMaterial; // colortex4：「之前」= 打包几何 /「之后」= 不写（无读者）
layout(location = 1) out vec4 outDetail;   // colortex5：同上
layout(location = 2) out vec4 outColor;    // colortex6：「之后」= 直通 (lit, alpha) 硬件混合 /「之前」= 随写 0（no-op）
#ifdef SR_ENTITY_VELOCITY
layout(location = 3) out vec4 outMotion;   // colortex31：实体层运动矢量（两路路径都写，见文件头）
#endif

void main() {
    // 导数先于 discard（同 gbuffers_opaque 的顺序约束——discard 后幸存像素导数未定义）；
    // TBN 构造与 normals 采样推迟到 discard 之后
    vec3 dp1 = dFdx(vViewPos);
    vec3 dp2 = dFdy(vViewPos);
    vec2 duv1 = dFdx(vTexCoord);
    vec2 duv2 = dFdy(vTexCoord);

    // TAAU 子区域外片元剔除（机制与调用纪律见 noise.glsl 的 outsideRenderRegion；
    // 本程序已有 cutout discard、Early-Z 无额外损失——视锥边缘实体正是剔除的主要受益者）
    if (outsideRenderRegion()) discard;
    vec4 color = sampleMaterialTexture(tex, vTexCoord, duv1, duv2) * vColor;
    if (color.a < CUTOUT_REF) discard; // cutout 透贴（引擎参考值钳制，constants.glsl 的 CUTOUT_REF）
    color.rgb = mix(color.rgb, entityColor.rgb, entityColor.a);
    // 上一行为 texcolor 的半透明混合、只作用于 rgb——标记不参与混合，a 通道整像素置空
    //（实体入口无 gsh 程序化判定，标记槽位恒空）；置空只作用「之前」路径的打包，「之后」
    // 路径的合成先取原始纹理 alpha
    float texAlpha = color.a;

#ifdef SR_ENTITY_VELOCITY
    // SR 实体层 MV（两路路径共写，见文件头）：at_velocity 重投影（space.glsl）；cur 位置 = vClipTrue
    // 除回的无抖动全视场 uv（渲染分辨率归一 uv 域、与相机 MV 同约定）。位于 discard 之后——被剔除
    // 片元不写（「之前」= clear 0 交 deferred_init 覆写、「之后」= 保留其相机 MV）
    outMotion = vec4(srEntityMotionVector(vViewPos, vVelocity,
                                          vClipTrue.xy / vClipTrue.w * 0.5 + 0.5), 1.0, 1.0);
#endif

    if (vAfterDeferred > 0.5) {
        // deferred 之后：简单光照（forwardEntityShade——直射 + 天光 + 方块光，阴影单 tap 最简档；
        // 导数法线 / labPBR 贴图法线与「之前」路径打包进 gbuffer 的同一根 gbufferViewNormal）
        // 后直通 (lit, alpha)、colortex6 per-buffer 硬件 alpha 混合原子合成
        //（同 draw 内重叠片段定序正确、跨 draw 链式叠加正确；曾为 gaux3 fetch + mix 手动合成——
        // 读正在写的附件个别驱动未定义 + 同 draw 竞态，2026-10 兼容性标准化移除，见头注）；
        // colortex4/5 本分支不写（无读者，见头注）
        vec2 lm = remapLightmap(vLmcoord);
        vec3 viewNormal = gbufferViewNormal(dp1, dp2, duv1, duv2, vTexCoord);
        vec3 lit = forwardEntityShade(srgbToLinear(color.rgb), viewNormal, lm, vViewPos,
                                      vLightDirection, vDirectIrradiance, vDirectTransmittance,
                                      vSkyAmbient);
        outColor = vec4(lit, texAlpha);
    } else {
        // deferred 之前：几何进 colortex4/5（deferred_init 延迟光照）；colortex6 随写 0（per-buffer
        // 混合下 alpha 0 = 精确 no-op；deferred_init 全屏覆盖、语义等效）
        color.a = MATERIAL_NONE;
        vec3 viewNormal = gbufferViewNormal(dp1, dp2, duv1, duv2, vTexCoord);
        outMaterial = packGbufferMaterial(color, vTexCoord, duv1, duv2);
        outDetail = packGbufferDetail(viewNormal, vLmcoord);
        outColor = vec4(0.0);
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

#ifdef SR_ENTITY_VELOCITY
// SR 的 Iris at_velocity 扩展（OptiFine 原生同名）：观察空间「到上一帧顶点位置的偏移」，仅实体 /
// 方块实体绑定——attribute 关键字与 mc_Entity 同纪律（老 OptiFine 对 in 声明的自定义属性不绑定）
attribute vec3 at_velocity;
#endif

void main() {
    vec4 clipPos = ftransform();
#ifdef SR_ENTITY_VELOCITY
    // 无抖动 clip 位置直传（applyTAAJitter 会先缩放子区域再叠 jitter，事后无从还原）；at_velocity
    // 直传（顶点属性、fsh 重投影）。clip 未除 w 为仿射量、透视矫正插值精确——fsh 内除回取 uv
    //（2026-10 修复，见 fsh 段 varying 注释）
    vClipTrue = clipPos;
    vVelocity = at_velocity;
#endif
    gl_Position = applyTAAJitter(clipPos); // TAA 亚像素抖动，composite_taa 统一解析
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    // 天空环境基色探针（lib/lighting/ambient.glsl，与通用全屏 vsh 同一实现）：本程序不采样
    // 天空 LUT、有效性出参不消费（局部变量即丢弃）
    float lutValid;
    vSkyAmbient = skyAmbientColor(lutValid);

    // ---- 直射帧数据（与通用全屏 vsh / gbuffers_translucent 同名同式，见 program/fullscreen_vsh.glsl；
    // 取值实现已收敛进 lib/lighting/ambient.glsl 的 frameDirectIrradiance 单真源；「之后」路径的
    // forwardEntityShade 消费、「之前」路径不消费由链接器剔除）----
    vLightDirection = normalize(viewToWorldDirection(shadowLightPosition));
    vDirectIrradiance = frameDirectIrradiance(sin(sunAngle * TAU),
                                              normalize(viewToWorldDirection(moonPosition)).y);
    // 相机高度近似的直射透射率（shadeSurface 的 directTransmittance 同式）：与「之前」路径的
    // 延迟光照实体同屏时直射色 / 量级一致（日落红化同步）
    vDirectTransmittance = exp(-opticalDepthToSpace(EARTH_RADIUS + max(cameraPosition.y, 1.0),
                                                    vLightDirection.y));

    // pass 顺序判定一次（vsh 顶点级，fsh 经 flat varying 消费）
    vAfterDeferred = isAfterDeferred() ? 1.0 : 0.0;
}

#endif
