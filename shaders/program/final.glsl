// 最终输出: final（vsh = 通用全屏 vsh，本 program 无自定义 vsh 段；fsh 按需声明同名 in）
// 单 pass 收尾全链（BSL / Complementary 同款合并，不占 composite 槽）：读线性主颜色 colortex6
//（composite_taa 后、未曝光）+ colortex1 tile0 → 线性域合成 bloom（getBloom × BLOOM_STRENGTH）
// → 乘 vExposure（composite12 写入槽位，vsh 取一次经 varying 传入）→ RCAS 锐化（春雷移植，
// 见下）→ AgX → linearToSrgb 输出屏幕。linearToSrgb 是全管线唯一离开线性空间的位置；
// 原 composite13/14 两全屏 pass 的主颜色读写往返与 colortex7 全屏透传（~46B/px@1080p）由此消除
//
// RCAS（FSR1，春雷移植；「感知域统计 + 线性域组合」形态——按性能反馈重构，首版「十字 5-tap
// 各过一遍 bloom+曝光+AgX」的 agx ×5 偏重）：春雷的 tonemap 在前序 composite 完成、final 直接
// fetch 邻域即得 RCAS 设计域（tonemap 后 [0,1]——限幅公式 hitMax 以 1 为白点，HDR 线性直入
// >1 通道限幅失效、亮区静默不锐化）；本包 tonemap 在 final 内，而 lobe（自适应增益）只依赖
// 邻域的单调统计量（min / max / 比值），故 5-tap 经 Reinhard 代理 x/(x+k)（k = RCAS_SURROGATE_K，
// 锚定 agx 曲线形状）只喂 rcasLobe 取增益——春雷 rcasFilter 的限幅 / 去噪逐式保留；输出组合
//(lobe·Σ邻 + 中心)/(4·lobe+1) 在线性域施加（pre-tonemap 锐化：过冲由 agx 吸收——BSL 等前锐化
// 同款纪律，agx 首行 max(·,0) 钳负向过冲），末段单次 agx。bloom 低频场（tile0 双线性）对
// ±1px 邻域近似恒定，中心一次采样供 5-tap 共享——泛光不参与锐化、亦省 4 次 bloom fetch。
// lobe → 0（RCAS_SHARPNESS 调大）时输出逐位退化回接入 RCAS 前的直通链
//
// 性能（二次优化，按反馈）：① **天空像素整段跳过**——depthtex0 ≥ 1 门控（天空 LUT / 云平滑，
// RCAS 在彼处近似 no-op），户外 30~50% 像素免 4 次邻域 fetch 与 lobe 统计；**TAAU 下取 depth 前
// 须 pixel × RENDER_SCALE 映射回渲染域**——final 全屏 vs depth 渲染子区域，子区域外是每帧 clear
// 值 1.0，直取会把顶部 / 右侧 1−S 带整带误判天空（该带为上采样出的正常画面内容）；取 depthtex0
// 而非 tex1：雨 / 手等最终图像内容在 tex0、属锐化受益对象（texelFetch 无隐式导数，分支内采样安全）；
//已知取舍：云 / 日盘边像素同在天空气分支、不被锐化（云走柔和风格，观感不合意则去门控）。② 总开关宏
// RCAS（constants.glsl，删定义整段编译剔除——调大 RCAS_SHARPNESS 只压增益不省采样）

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
    // bloom 先行取一次（tonemap 前线性域合成；低频场对十字邻域近似恒定，5-tap 共享、泛光不参与锐化）
    vec3 bloom = getBloom(vTexCoord) * BLOOM_STRENGTH;

    // 直通链（无 RCAS / 天空像素共用）：中心 tap + bloom + 曝光 = 线性组合域的中心值
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec3 color = (texelFetch(colortex6, pixel, 0).rgb + bloom) * vExposure;

#ifdef RCAS
    // 天空门控见文件头：几何像素才锐化（分支内 texelFetch 无隐式导数、安全）
#ifdef TAAU
    ivec2 depthPixel = ivec2(vec2(pixel) * RENDER_SCALE); // 屏幕域 → 渲染子区域（子区域外 depth 为 clear 值）
#else
    ivec2 depthPixel = pixel;
#endif
    if (texelFetch(depthtex0, depthPixel, 0).r < 1.0) {
        // RCAS 十字邻域：线性域留作输出组合，Reinhard 代理域只喂 rcasLobe 统计（见文件头）
        ivec2 sizeMax = textureSize(colortex6, 0) - ivec2(1); // 边缘 tap 越界钳回（texelFetch 越界未定义）
        const ivec2 rcasNeighborOffsets[4] = ivec2[4]( // b d f h（FSR1 记法；e = 中心直通值）
            ivec2( 0, -1), ivec2(-1,  0), ivec2( 1, 0), ivec2( 0,  1));
        vec3 neighborLinear[4];
        vec3 neighborPerceptual[4];
        for (int i = 0; i < 4; i++) {
            vec3 tap = texelFetch(colortex6, clamp(pixel + rcasNeighborOffsets[i], ivec2(0), sizeMax), 0).rgb;
            tap = (tap + bloom) * vExposure; // agx 输入域 = 组合域（pre-tonemap 锐化）
            neighborLinear[i] = tap;
            neighborPerceptual[i] = tap / (tap + RCAS_SURROGATE_K);
        }
        vec3 centerPerceptual = color / (color + RCAS_SURROGATE_K);

        float lobe = rcasLobe(neighborPerceptual[0], neighborPerceptual[1], centerPerceptual, neighborPerceptual[2], neighborPerceptual[3], RCAS_SHARPNESS);
        color = (lobe * (neighborLinear[0] + neighborLinear[1] + neighborLinear[2] + neighborLinear[3]) + color) / (4.0 * lobe + 1.0);
    }
#endif

    outColor = vec4(linearToSrgb(agx(color)), 1.0);
}

#endif
