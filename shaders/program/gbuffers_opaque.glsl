// 不透明 gbuffer: gbuffers_opaque
// 不透明阶段，MRT 写两张（不写主颜色——colortex6 由 deferred_init 解包 colortex4 后写出）：
//   colortex4 = rg 打包 albedo（tex × 顶点色，4x8→2x16；a 通道在 cutout 判定后复用为物品标记
//               MATERIAL_*——vsh 按 block.properties 显式列表〔春v2 同款五族，isVegetationId〕
//               写 MATERIAL_VEGETATION），ba 打包高光贴图 RGBA（4x8→2x16）
//   colortex5 = rg 八面体观察空间法线（贴图法线经导数 TBN 变换，无 normals 纹理时为几何法线），ba 原始 lmcoord（读取端再重映射）
// albedo 存原始 sRGB（8bit 打包），反 gamma 由 deferred_init 侧统一处理；block / hand 入口复用本程序
// 植被判定 = block.properties → mc_Entity 显式列表（春v2 IDMapping 同款：高矮草 / 上下半 / 树叶各族
// 分列 ID；原程序化判定 isLikelyPlantVertex 与入口宏 OPAQUE_TERRAIN_MARKER 已删，git 历史含完整形态）——
// vsh 判定一次经 flat varying 下传；block / hand 入口 mc_Entity 无引擎填充，标记恒空
// 植物晃动（WAVING_PLANTS，春v2 移植）：vsh 世界锚定偏移（lib/common/pipeline/waving.glsl，同一函数
// 与 shadow pass 共用 → 阴影同步）；block / hand 入口属性未绑定、天然不晃
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一段

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/pipeline/waving.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/pipeline/material.glsl"
#include "/lib/common/utils/noise.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos;
flat VARYING float vMaterialID; // 物品标记：vsh 按 block.properties 显式列表写植被标记（春v2 同款），block / hand 入口恒空

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
// （已移除：植被判定原为 terrain 入口专属 gsh 按三角形兜底，后改 vsh 逐顶点程序化判定，
//   2026-09 起整体改为 block.properties 显式列表（春v2 同款）——见上方 vsh 段 isVegetationId；
//   world0/gbuffers_terrain.gsh 入口已删）

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

// block.properties 自定义方块 ID（x 分量，未定义方块 = -1；y 为渲染类型）：仅 terrain 等地形类入口
// 有引擎填充，block / hand 入口未绑定、取默认 0——不命中任何植被 ID，标记回落 MATERIAL_NONE。
// 声明取 vec4 通用形式（OptiFine 官方模板同型，z/w 不消费）——vec2 为 Iris 文档写法，老 OptiFine
// 的属性绑定对声明类型较挑剔，vec4 两家加载器通吃；关键字必须 attribute 而非 in——生态标准形态
// （Complementary / Photon 同款），老 OptiFine 对 in 声明的自定义属性不绑定（实测老版本显式标记
// 静默失效的根因），#version 330 compatibility 下 attribute 合法（兼容 profile 保留废弃关键字）
attribute vec4 mc_Entity;

#ifdef WAVING_PLANTS
// 纹理中点 uv（引擎标准属性、无需 properties 定义）：草类「上顶点」判定（v < 中点 = 几何上半，根部钉地）。
// block / hand 入口未绑定取 0 → 判定恒假，叠加 mc_Entity 恒 0 不命中晃动族——天然不晃
attribute vec4 mc_midTexCoord;
#endif

void main() {
    // 显式投影链替代 ftransform（数学等价）——植物晃动的世界偏移须在观察域插入、无法事后改 clip
    vec4 viewPos = gl_ModelViewMatrix * gl_Vertex;
#ifdef WAVING_PLANTS
    // 植物晃动（lib/common/pipeline/waving.glsl，春v2 移植）：总入口观察位置进出、换算矩阵按本阶段
    // 传入；分族门控在函数内先于世界坐标重建——非植物顶点（地形绝大多数）零矩阵开销；shadow 侧同一
    // 函数同一输入 → 贴图阴影与几何同步晃；vViewPos 用晃后值，fsh 导数法线与几何一致
    viewPos = applyPlantWaving(viewPos, gbufferModelViewInverse, mat3(gbufferModelView),
                               mc_Entity.x, gl_MultiTexCoord0.t, mc_midTexCoord.t);
#endif
    gl_Position = applyTAAJitter(gl_ProjectionMatrix * viewPos); // TAA 亚像素抖动，composite_taa 统一解析
    vViewPos = viewPos.xyz;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
    // 植被标记（block.properties 显式列表，春v2 同款五族 → isVegetationId；函数在 material.glsl）：
    // 草方块不在列表、天然空标记无 SSS；block / hand 入口 mc_Entity 恒 0 不命中
    vMaterialID = isVegetationId(mc_Entity.x) ? MATERIAL_VEGETATION : MATERIAL_NONE;
}

#endif
