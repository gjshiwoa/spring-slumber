// gbuffer 写入侧：材质判定 + colortex4/5 打包输出（与 gbuffer_data.glsl 的读取端工具相对）
// 依赖先行 include：lib/common/globals/constants.glsl（PLANT_* / MATERIAL_*）、
//   lib/common/globals/uniforms.glsl（normals / specular）、lib/common/utils/space.glsl（viewToWorldDirection /
//   calculateTBN）、lib/common/utils/packing.glsl（pack4x8To2x16 / encodeOctahedral），
//   由 program 在本文件之前 include
#ifndef LIB_MATERIAL_GLSL
#define LIB_MATERIAL_GLSL

// 三角形是否疑似植被（草 / 花 / 苗等，春雷 isLikelyPlantTriangle 判据），两信号取或：
//   垂直交叉面片：三角形几何法线近水平（面片垂直地面）且 xz 分量对角——原版草 / 花 / 苗的
//     十字交叉模型两两正交再整体斜置 45°，法线落在对角方向
//   生物群系染色：三顶点平均顶点色 chroma 偏大——草 / 树叶带绿色 tint，未染色几何近灰
// 染色信号对草方块顶面等染色几何误报，由调用方（vsh 的 block.properties 显式标记）压制；
// 入参为三顶点观察空间位置与顶点色，按三角形整体分类、经 flat varying 下传
bool isLikelyPlantTriangle(vec3 viewPos[3], vec4 vertexColor[3]) {
    // 三角形两邻边差向量旋转到世界轴向（viewToWorldDirection 纯旋转，平移对差向量无效）
    vec3 edge0 = viewToWorldDirection(viewPos[1] - viewPos[0]);
    vec3 edge1 = viewToWorldDirection(viewPos[2] - viewPos[0]);
    vec3 geometricNormal = cross(edge0, edge1);
    float areaSquared = dot(geometricNormal, geometricNormal);
    if (areaSquared < 1e-8) return false; // 退化三角形（零面积）
    geometricNormal *= inversesqrt(areaSquared);

    vec2 horizontalNormal = abs(geometricNormal.xz);
    float diagonalness = min(horizontalNormal.x, horizontalNormal.y)
                       / max(max(horizontalNormal.x, horizontalNormal.y), 1e-5);
    bool verticalCrossPanel = abs(geometricNormal.y) < PLANT_PANEL_MAX_Y
                           && diagonalness > PLANT_PANEL_DIAGONAL;

    vec3 averageColor = (vertexColor[0].rgb + vertexColor[1].rgb + vertexColor[2].rgb) / 3.0;
    float colorChroma = max(averageColor.r, max(averageColor.g, averageColor.b))
                      - min(averageColor.r, min(averageColor.g, averageColor.b));
    bool tinted = colorChroma > PLANT_TINT_CHROMA_MIN;

    return verticalCrossPanel || tinted;
}

// ---- gbuffer 打包写入（gbuffers_opaque / entities / 前向半透明的「deferred 之前」路径共用）----
// 仅片段阶段（导数 TBN 与贴图采样；vsh / gsh 编译不展开，isLikelyPlantTriangle 独立可用）
#ifdef STAGE_FRAGMENT

// 观察空间法线：导数 cotangent TBN 变换 labPBR 贴图法线（*2-1，不翻 Y，春雷 / 春v2 同约定），
// 无 normals 纹理时贴图为 (0.5, 0.5, 1.0)、结果即导数几何法线。调用纪律：dp / duv 导数必须在
// discard 之前集中求好传入（discard 后 quad 内幸存像素的导数未定义）
vec3 gbufferViewNormal(vec3 dp1, vec3 dp2, vec2 duv1, vec2 duv2, vec2 texCoord) {
    mat3 tbn = calculateTBN(dp1, dp2, duv1, duv2);
    return normalize(tbn * (texture(normals, texCoord).rgb * 2.0 - 1.0));
}

// colortex4 输出：rg = 打包 albedo（rgba 已带标记位 a）、ba = 打包高光贴图 RGBA（labPBR 全量）
vec4 packGbufferMaterial(vec4 texcolorMarked, vec2 texCoord) {
    return vec4(pack4x8To2x16(texcolorMarked), pack4x8To2x16(texture(specular, texCoord)));
}

// colortex5 输出：rg = 八面体观察空间法线、ba = 原始 lmcoord（读取端 remapLightmap）
vec4 packGbufferDetail(vec3 viewNormal, vec2 lmcoordRaw) {
    return vec4(encodeOctahedral(viewNormal), lmcoordRaw);
}

#endif

#endif
