// 雨天地表湿滑 SSR: deferred_ssr（deferred2 槽——deferred1 之后、前向半透明与 composite 链之前；
// 2026-10 接入）：对 colortex6 就地混入湿滑地表的屏幕空间反射——可见度 = 湿度（lib/common/pipeline/
// wetness.glsl 的 terrainWetness，与 gbuffers_opaque 湿面法线压平同函数同输入；2026-10 侧面接入
// 后湿度随世界法线朝上度单调增——顶面满权、侧面半权、底面无湿，「越朝上可见度越高」由湿度场
// 的朝上度权重窗结构性承载，本 pass 无独立法线因子）× 水面 Fresnel 近似
//（lib/water/reflection.glsl 的 waterFresnel 水上档）；march / 命中验证 / 天空回退 / 命中段雾全链
// 复用水面反射件（lib/water/ssr.glsl + reflection.glsl）——单真源不抄式。
// 时序：deferred1 的输出（完整不透明光照 + before 路径粒子的 gbuffer 着色）即本 pass 的读入——
// SSR 命中色 / 天空回退都在光照后的 colortex6 上取色；输出仍写 colortex6（DRAWBUFFERS:6，同缓冲
// 读改写 = composite_fog 同款 ping-pong 已知取舍），之后的前向半透明（water / weather 等）在本结果
// 上叠层、composite_fog 对整像素按表面深度雾化——反射路径的段距离对它不可见，命中段雾已在本 pass
// 经 waterReflectionHitFog 就地施加（water 反射同理由）。colortex4 背景快照保持 deferred1 内容
//（不含湿滑反射——water 折射背景的已知取舍，见 AGENTS 已知限制）。
// 位置 / 法线 / lm 重建：depthtex1 + 去抖基底（deferred_init 同式「像素 uv − vJitter」）重建 viewPos，
// colortex5.rg 解包八面体法线（**已含 gbuffer 侧湿滑压平**——反射方向 / Fresnel / SSR 起点推离与
// 光照消费同一法线）、.a 原始 lm.y 喂湿度露天门。
// 守卫链（逐级早退；非雨天全屏常态成本 = 1 fetch + 透传写回）：雨强低于 SSR 门槛（uniform
// 分支）→ 天空像素（depth >= 1）→ 手部（NDC < TAA_HAND_DEPTH——手部深度经重映射、世界重建失真，
// TAA 同款排除）→ 前景半透明（depthtex0 < depthtex1 = before 路径粒子覆着该像素、SSR 不应加于
// 其上）→ 湿度 < WET_SSR_MIN_WETNESS（0.03——免 march 门槛**只看湿度、与视角 / Fresnel 无关**，
// 2026-10 按反馈自「湿度 × Fresnel < WET_SSR_MIN_WEIGHT」改判：旧门槛下 Schlick F0 0.02 使眼点
// 正下方 ~53° 锥内——地面投影为以脚下为圆心、半径 ≈ 1.34 × 相机离地高度的硬边干圈（越高越大）——
// 整片跳过；Fresnel 现只进 mix 权重，march / 天空回退覆盖全部过湿像素〔含俯视〕）。WET_SURFACE
// 删宏 = 反射段
// 整体编译剔除、本 pass 透传旁路（colortex6 原样写回——引擎缓冲翻转纪律不可 discard）。
// vsh = 通用全屏 vsh（TAAU 时 quad 经 FULLSCREEN_RENDER_REGION〔入口 vsh 定义〕缩进渲染子区域、
// 与 deferred_init / composite_fog 同款）；本 program 无自定义 vsh 段，fsh 按需声明同名 in。
// 下界 / 末地不建入口（无降雨，rainStrength 恒 0）。

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/compat/voxy/scene.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/lighting/ambient.glsl"
#include "/program/fullscreen_vsh.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/aerial.glsl"
#include "/lib/atmosphere/fog.glsl"
#include "/lib/common/pipeline/wetness.glsl"
#include "/lib/water/fog.glsl"
#include "/lib/water/ssr.glsl"
#include "/lib/water/reflection.glsl"

#ifdef STAGE_FRAGMENT
// 通用全屏 vsh 输出的帧数据——按需 in 声明（未声明的由链接器剔除、零成本）
in vec2 vJitter; // 去抖重建基底（deferred_init 同式消费）
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vDirectIrradiance; // 命中段雾（waterReflectionHitFog 的水下 / 水雾分支）消费
in vec3 vSkyAmbient;
in vec3 vHorizon;
flat in float vSkyLutValid; // 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）
#endif

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:6 */

layout(location = 0) out vec4 outColor; // colortex6：场景颜色（就地混入湿滑 SSR；alpha 无下游读者恒 1）

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec3 color = texelFetch(colortex6, pixel, 0).rgb;
    // 所有早退均透传写出，保留引擎 ping-pong 纪律；不能用 discard 旁路。
    outColor = vec4(color, 1.0);

#ifdef WET_SURFACE
    // puddle <= 1、两道门 <= 1：雨强本身已低于 SSR 门槛时整段免工作。
    // 保留原 0.01 雨强守卫；严格 < 门槛才排除，等于门槛仍参与。
    if (rainStrength <= 0.01 || rainStrength < WET_SSR_MIN_WETNESS) return;
    float depth = texelFetch(depthtex1, pixel, 0).r;
    if (depth < TAA_HAND_DEPTH) return;
#ifdef VOXY
    vec2 uv = applyInverseJitter(gl_FragCoord.xy / vec2(viewWidth, viewHeight), vJitter);
    vec3 viewPos = screenToViewCanonical(uv, depth);
    bool lodSurface;
    if (!voxyScenePosition(gl_FragCoord.xy, vJitter, depth, false, viewPos, lodSurface)) return;
    float frontDepth = texelFetch(depthtex0, pixel, 0).r;
    if (frontDepth < 1.0 && frontDepth < depth - 1e-6 &&
        screenToViewCanonical(uv, frontDepth).z > viewPos.z) return;
