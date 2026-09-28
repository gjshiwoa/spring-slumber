// gbuffer 写入侧：材质判定 + colortex4/5 打包输出（与 gbuffer_data.glsl 的读取端工具相对）
// 依赖先行 include：lib/common/globals/constants.glsl（MATERIAL_*）、
//   lib/common/globals/uniforms.glsl（normals / specular）、lib/common/utils/space.glsl（calculateTBN）、
//   lib/common/utils/packing.glsl（pack4x8To2x16 / encodeOctahedral），
//   由 program 在本文件之前 include
#ifndef LIB_MATERIAL_GLSL
#define LIB_MATERIAL_GLSL

// block.properties 自定义方块 ID（mc_Entity.x）→ 是否植被（春v2 materialIdMapper 的 IDMapping 植被族
// 同款列表，ID 语义见 constants.glsl 的 block.properties 段）：31 = 矮草 / 花 / 农作物、10175 / 11175 =
// 双高植物下 / 上半（tall_grass 等，`half=` 属性匹配——高矮草由此区分）、18 = 树叶 / 藤蔓 / 海草、
// 10176 = 其他植物 / 片状物。五族在春v2 各自驱动摇晃 / 阴影差异，本包统一映射 MATERIAL_VEGETATION
//（SSS 单档、无 waving）。未定义方块（-1）/ 未绑定属性（0）不命中；terrain 入口 vsh 判定一次经
// flat varying 下传；原程序化判定 isLikelyPlantVertex（法线交叉面片 × 染色 chroma）已删，git 历史含完整形态
bool isVegetationId(float blockId) {
    switch (int(round(blockId))) {
        case 31:
        case 10175:
        case 11175:
        case 18:
        case 10176:
            return true;
        default:
            return false;
    }
}

// ---- gbuffer 打包写入（gbuffers_opaque / entities / 前向半透明的「deferred 之前」路径共用）----
// 仅片段阶段（导数 TBN 与贴图采样；vsh 编译不展开，isVegetationId 任意阶段独立可用）
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
