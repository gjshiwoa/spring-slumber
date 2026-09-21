// 不透明 gbuffer: gbuffers_opaque
// 不透明阶段，MRT 写两张（不写主颜色——colortex6 由 deferred_init 解包 colortex4 后写出）：
//   colortex4 = rg 打包 albedo（tex × 顶点色，4x8→2x16；a 通道在 cutout 判定后复用为物品标记
//               MATERIAL_*——vsh 先写 block.properties 显式标记（草方块 → MATERIAL_SOLID 排除），
//               terrain 入口空标记时由下方 gsh 段程序化判定植被），ba 打包高光贴图 RGBA（4x8→2x16）
//   colortex5 = rg 八面体观察空间法线（贴图法线经导数 TBN 变换，无 normals 纹理时为几何法线），ba 原始 lmcoord（读取端再重映射）
// albedo 存原始 sRGB（8bit 打包），反 gamma 由 deferred_init 侧统一处理；block / hand 入口复用本程序
// 植被判定为 terrain 入口专属的几何着色器（STAGE_GEOMETRY 段，春雷 isLikelyPlantTriangle 判据），
// 按 per-triangle 分类经 flat varying 下传、仅在 vsh 空标记时兜底（显式标记来源见 vsh 的 mc_Entity）；
// block / hand 入口无 gsh、mc_Entity 亦无引擎填充，标记恒空
// fsh 前半 / vsh 后半（+ 可选 gsh 段），入口文件用 STAGE_FRAGMENT / STAGE_VERTEX / STAGE_GEOMETRY 选择编译哪一段

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/material.glsl"
#include "/lib/common/utils/noise.glsl"

// terrain 入口挂几何着色器（OPAQUE_GSH 由 world0/gbuffers_terrain.vsh 定义，block / hand 不定义）：
// GLSL 单命名空间，gsh 的 in/out 不得同名——vsh 输出侧挂 vGsh 前缀给 gsh 消费、gsh 输出还原原名
// 衔接 fsh（春v2 terrain 的 v_ 前缀同名法）；无 gsh 的入口 vsh 原名直连 fsh，编译路径不受影响
#if defined STAGE_VERTEX && defined OPAQUE_GSH
#define vTexCoord   vGshTexCoord
#define vColor      vGshColor
#define vLmcoord    vGshLmcoord
#define vViewPos    vGshViewPos
#define vMaterialID vGshMaterialID
#endif

// gsh 编译段自带 in/out 声明（数组 + 双向），不经过 VARYING 宏
#ifndef STAGE_GEOMETRY
VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos;
flat VARYING float vMaterialID; // 物品标记：vsh 写 block.properties 显式标记（或空），terrain 空标记时由 gsh 程序化补判、其余入口恒空
#endif

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:45 */

layout(location = 0) out vec4 outMaterial; // colortex4
layout(location = 1) out vec4 outDetail;  // colortex5

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;

    // 导数必须先于 discard：规范允许实现在 discard 后任意终止调用，quad 内被终止 texel 的寄存器
    // 值未定义、幸存像素的 dFdx/dFdy（及隐式 LOD）会拿到垃圾（cutout 边缘法线错乱的根源）；
    // 先集中求好再过 discard，TBN 构造与 normals 采样推迟到后面
    vec3 dp1 = dFdx(vViewPos);
    vec3 dp2 = dFdy(vViewPos);
    vec2 duv1 = dFdx(vTexCoord);
    vec2 duv2 = dFdy(vTexCoord);

    // TAAU 子区域外片元剔除（纯性能剔除，纪律见 noise.glsl；本程序已有 cutout discard、Early-Z 无额外损失）
    if (outsideRenderRegion()) discard;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴（树叶等）

    // alpha 的 cutout 职责已尽，a 通道槽位改存物品标记（随 pack4x8To2x16 一同压缩进 colortex4.rg）
    color.a = vMaterialID;

    // 观察空间法线与打包输出（函数在 lib/common/pipeline/material.glsl，与 entities / 前向半透明
    // 的「deferred 之前」路径共用；调用纪律：导数先于 discard 已求好）
    vec3 viewNormal = gbufferViewNormal(dp1, dp2, duv1, duv2, vTexCoord);
    outMaterial = packGbufferMaterial(color, vTexCoord);
    outDetail = packGbufferDetail(viewNormal, vLmcoord); // lmcoord 存原始值
}

#endif

// ================================ GEOMETRY ================================
#ifdef STAGE_GEOMETRY
// 植被程序化判定（仅 terrain 入口挂接，判据函数在 lib/common/pipeline/material.glsl）：
// 按三角形整体分类、经 flat varying 下传，fsh 写入 albedo a 通道
layout(triangles) in;
layout(triangle_strip, max_vertices = 3) out;

in vec2 vGshTexCoord[3];
in vec4 vGshColor[3];
in vec2 vGshLmcoord[3];
in vec3 vGshViewPos[3];
flat in float vGshMaterialID[3];

out vec2 vTexCoord;
out vec4 vColor;
out vec2 vLmcoord;
out vec3 vViewPos;
flat out float vMaterialID;

void main() {
    // vsh 经 mc_Entity / block.properties 写入显式标记、gsh 仅空标记时程序化兜底（春雷同构）
    float primitiveMarker = vGshMaterialID[0];
    if (primitiveMarker < 0.5 && isLikelyPlantTriangle(vGshViewPos, vGshColor)) {
        primitiveMarker = MATERIAL_VEGETATION;
    }

    for (int i = 0; i < 3; ++i) {
        vTexCoord   = vGshTexCoord[i];
        vColor      = vGshColor[i];
        vLmcoord    = vGshLmcoord[i];
        vViewPos    = vGshViewPos[i];
        vMaterialID = primitiveMarker;
        gl_Position = gl_in[i].gl_Position; // vsh 已注入 TAA jitter，原样透传
        EmitVertex();
    }
    EndPrimitive();
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

// block.properties 自定义方块 ID（x 分量，未定义方块 = -1；y 为渲染类型）：仅 terrain 等地形类入口
// 有引擎填充，block / hand 入口未绑定、取默认 0——不命中任何 BLOCK_* 常量，标记回落 MATERIAL_NONE。
// 声明取 vec4 通用形式（OptiFine 官方模板同型，z/w 不消费）——vec2 为 Iris 文档写法，老 OptiFine
// 的属性绑定对声明类型较挑剔，vec4 两家加载器通吃
in vec4 mc_Entity;

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    // 显式标记（block.properties）：草方块顶面带生物群系染色、会被 gsh 的 chroma 判据误标——
    // 在此显式置 MATERIAL_SOLID，gsh 见非空标记不再兜底（读取端 SSS 强度取 0）
    vMaterialID = mc_Entity.x == BLOCK_GRASS_BLOCK ? MATERIAL_SOLID : MATERIAL_NONE;
}

#endif
