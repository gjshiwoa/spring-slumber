// gbuffer 写入侧材质判定（与 gbuffer_data.glsl 的读取端工具相对）
// 依赖 lib/common/globals/constants.glsl（PLANT_*）、lib/common/utils/space.glsl（viewToWorldDirection，
// 依赖的 uniforms 由 uniforms.glsl 提供），由 program 在本文件之前 include
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

#endif
