// 最终输出: final
// 单 pass 完成收尾全链（BSL / Complementary 的 final 同款合并，免占 composite 槽）：
//   读线性 colortex0（composite_taa 后的未曝光线性 HDR）+ colortex1 tile0（上采样回卷合并后的
//   完整泛光）→ tonemap 前线性域合成（getBloom tent 放大 × BLOOM_STRENGTH 相加）→
//   乘 colortex7 曝光槽位的自适应曝光（lib/post/exposure.glsl，composite12 测光并写入；
//   vsh 取一次经 varying 传入，免每像素对槽位 texelFetch）→ AgX tonemap（末段 pow 2.2 即
//   「回到线性」display-referred linear，春雷同款）→ gamma 矫正（linearToSrgb）输出到屏幕
// linearToSrgb 是全管线唯一离开线性空间的位置；colortex0 终态保持 TAA 后线性 HDR，
// 原先 composite13（bloom 合成）/ composite14（tonemap）两个全屏 pass 的 colortex0 读写
// 往返与 colortex7 全屏透传（合计 ~46B/px@1080p）由此消除
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/tonemap.glsl"
#include "/lib/post/exposure.glsl"

VARYING vec2 vTexCoord;
VARYING float vExposure; // 全屏恒定：四顶点写同值，插值精确

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

// 缓冲格式常量集中在 lib/common/globals/constants.glsl（program 平铺 include，OptiFine/Iris 扫描展开后内容）
layout(location = 0) out vec4 outColor;

void main() {
    vec3 color = texture(colortex0, vTexCoord).rgb;
    color += getBloom(vTexCoord) * BLOOM_STRENGTH; // tonemap 前线性域合成
    color *= vExposure;
    outColor = vec4(linearToSrgb(agx(color)), 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
    vExposure = readAdaptedExposure();
}

#endif
