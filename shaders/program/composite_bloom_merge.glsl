// Bloom 上采样合并 pass：composite_bloom_merge（world0/composite13 入口）
// 读 composite8~12 生成的 colortex1 tile 图集，5 个 tile 各经双线性放大、加权平均
// （lib/post/bloom.glsl 的 getBloom），乘 BLOOM_STRENGTH 与线性场景 colortex0 相加后写回 colortex0
// （tonemap 前线性域，与各参考包一致）；tile 图集自此被消费，colortex1 不再写入
// 兼自动曝光寄生存储（春v2 composite21 同款 pass 设计，不新增 pass）：colortex7 右上角 1 texel
// 存适应后曝光——角点像素测图集最粗 tile（tile4）的对数平均亮度（春雷算法，固定 16 点均匀抖动
// 采样核，lib/post/exposure.glsl）、与角点上一帧曝光指数平滑后写回；其余像素 colortex7 同位置读回原样透传
// （colortex7Clear = false + 每帧全屏透传跨帧保值，对 main/alt 翻转免疫，后续杂项槽位同理共存）；
// composite_tonemap 读角点在 AgX 前乘一次。vsh 保持全屏（merge 须覆盖全屏，角点 fragment 恒存在）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:07 */

layout(location = 0) out vec4 outColor;
layout(location = 1) out vec4 outMisc;

void main() {
    vec3 scene = texture(colortex0, vTexCoord).rgb;
    outColor = vec4(scene + getBloom(vTexCoord) * BLOOM_STRENGTH, 1.0);

    // 自动曝光寄生存储：仅右上角 1 texel 付测光成本，其余像素透传保持 colortex7 既有内容
    if (ivec2(gl_FragCoord.xy) == exposureTexel()) {
        outMisc = vec4(adaptedExposure(targetExposure(sceneAverageLuminance())), 0.0, 0.0, 1.0);
    } else {
        outMisc = texelFetch(colortex7, ivec2(gl_FragCoord.xy), 0);
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
