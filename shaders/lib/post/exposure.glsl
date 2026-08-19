// 自动曝光工具库：亮度算法参考春雷 passes/08_composite/auto_exposure.glsl
// （bloom 图集最粗 tile 16 点均匀采样对数平均 + 0.18 key 直除 + 曝光域指数时间适应），
// pass 设计参考春v2 program/composite21.glsl（寄生 bloom 合并 pass 测光、单像素存储、
// 全屏透传跨帧保值，无 flip.* 依赖；春雷的 compute / SSBO 载体与本项目 GLSL 330 低配定位不符，只搬算法不搬载体）
// 依赖先行 include：lib/common/globals/constants.glsl（AUTO_EXPOSURE_*）、
// lib/common/globals/uniforms.glsl（colortex1 / colortex7 / frameTime / viewWidth / viewHeight）、
// lib/post/bloom.glsl（bloomTileRect / BLOOM_TILE_COUNT）、lib/common/utils/color.glsl（rgbToLuma）
#ifndef LIB_EXPOSURE_GLSL
#define LIB_EXPOSURE_GLSL

// colortex7 右上角 1 texel：自适应曝光槽位（杂项缓冲的第一个槽）
ivec2 exposureTexel() {
    return ivec2(viewWidth, viewHeight) - 1;
}

// 场景平均亮度（春雷同款对数平均）：在 bloom 图集最粗 tile（tile4，1/64 分辨率低频 HDR）上
// 以固定 16 点均匀抖动网格核采样（EXPOSURE_SAMPLE_KERNEL，4×4 每单元一个随机点，全域覆盖无聚集），
// avgLum = exp(mean(log(luma + MIN_LUMINANCE)))——对数域平均抑制高光算术级主导，暗部话语权更高；
// 测量语义与春雷 lod8 / 春v2 金字塔顶微块一致：未乘曝光、未加回 bloom 的线性场景。
// 采样规模与春v2 的 16 点盘采样同档：tile4 每纹素经链式下采样已聚合约 64² 屏幕像素、
// 内容极低频，16 点估计均值充分；测光成本与分辨率解耦（全遍历在 4K 下 2000+ fetch），
// 固定核保证帧间稳定不闪烁
float sceneAverageLuminance() {
    ivec2 atlasSize = textureSize(colortex1, 0);
    vec4 rect = bloomTileRect(BLOOM_TILE_COUNT - 1);
    ivec2 origin = ivec2(rect.xy * atlasSize);
    ivec2 extent = max(ivec2(rect.zw * atlasSize), ivec2(1));

    float logLumSum = 0.0;
    for (int i = 0; i < EXPOSURE_SAMPLE_COUNT; i++) {
        ivec2 p = origin + clamp(ivec2(EXPOSURE_SAMPLE_KERNEL[i] * extent), ivec2(0), extent - 1);
        vec3 c = max(texelFetch(colortex1, p, 0).rgb, vec3(0.0));
        logLumSum += log(rgbToLuma(c) + AUTO_EXPOSURE_MIN_LUMINANCE);
    }
    return exp(logLumSum / float(EXPOSURE_SAMPLE_COUNT));
}

// 目标曝光（春雷同款 key value 直除，无曲线）
float targetExposure(float avgLum) {
    return clamp(AUTO_EXPOSURE_KEY_VALUE / avgLum, 1e-7, 1e7);
}

// 时间适应（春雷同款指数平滑，帧率无关）：读 colortex7 角点上一帧曝光向目标推进；
// 曝光域平滑 = 亮度等比变化时按 EV stop 均匀收敛，符合人眼明暗适应；
// prev <= 0（首帧 / 重载后的 clear color）直接取目标
float adaptedExposure(float target) {
    float prev = texelFetch(colortex7, exposureTexel(), 0).r;
    if (prev <= 0.0) return target;
    return mix(prev, target, 1.0 - exp(-frameTime * AUTO_EXPOSURE_RATE));
}

// 读取端（composite_tonemap 应用曝光用）：本帧已适应的曝光系数
float readAdaptedExposure() {
    return texelFetch(colortex7, exposureTexel(), 0).r;
}

#endif
