// 前向半透明（完整处理）: gbuffers_translucent
// water 入口。按 pass 顺序标记自适应（lib/common/pipeline/pass_order_marker.glsl，vsh 判定经
// flat varying 下传——与 gbuffers_translucent_simple 同构）；「之后」路径分两档、由入口宏
// FORWARD_HW_BLEND 选择（water 族恒 deferred 后、入口启用）：
//   deferred 之后 + FORWARD_HW_BLEND（water 入口）：光照图轻量着色（forwardLightmapShade，与
//     简单半透明同式）后输出直通 (lit, alpha)、引擎硬件混合（ROP srcAlpha/1−srcAlpha 原子合成
//     进 colortex6）——手动「texelFetch 背景 + mix」的读改写在同一 draw 内重叠半透明片段间是
//     竞态（后片元读到 draw 前旧背景、层层覆盖，逐帧竞态结果不同 = 重叠处纹理闪烁——雨丝交叉 /
//     瀑布叠面实测；主颜色 16F 后幅度不再被旧 RGBA16 副本钳位压缩、更显眼），ROP 按提交序原子
//     叠层根治、跨 draw 亦天然正确，且消除本族「读正在写的缓冲」取舍；单附件 DRAWBUFFERS:6
//     （下放入口）、colortex4/5 完全不写
//   deferred 之后 + 手动档（无宏）：背景 fetch gaux3（= colortex6 主颜色）+ mix 写回——跨 draw
//     链式叠加正确，同 draw 重叠竞态为本档残余（时机两可的 textured 族专属本程序结构）
//   deferred 之前（引擎变体防御位）：不计算光照，几何打包写 colortex4/5（同 gbuffers_opaque
//     格式），deferred_init 解包延迟光照；colortex6 随写 0（deferred_init 全屏覆盖）——要求
//     引擎混合关（打包整像素写入），FORWARD_HW_BLEND 档恒不达（water 恒 deferred 后）、防御性
//     只写 colortex6
// DRAWBUFFERS 下放入口文件（多入口输出不同，同 composite_bloom_upsample 惯例）：
// FORWARD_HW_BLEND 档 6、手动档 456；引擎混合开关同在 shaders.properties 按阶段名配置
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/common/pipeline/pass_order_marker.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/material.glsl"
#include "/lib/lighting/ambient.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos; // 「之前」路径导数法线的位置基底（同 gbuffers_opaque）
VARYING vec3 vSkyAmbient; // 天空环境辐照度基色（vsh 探针一次取好；同通用全屏 vsh 的同名 varying 语义）
flat VARYING float vAfterDeferred; // pass 顺序判定 0/1（flat float——bool varying 不为补丁器 / 部分驱动所容）

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

// DRAWBUFFERS 在入口文件：FORWARD_HW_BLEND 档 6（单附件、引擎混合）/ 手动档 456（多入口输出不同）

#ifdef FORWARD_HW_BLEND
layout(location = 0) out vec4 outColor; // colortex6：直通 (lit, alpha)、引擎 ROP 原子合成
#else
layout(location = 0) out vec4 outMaterial; // colortex4：「之前」= 打包几何 /「之后」= 不写（无读者）
layout(location = 1) out vec4 outDetail;   // colortex5：同上
layout(location = 2) out vec4 outColor;    // colortex6：「之后」= 手动合成光照 /「之前」= 随写 0（deferred 覆盖）
#endif

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;

    // 导数先于 discard（「之前」路径 TBN 需要；纪律同 gbuffers_opaque）
    vec3 dp1 = dFdx(vViewPos);
    vec3 dp2 = dFdy(vViewPos);
    vec2 duv1 = dFdx(vTexCoord);
    vec2 duv2 = dFdy(vTexCoord);

    // TAAU 子区域外片元剔除（机制见 noise.glsl 的 outsideRenderRegion；水面大三角形常跨视锥
    // 边界、剔除收益可观，半透明混合本无 Early-Z 顾虑）
    if (outsideRenderRegion()) discard;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    if (vAfterDeferred > 0.5) {
        // deferred 之后：光照图轻量着色（forwardLightmapShade）后按档合成（两档语义见头注）
        vec2 lm = remapLightmap(vLmcoord);
        vec3 lit = forwardLightmapShade(srgbToLinear(color.rgb), lm, vSkyAmbient);
#ifdef FORWARD_HW_BLEND
        outColor = vec4(lit, color.a); // 直通 alpha、引擎 ROP 原子合成（draw 内重叠定序正确）
#else
        // 手动档：背景取 gaux3（= colortex6 主颜色，deferred_init 写入；主颜色放 colortex6 正是为
        // gbuffers 阶段可采样——colortex0~3 采样单元被游戏纹理占用）；合成结果写回 colortex6、
        // 跨 draw 链式叠加背景正确；colortex4/5 本分支不写（无读者，见头注）
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        vec3 composited = mix(texelFetch(gaux3, pixel, 0).rgb, lit, color.a);
        outColor = vec4(composited, 1.0);
#endif
    } else {
        // deferred 之前：几何进 colortex4/5（deferred_init 延迟光照）；alpha 的 cutout 职责已尽、
        // a 通道置空标记；colortex6 随写 0、deferred_init 覆盖。FORWARD_HW_BLEND 档恒不达
        //（water 恒 deferred 后）、不写 gbuffer
#ifndef FORWARD_HW_BLEND
        vec3 viewNormal = gbufferViewNormal(dp1, dp2, duv1, duv2, vTexCoord);
        color.a = MATERIAL_NONE;
        outMaterial = packGbufferMaterial(color, vTexCoord);
        outDetail = packGbufferDetail(viewNormal, vLmcoord);
#endif
        outColor = vec4(0.0);
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    // 天空环境基色探针（lib/lighting/ambient.glsl，与通用全屏 vsh 同一实现）；out lutValid 为探针
    // 签名的固定出参、本程序只取 rgb 不消费
    float lutValid;
    vSkyAmbient = skyAmbientColor(lutValid);
    // pass 顺序判定一次（vsh 顶点级，fsh 经 flat varying 消费）
    vAfterDeferred = isAfterDeferred() ? 1.0 : 0.0;
}

#endif