#else
    if (depth >= 1.0) return;
    if (texelFetch(depthtex0, pixel, 0).r < depth - 1e-6) return;
#endif

    vec4 gNormalLm = texelFetch(colortex5, pixel, 0);
    float wetSkyGate = terrainWetnessSkyGate(gNormalLm.a);
    // 露天上界先于法线解包 / 位置重建，弱天光像素无需采水坑噪声。
    if (wetSkyGate * rainStrength < WET_SSR_MIN_WETNESS) return;
    vec3 normalWorld = mat3(gbufferModelViewInverse) * decodeOctahedral(gNormalLm.rg);
#ifdef VOXY
    if (lodSurface) normalWorld = mat3(vxModelViewInv) * decodeOctahedral(gNormalLm.rg);
#endif
    float wetGate = wetSkyGate * terrainWetnessUpGate(normalWorld.y);
    if (wetGate * rainStrength < WET_SSR_MIN_WETNESS) return;

    // 原版档仍在湿度门之后重建；Voxy 档已用真实位置完成前景遮挡比较。
#ifndef VOXY
    vec2 uv = applyInverseJitter(gl_FragCoord.xy / vec2(viewWidth, viewHeight), vJitter);
    vec3 viewPos = screenToViewCanonical(uv, depth);
#endif
    vec3 relWorld = viewToRelativeWorld(viewPos);
    float wet = terrainWetnessFromGate(relWorld.xz + cameraPosition.xz, wetGate);
    // 只看湿度，不引入 Fresnel 门槛，避免脚下硬边干圈；gbuffer 微潮不受此门影响。
    if (!(wet >= WET_SSR_MIN_WETNESS)) return;
    vec3 viewDirW = normalize(viewToWorldDirection(viewPos));
    // 反射可见度 = 湿度 × 水面 Fresnel 近似（水上 Schlick 档——F0 0.02 与水面同源）；
    // Fresnel 只进 mix 权重（物理反射强度随掠射角增长）、不参与早退
    float weight = wet * waterFresnel(viewDirW, normalWorld, false);
    vec2 lm = remapLightmap(gNormalLm.ba);
    float distWorld = length(viewPos);

    // 直射天光门（shadeSurface 同窗同式）：只喂命中段雾的直射分量——洞穴 / 深室内
    // 湿面的反射命中色不带回直射雾色。镜中日 / 月盘不渲染（2026-10 按决策移除：
    // sunVisibility 实参恒 0、盘面连同「shadowtex1 单 tap 可见性 × 天光门」门控整段
    // 删除——省每反射像素一次 shadowmap fetch；阴雨天盘面本就被 SUN/MOON_DISK_RAIN_
    // FADE 大幅淡出、视觉损失轻微；水面反射不受影响，仍渲染并门控镜中盘）；
    // 天空 LUT / 云天空盒照常（环境无对应遮蔽信息）
    float skyGate = smoothstep(DIRECT_SKYLIGHT_GATE_LOW, DIRECT_SKYLIGHT_GATE_HIGH, lm.y);
    skyGate *= skyGate;
    skyGate *= skyGate; // pow4 整形（shadeSurface 同款）

    vec3 reflDirW = reflect(viewDirW, normalWorld);
    vec2 hitUv;
    float ssrConfidence;
    float hitDepth;
    // SSR 起点推离沿表面法线（waterSSR 的 faceNormalW 入参——湿面压平后的法线：顶面
    // 朝上、侧面水平，均为朝空气侧的几何面法线，等价水面的几何面推离语义）
    bool ssrHit = waterSSR(viewPos, mat3(gbufferModelView) * reflDirW, distWorld,
                           normalWorld, hitUv, ssrConfidence, hitDepth);
    vec3 reflColor = vec3(0.0);
    if (ssrHit) {
        // 命中色取本 pass 读入面（deferred1 完整光照；ping-pong 读副本恒为写入前
        // 内容，无读正在写歧义）；bilinear 与 water 命中采样同款
        reflColor = textureLod(colortex6, hitUv, 0.0).rgb;
        // 命中段雾：距离 = 眼→表面 + 表面→命中点折线全长（waterReflectionHitFog
        // 内部语义）；hitUv 为 buffer 域、深度取 march 门控同一纹素
        vec3 hitViewPos = waterSsrViewPosition(hitUv, hitDepth, vJitter);
        waterReflectionHitFog(reflColor, viewPos, relWorld.y + cameraPosition.y, hitViewPos,
                              lm, vSunDirection, vMoonDirection, vHorizon,
                              vSkyLutValid > 0.5, vDirectIrradiance * skyGate, vSkyAmbient);
    }
    if (!ssrHit || ssrConfidence < 1.0) {
        // 天空回退 = sky-view LUT + 烘焙云层天空盒 + 镜中边界雾（waterSkyReflection
        // 单真源；sunVisibility 恒 0 = 镜中日 / 月盘整项剔除〔见上注〕，LUT 天空 / 云 /
        // 镜中雾照常；阴天云 coverage 随 rainStrength 抬高、镜中自动阴天）——已含
        // lm.y 露天门（湿度自带，暗处湿地面本就不存在）
        vec3 fallback = waterSkyReflection(reflDirW, vSunDirection, vMoonDirection, vHorizon,
                                           vSkyLutValid > 0.5, 0.0);
        reflColor = mix(fallback, reflColor, ssrConfidence);
    }
    color = mix(color, reflColor, weight);
#endif // WET_SURFACE

    outColor = vec4(color, 1.0);
}

#endif
