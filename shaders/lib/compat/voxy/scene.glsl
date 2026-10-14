// Voxy 深度纹理 -> 原版观察空间：坐标适配与最近可见层选择。
// depthtex 只含原版几何；LOD 只由 vxDepthTexOpaque/Trans + vxProjInv/vxModelViewInv 重建。
// Dependencies (flat includes): constants, uniforms, utils/noise, utils/space.
#ifndef LIB_COMPAT_VOXY_SCENE_GLSL
#define LIB_COMPAT_VOXY_SCENE_GLSL
#if defined(VOXY) && defined(STAGE_FRAGMENT)
bool voxyDepthViewPosition(sampler2D tex, vec2 bufferPx, vec2 jitterUv, out vec3 viewPos) {
    vec2 bufferSize = renderRegionSize();
    ivec2 size = textureSize(tex, 0);
#ifdef SR_UPSCALE
    // Voxy 与 SR 同按 floor(viewSize * 名义比例) 建视口，整数像素直接对应。
    // 其他路径保留比例映射（TAAU 的子区域允许非整数边界）。
    ivec2 pixel = clamp(ivec2(bufferPx), ivec2(0), size - 1);
#else
    ivec2 pixel = clamp(ivec2(bufferPx / bufferSize * vec2(size)), ivec2(0), size - 1);
#endif
    float depth = texelFetch(tex, pixel, 0).r;
    viewPos = vec3(0.0);
    if (depth <= 0.0 || depth >= 1.0) return false;
#ifdef SR_UPSCALE
    // 深度纹素中心直接去抖：jitterUv 来自完整 buffer 像素域；避免先缩放再除回的舍入。
    vec2 fullUv = (vec2(pixel) + 0.5 - jitterUv * vec2(viewWidth, viewHeight)) / vec2(size);
#else
    vec2 lodBufferUv = (vec2(pixel) + 0.5) / vec2(size);
#if defined(EFFECTIVE_RENDER_SCALE)
    lodBufferUv *= renderRegionScale();
#endif
    vec2 fullUv = applyInverseJitter(lodBufferUv, jitterUv);
#endif
    vec4 lodView = vxProjInv * vec4(fullUv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
    if (abs(lodView.w) < 1e-10) return false;
    // 显式逐向量变换，避免先构造两个 uniform 的 mat4 乘积。
    vec4 nativeView = gbufferModelView * (vxModelViewInv * vec4(lodView.xyz / lodView.w, 1.0));
    viewPos = nativeView.xyz;
    return viewPos.z < 0.0;
}

// 两类深度各自重建后在同一观察空间比较，原版手部优先。
// viewPos 由调用方用原版深度初始化；无几何时保留原版远平面视线供天空消费。
bool voxyScenePosition(vec2 bufferPx, vec2 jitterUv, float nativeDepth, bool includeTrans,
                       inout vec3 viewPos, out bool lodSurface) {
    bool valid = nativeDepth < 1.0;
    lodSurface = false;
    if (valid && nativeDepth < TAA_HAND_DEPTH) return true;
    vec3 lodPos;
    if (voxyDepthViewPosition(vxDepthTexOpaque, bufferPx, jitterUv, lodPos)
        && (!valid || lodPos.z > viewPos.z)) {
        viewPos = lodPos;
        valid = true;
        lodSurface = true;
    }
    if (includeTrans && voxyDepthViewPosition(vxDepthTexTrans, bufferPx, jitterUv, lodPos)
        && (!valid || lodPos.z > viewPos.z)) {
        viewPos = lodPos;
        valid = true;
        lodSurface = true;
    }
    return valid;
}

bool voxyOpaqueBackgroundPosition(vec2 bufferPx, vec2 jitterUv, float nativeDepth, inout vec3 viewPos) {
    bool lodSurface;
    return voxyScenePosition(bufferPx, jitterUv, nativeDepth, false, viewPos, lodSurface);
}

void voxyVisibleSurfacePosition(vec2 bufferPx, vec2 jitterUv, float nativeDepth,
                                inout vec3 viewPos, inout bool skyPixel) {
    bool lodSurface;
    skyPixel = !voxyScenePosition(bufferPx, jitterUv, nativeDepth, true, viewPos, lodSurface);
}

#if defined(SR_UPSCALE)
// 仅供 SR 外部深度接口：由已重建位置导出原版投影域标量，不回写 depthtex。
// 内部光照 / 雾 / SSR / TAA 始终直接消费原始 LOD 位置。
float voxyWindowDepth(vec3 viewPos) {
    vec4 clip = gbufferProjection * vec4(viewPos, 1.0);
    return clip.z / clip.w * 0.5 + 0.5;
}

vec2 voxySceneMotionVector(vec2 uv, vec3 viewPos) {
    vec4 prevClip = gbufferPreviousProjection * gbufferPreviousModelView * vec4(
        viewToRelativeWorld(viewPos) + cameraPosition - previousCameraPosition, 1.0);
    return prevClip.w > 1e-5 ? prevClip.xy / prevClip.w * 0.5 + 0.5 - uv : vec2(0.0);
}
#endif
#endif
#endif
