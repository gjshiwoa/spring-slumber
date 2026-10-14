// Voxy V1 片段补丁：面法线、材质标记与半透明 lightmap/type 编码。
// 依赖（program 平铺引入）：constants / packing。
// 宿主提供 VoxyFragmentParameters / vxModelView；program 提供输出与 VOXY_TRANSLUCENT_PATCH。
// voxy_emitFragment 为宿主规定的回调名，不是独立 pass 的 main。
#ifndef LIB_COMPAT_VOXY_MATERIAL_GLSL
#define LIB_COMPAT_VOXY_MATERIAL_GLSL

vec3 voxyFaceNormal(uint face) {
    return vec3(uint((face >> 1u) == 2u), uint((face >> 1u) == 0u), uint((face >> 1u) == 1u))
           * (float(int(face) & 1) * 2.0 - 1.0);
}

bool voxyVegetation(uint id) {
    return id == 31u || id == 10175u || id == 11175u || id == 18u || id == 10176u;
}

#ifdef VOXY_TRANSLUCENT_PATCH
void voxy_emitFragment(VoxyFragmentParameters p) {
    outTransColor = p.sampledColour * p.tinting;
    // 16bit lightmap 整数码 + 1：零留给清屏，负号标记水；RGBA32F 保持逐整数精确。
    float lmCode = floor(pack2x8To16(p.lightMap.x, p.lightMap.y) * 65535.0 + 0.5) + 1.0;
    // 只有水面消费法线；玻璃保留 lightmap/type，免做矩阵变换与八面体编码。
    vec2 normalOct = vec2(0.0);
    if (p.customId == uint(BLOCK_WATER)) {
        lmCode = -lmCode;
        normalOct = encodeOctahedral(normalize(mat3(vxModelView) * voxyFaceNormal(p.face)));
    }
    outTransDetail = vec4(normalOct, lmCode, 0.0);
}
#else
void voxy_emitFragment(VoxyFragmentParameters p) {
    vec4 albedo = p.sampledColour * p.tinting;
    albedo.a = voxyVegetation(p.customId) ? MATERIAL_LOD_VEGETATION : MATERIAL_LOD;
    outMaterial = vec4(pack4x8To2x16(albedo), pack4x8To2x16(vec4(0.0)));
    outDetail = vec4(encodeOctahedral(normalize(mat3(vxModelView) * voxyFaceNormal(p.face))),
                    p.lightMap);
}
#endif
#endif
