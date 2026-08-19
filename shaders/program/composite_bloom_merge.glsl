// Bloom 上采样合并 pass：composite_bloom_merge（world0/composite13 入口）
// 读 composite8~12 生成的 colortex1 tile 图集，5 个 tile 各经双线性放大、加权平均
// （lib/post/bloom.glsl 的 getBloom），乘 BLOOM_STRENGTH 与线性场景 colortex0 相加后写回 colortex0
// （tonemap 前线性域，与各参考包一致）；tile 图集自此被消费，colortex1 不再写入
// composite_tonemap 只做纯 AgX，不再叠加
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/post/bloom.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor;

void main() {
    vec3 scene = texture(colortex0, vTexCoord).rgb;
    outColor = vec4(scene + getBloom(vTexCoord) * BLOOM_STRENGTH, 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
