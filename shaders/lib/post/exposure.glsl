// 自动曝光工具库：亮度算法参考春雷（tile4 对数平均 + 0.18 key 直除 + 地板 + 曝光域指数适应），
// pass 设计参考春v2（寄生 bloom 链测光、单像素存储、写入区域透传保值，无 flip.* 依赖）
// 依赖先行 include：constants.glsl（AUTO_EXPOSURE_*）、uniforms.glsl（colortex1 / colortex7 /
// frameTime）、lib/post/bloom.glsl（bloomTileRect / BLOOM_TILE_COUNT）、utils/color.glsl（rgbToLuma）
#ifndef LIB_EXPOSURE_GLSL
#define LIB_EXPOSURE_GLSL

// colortex7 曝光槽位（杂项簇第一个槽）：天空盒与天空 LUT 的 4 texel 间隔 gutter 内、缓冲底边
//（固定 texel (258, 0)，与两区域任何分辨率下不相交——原「图集 tile 间隔」方案位置随分辨率浮动、
// 常见分辨率下会落进 LUT 区域故迁址）；槽位常量 EXPOSURE_TEXEL 在 constants.glsl（water vsh 快照
// 解码不经本文件直读槽位、须共享位置），写入端 composite12 与全部读取端经本函数取值、位置恒一致
ivec2 exposureTexel() {
    return EXPOSURE_TEXEL;
}

// 场景平均亮度（对数平均，春雷同款）：bloom 最粗 tile4（1/64 分辨率低频）上固定 16 点抖动网格核
// 采样（tile4 每纹素已聚合 ~64² 屏幕像素、内容极低频，16 点估计充分；测光成本与分辨率解耦、
// 固定核帧间稳定）；对数域平均抑制高光算术级主导；测量语义 = 未乘曝光、未加 bloom 的线性场景
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

// 目标曝光（春雷 key value 直除 + 基础亮度地板）：avgLum 先抬到 AUTO_EXPOSURE_BASE_LUMINANCE
// 再直除——纯黑 / 深夜场景的对数平均远低于地板，曝光封顶在 KEY / BASE，夜晚 / 暗室不再被
// 放大成白天；亮场景 avgLum >> 地板，直除行为不变
float targetExposure(float avgLum) {
    return clamp(AUTO_EXPOSURE_KEY_VALUE / max(avgLum, AUTO_EXPOSURE_BASE_LUMINANCE), 1e-7, 1e7);
}

// 时间适应（春雷同款指数平滑、帧率无关）：曝光域平滑 = 亮度等比变化时按 EV stop 均匀收敛，
// 符合人眼明暗适应；prev <= 0（首帧 / clear color）直接取目标
float adaptedExposure(float target) {
    float prev = texelFetch(colortex7, exposureTexel(), 0).r;
    if (prev <= 0.0) return target;
    return mix(prev, target, 1.0 - exp(-frameTime * AUTO_EXPOSURE_RATE));
}

// 读取端（composite_taa 钳制域归一化乘上一帧值 / final 应用本帧值）：已适应的曝光系数
float readAdaptedExposure() {
    return texelFetch(colortex7, exposureTexel(), 0).r;
}

#endif
