// 最终输出: final（vsh = 通用全屏 vsh，本 program 无自定义 vsh 段；fsh 按需声明同名 in）
// 单 pass 收尾全链（BSL / Complementary 同款合并，不占 composite 槽）：读线性主颜色 colortex6
//（composite_taa 后、未曝光）+ colortex1 tile0 → 线性域合成 bloom（getBloom × BLOOM_STRENGTH）
// → 乘 vExposure（composite12 写入槽位，vsh 取一次经 varying 传入）→ AgX → linearToSrgb 输出屏幕。
// linearToSrgb 是全管线唯一离开线性空间的位置；原 composite13/14 两全屏 pass 的主颜色读写
// 往返与 colortex7 全屏透传（~46B/px@1080p）由此消除

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/lighting/ambient.glsl"
#include "/program/fullscreen_vsh.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

// 通用全屏 vsh 输出的帧数据——按需 in 声明
in vec2 vTexCoord;  // 全屏 uv
in float vExposure; // 本帧自适应曝光（composite12 已写入槽位）

// 缓冲格式常量集中在 lib/common/globals/constants.glsl（program 平铺 include，OptiFine/Iris 扫描展开后内容）
layout(location = 0) out vec4 outColor;

void main() {
    vec3 color = texelFetch(colortex6, ivec2(gl_FragCoord.xy), 0).rgb;
    color += getBloom(vTexCoord) * BLOOM_STRENGTH; // tonemap 前线性域合成
    color *= vExposure;
    outColor = vec4(linearToSrgb(agx(color)), 1.0);
}

#endif
