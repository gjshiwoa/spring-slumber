// 手动合成（带纹理）: gbuffers_color_textured
// deferred 之前绘制的混合几何在打包通道不能直接吃引擎 alpha 混合（字节串扰），按春雷方式：
// 关闭本程序混合（shaders.properties），着色器内采样已有内容手动合成后重新打包写入
// colortex4.rg（不写 colortex5，背景的法线 / lm 数据保持完好）；随后随背景像素一起
// 经过 deferred_init。当前消费者 = 蜘蛛眼 / 附魔光效（spidereyes / armor_glint 入口，
// 加色档）；附魔光效曾按反馈改道 gbuffers_color 常量 tint 档（无贴图采样的常量紫光泽）、
// 再按反馈回贴图路线（2026-10，git 历史含完整形态）；textured 族需要回退打包路线时
// 把入口指回（alpha 档缺省）
// 加色档（入口宏 MANUAL_COMPOSITE_ADDITIVE）：两族原版即加色混合（eyes 的 srcAlpha/ONE、
// glint 的 SRC_COLOR/ONE），mix 会把物品 albedo 整体替换成光效色膜——按 srcAlpha/ONE 近似
// 往背景 albedo 上加光、钳 1（打包 8bit 域上限，原版帧缓冲加色同样钳 1）；两族均不写深度
// （glint 的 EQUAL 深度测试对被贴附几何），背景 colortex5 原样保留 = 光效按被贴附表面的
// 法线 / lm 光照着色。已知取舍：albedo 路径经 deferred 照度乘法，夜间随光变暗——真自发光
// 须等 emissive 消费端（beacon 的 specular.a 同款扩展点）
// texcoord 基底 = gl_TextureMatrix[0] × gl_MultiTexCoord0（春雷 textured pass 同款）：
// glint 的滚动动画藏在纹理矩阵（缩放 + 时间平移），裸 texcoord 采出的是静态错位贴图；
// eyes / textured 族纹理矩阵恒等、逐位无感
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/utils/noise.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:4 */

layout(location = 0) out vec4 outMaterial; // colortex4

void main() {
    // TAAU 子区域外片元剔除（机制见 noise.glsl 的 outsideRenderRegion；手动合成的读回 /
    // 写回一并省去——光效层随实体几何贴附视锥边界，半透明类无 Early-Z 顾虑）
    if (outsideRenderRegion()) discard;

    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    // 与背景已写入的打包颜色手动合成（引擎混合已由 shaders.properties 关闭）；
    // 合成只作用于 rgb——物品标记不参与混合，a 通道整像素置空
    vec4 previous = texelFetch(gaux1, ivec2(gl_FragCoord.xy), 0);
    vec3 previousColor = unpack2x16To4x8(previous.rg).rgb;
#ifdef MANUAL_COMPOSITE_ADDITIVE
    // 加色档：往背景 albedo 上加光（原版 srcAlpha/ONE 的近似，两族见头注）
    color.rgb = min(previousColor + color.rgb * color.a, 1.0);
#else
    color.rgb = mix(previousColor, color.rgb, color.a);
#endif

    outMaterial = vec4(pack4x8To2x16(vec4(color.rgb, MATERIAL_NONE)), previous.ba);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动（含 TAAU 子区域缩放），composite_taa 统一解析
    vTexCoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy; // 纹理矩阵基底：glint 滚动动画所在（见头注）
    vColor = gl_Color;
}

#endif
