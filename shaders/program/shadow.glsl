// 阴影贴图写入 pass: shadow（shadow 阶段）
// 引擎在本阶段把场景渲染进 shadowtex0（全几何深度）/ shadowtex1（仅不透明深度，两张由引擎自动分工），
// 本程序额外写 shadowcolor0 = 透射色（sRGB albedo，读取端 srgbToLinear）；blend.shadow = off（整像素写入，见 shaders.properties）
// 顶点：显式投影链（= ftransform）后线性扭曲 xy + 压缩 z——shadowDistort / SHADOW_DEPTH_SCALE 取自
// lib/common/utils/space.glsl，与读取端 lib/lighting/shadow.glsl 的 relativeWorldToShadowScreen
// 共用同一实现（对称性由共用结构性保证）；不注入 TAA jitter（阴影贴图按世界位置采样，抖动会错位）
// 植物晃动（WAVING_PLANTS）：与 gbuffers_opaque 同一函数（lib/common/pipeline/waving.glsl）、同一
// 绝对世界坐标锚定——贴图阴影随几何同步晃（两侧不一致才会闪烁，原「无 waving」注释所指的约束）
// fsh 手动 alpha test（ALPHA_CUTOUT）实现 cutout 透贴（树影镂空），深度随 discard 一并丢弃
// 水面特判（WATER_CAUSTICS）：mc_Entity 判水后改写焦散透射——rgb = 生物群系水色 tint ×
// lib/lighting/caustics.glsl 的焦散网（≤1，rgba8 上限）、a 通道 = SHADOW_COLOR_WATER_A 水标记，
// 读取端识别标记 ×WATER_CAUSTICS_BOOST 重建 >1 的 HDR 焦点；先于 cutout 判定（水纹理 alpha 不参与）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一段

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/pipeline/waving.glsl"
#include "/lib/lighting/caustics.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
#ifdef WATER_CAUSTICS
VARYING vec3 vWorldPos;      // 绝对世界坐标（焦散图案世界锚定；仅水顶点重建、非水写 0——fsh 只在 vIsWater 分支消费，见 vsh）
flat VARYING float vIsWater; // 水面标记（block.properties → mc_Entity；实体几何无引擎填充恒 0）
#endif

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor; // shadowcolor0：透射色（sRGB albedo，读取端 srgbToLinear）；水面 = 焦散×tint + a 通道水标记

void main() {
#ifdef WATER_CAUSTICS
    if (vIsWater > 0.5) {
        // rgba8 值域 [0,1]：焦散轮廓对比在写入端 shaping（网谷 CAUSTICS_BASE → 波前 1.0），
        // 亮度 >1 的 HDR 焦点由读取端按标记重建——两端的曲线分工见 constants.glsl 水焦散分区
        outColor = vec4(vColor.rgb * waterCaustics(vWorldPos), SHADOW_COLOR_WATER_A);
        return;
    }
#endif
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴（树叶等）

    outColor = vec4(color.rgb, 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

#if defined(WATER_CAUSTICS) || defined(WAVING_PLANTS)
attribute vec4 mc_Entity; // block.properties 自定义 ID（老 OptiFine 对 in 声明的自定义属性不绑定，attribute 为生态标准形态——见 AGENTS.md「gbuffer 打包与物品标记」）
#endif
#ifdef WAVING_PLANTS
attribute vec4 mc_midTexCoord; // 纹理中点 uv：草类「上顶点」判定（与 gbuffers_opaque 同款；实体几何未绑定恒不晃）
#endif

void main() {
    // 显式投影链（= ftransform，晃动偏移须在观察域插入）；shadow 阶段 gl_ModelViewMatrix = shadowModelView
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
#ifdef WATER_CAUSTICS
    // 水面世界坐标（焦散图案锚定）：晃动前锚定——水面（block.8）不在晃动族、偏移恒 0，先后无差。
    // 仅水顶点付逆矩阵重建：非水顶点写 0 免白付（与 vIsWater 同一条件门控，fsh 只在水分支消费、
    // 恒不读到占位值）
    vWorldPos = vec3(0.0);
    vIsWater = mc_Entity.x == BLOCK_WATER ? 1.0 : 0.0;
    if (vIsWater > 0.5) vWorldPos = (shadowModelViewInverse * viewPos).xyz + cameraPosition;
#endif
#ifdef WAVING_PLANTS
    // 植物晃动：与 gbuffers_opaque 同一函数（lib/common/pipeline/waving.glsl）、同一绝对世界坐标锚定
    // → 偏移逐位一致、阴影随几何同步晃；换算矩阵按本观察系传入，分族门控在函数内先于世界坐标重建
    // （非植物顶点零矩阵开销）；距离门同式（cameraPosition 在本阶段亦为玩家位置）
    viewPos = applyPlantWaving(viewPos, shadowModelViewInverse, mat3(shadowModelView),
                               mc_Entity.x, gl_MultiTexCoord0.t, mc_midTexCoord.t);
#endif
    vec4 clipPos = gl_ProjectionMatrix * viewPos;
    gl_Position = clipPos;
    gl_Position.xy = shadowDistort(gl_Position.xy); // 正交投影 w = 1，clip 与 NDC 同值
    gl_Position.z *= SHADOW_DEPTH_SCALE;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
}

#endif
