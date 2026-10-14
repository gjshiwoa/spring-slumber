// Voxy 最近半透明层：位置 / 遮挡检查、水面框架接入与玻璃 alpha 合成。
// 依赖（program 平铺引入）：constants / uniforms / packing / color / space / noise /
// gbuffer_data / compat/voxy/scene / lighting/ambient / water/surface（及其依赖）。
// 输出最终线性颜色；colortex6 与背景快照的写入由 deferred pass 负责。
#ifndef LIB_COMPAT_VOXY_TRANSLUCENT_GLSL
#define LIB_COMPAT_VOXY_TRANSLUCENT_GLSL
#if defined(VOXY) && defined(STAGE_FRAGMENT)
vec3 compositeVoxyTranslucent(vec3 color, vec2 bufferPx, vec2 jitterUv,
                             vec3 sunDirection, vec3 moonDirection, vec3 lightDirection,
                             vec3 horizon, float skyLutValid, vec3 directIrradiance,
                             vec3 skyAmbient, float snapshotDecodeScale) {
    ivec2 pixel = ivec2(bufferPx);
    vec4 detail = texelFetch(colortex17, pixel, 0);
    // 清屏 / 无效深度先退；玻璃只解包颜色与 lightmap，不付水面法线成本。
    if (detail.b == 0.0) return color;
    vec3 viewPos;
    if (!voxyDepthViewPosition(vxDepthTexTrans, bufferPx, jitterUv, viewPos)) return color;

    float bgDepth = texelFetch(depthtex1, pixel, 0).r;
    // 原版天空没有待比较的位置；LOD 远景常在此分支，省去无消费者的远平面重建。
    // 无几何时 scene 保留占位值，但下方只在 bgValid 时读取它。
    vec3 bgViewPos = vec3(0.0);
    if (bgDepth < 1.0) {
        vec2 uv = applyInverseJitter(bufferPx / vec2(viewWidth, viewHeight), jitterUv);
        bgViewPos = screenToViewCanonical(uv, bgDepth);
    }
    bool bgValid = voxyOpaqueBackgroundPosition(bufferPx, jitterUv, bgDepth, bgViewPos);
    if (bgValid && -viewPos.z > -bgViewPos.z + 0.01) return color;

    vec4 texcolor = texelFetch(colortex16, pixel, 0);
    vec2 lm = remapLightmap(unpack16To2x8((abs(detail.b) - 1.0) / 65535.0));
    if (detail.b < 0.0) {
        vec3 normalW = normalize(mat3(vxModelViewInv) * decodeOctahedral(detail.rg));
        float footprint = max(-viewPos.z, 1.0) * 2.0 /
            max(abs(gbufferProjection[1][1]) * viewHeight, 1.0);
#if defined(EFFECTIVE_RENDER_SCALE)
        footprint /= renderRegionScale().y;
#endif
        color = shadeWaterSurface(viewPos, texcolor.rgb, lm, sunDirection, moonDirection,
            lightDirection, horizon, skyLutValid, directIrradiance, skyAmbient,
            snapshotDecodeScale, jitterUv, normalW, footprint);
    } else {
        vec3 lit = forwardLightmapShade(srgbToLinear(texcolor.rgb), lm, skyAmbient);
        color = mix(color, lit, texcolor.a);
    }
    return color;
}
#endif
#endif
