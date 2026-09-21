// 不透明 gbuffer（实体）: gbuffers_opaque_entities
// 与 gbuffers_opaque 的区别: 叠加 entityColor（受伤红闪等实体着色）后再写入 gbuffer
// 按 pass 顺序标记自适应（lib/common/pipeline/pass_order_marker.glsl，vsh 判定经 flat varying 下传）：
//   deferred 之前（引擎常规位）：MRT 写 colortex4/5（布局同 gbuffers_opaque 头部注释），colortex6
//     随写 0（deferred_init 全屏覆盖）——原有行为
//   deferred 之后（引擎变体防御位）：光照图轻量着色（forwardLightmapShade，与简单半透明同式）
//     手动 alpha 合成进线性主颜色 colortex6（本阶段引擎混合本就 off；主颜色在 colortex6 =
//     gbuffers 可采样的 gaux3，背景 fetch + mix 后写回同缓冲）；colortex4/5 本分支不写——
//     gbuffer 读者（deferred_init 几何分支）只读 depthtex1 < 1 像素、该区域每帧被不透明
//     gbuffers 先行整写，遗留内容活不到读者面前
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/space.glsl"
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
flat VARYING float vAfterDeferred; // pass 顺序判定 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:456 */

layout(location = 0) out vec4 outMaterial; // colortex4：「之前」= 打包几何 /「之后」= 不写（无读者）
layout(location = 1) out vec4 outDetail;   // colortex5：同上
layout(location = 2) out vec4 outColor;    // colortex6：「之后」= 手动合成光照 /「之前」= 随写 0（deferred 覆盖）

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;

    // 导数先于 discard（同 gbuffers_opaque 的顺序约束——discard 后幸存像素导数未定义）；
    // TBN 构造与 normals 采样推迟到 discard 之后
    vec3 dp1 = dFdx(vViewPos);
    vec3 dp2 = dFdy(vViewPos);
    vec2 duv1 = dFdx(vTexCoord);
    vec2 duv2 = dFdy(vTexCoord);

    // TAAU 子区域外片元剔除（机制与调用纪律见 noise.glsl 的 outsideRenderRegion；
    // 本程序已有 cutout discard、Early-Z 无额外损失——视锥边缘实体正是剔除的主要受益者）
    if (outsideRenderRegion()) discard;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴
    color.rgb = mix(color.rgb, entityColor.rgb, entityColor.a);
    // 上一行为 texcolor 的半透明混合、只作用于 rgb——标记不参与混合，a 通道整像素置空
    //（实体入口无 gsh 程序化判定，标记槽位恒空）；置空只作用「之前」路径的打包，「之后」
    // 路径的合成先取原始纹理 alpha
    float texAlpha = color.a;

    ivec2 pixel = ivec2(gl_FragCoord.xy);
    if (vAfterDeferred > 0.5) {
        // deferred 之后：轻量光照手动合成——背景取 gaux3（= colortex6 主颜色，deferred_init 写入；
        // 主颜色放 colortex6 正是为 gbuffers 阶段可采样——colortex0~3 采样单元被游戏纹理占用）；
        // 合成结果写回 colortex6，后续半透明层链式叠加背景正确；colortex4/5 本分支不写（见头注）
        vec2 lm = remapLightmap(vLmcoord);
        vec3 lit = forwardLightmapShade(srgbToLinear(color.rgb), lm, vSkyAmbient);
        outColor = vec4(mix(texelFetch(gaux3, pixel, 0).rgb, lit, texAlpha), 1.0);
    } else {
        // deferred 之前：几何进 colortex4/5（deferred_init 延迟光照）；colortex6 随写 0、覆盖
        color.a = MATERIAL_NONE;
        vec3 viewNormal = gbufferViewNormal(dp1, dp2, duv1, duv2, vTexCoord);
        outMaterial = packGbufferMaterial(color, vTexCoord);
        outDetail = packGbufferDetail(viewNormal, vLmcoord);
        outColor = vec4(0.0);
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    // 天空环境基色探针（lib/lighting/ambient.glsl，与通用全屏 vsh 同一实现）：本程序不采样
    // 天空 LUT、有效性出参不消费（局部变量即丢弃）
    float lutValid;
    vSkyAmbient = skyAmbientColor(lutValid);
    // pass 顺序判定一次（vsh 顶点级，fsh 经 flat varying 消费）
    vAfterDeferred = isAfterDeferred() ? 1.0 : 0.0;
}

#endif
