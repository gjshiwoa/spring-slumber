// 不透明 gbuffer（实体）: gbuffers_opaque_entities
// 与 gbuffers_opaque 的区别: 叠加 entityColor（受伤红闪等实体着色）后再写入 gbuffer
// MRT 写两张（colortex4/5，布局同 gbuffers_opaque 头部注释），colortex0/1 不写
// 骨架阶段不做光照与颜色空间转换
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/packing.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec2 vLmcoord;
VARYING vec3 vViewPos;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:45 */

layout(location = 0) out vec4 outMaterial; // colortex4
layout(location = 1) out vec4 outDetail;  // colortex5

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴
    color.rgb = mix(color.rgb, entityColor.rgb, entityColor.a);

    // 高光贴图 RGBA 全量打包（labPBR: r smoothness / g F0 / b porosity·SSS / a emissive）
    vec4 specularMap = texture(specular, vTexCoord);

    // 观察空间法线：导数 cotangent TBN 变换 labPBR 贴图法线（*2-1，不翻 Y，春雷 / 春v2 同约定），
    // 无 normals 纹理时贴图为 (0.5, 0.5, 1.0)，变换后即导数几何法线
    mat3 tbn = calculateTBN(vViewPos, dFdx(vTexCoord), dFdy(vTexCoord));
    vec3 viewNormal = normalize(tbn * (texture(normals, vTexCoord).rgb * 2.0 - 1.0));

    outMaterial = vec4(pack4x8To2x16(color), pack4x8To2x16(specularMap));
    outDetail = vec4(encodeOctahedral(viewNormal), vLmcoord); // lmcoord 存原始值
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
    vLmcoord = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
}

#endif
