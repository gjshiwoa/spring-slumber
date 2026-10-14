// deferred3：Voxy 最近半透明层，位于 deferred2 之后、原版 water 之前。
// Voxy 关闭时 properties 禁用本 pass；保留可独立编译的颜色透传路径。
#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/post/exposure.glsl"
#include "/lib/lighting/ambient.glsl"

#ifdef VOXY
#include "/lib/atmosphere/atmosphere.glsl"
#include "/lib/common/pipeline/gbuffer_data.glsl"
#include "/lib/compat/voxy/scene.glsl"
#include "/lib/atmosphere/sky.glsl"
#include "/lib/atmosphere/aerial.glsl"
#include "/lib/atmosphere/fog.glsl"
#include "/lib/water/waves.glsl"
#include "/lib/water/fog.glsl"
#include "/lib/water/ssr.glsl"
#include "/lib/water/reflection.glsl"
#include "/lib/water/surface.glsl"
#include "/lib/compat/voxy/translucent.glsl"
#endif
#include "/program/fullscreen_vsh.glsl"

#ifdef STAGE_FRAGMENT
#ifdef VOXY
/* DRAWBUFFERS:64 */
#else
/* DRAWBUFFERS:6 */
#endif
layout(location = 0) out vec4 outColor;
#ifdef VOXY
layout(location = 1) out vec4 outSnapshot;
in vec2 vJitter;
in vec3 vSunDirection;
in vec3 vMoonDirection;
in vec3 vLightDirection;
in vec3 vDirectIrradiance;
in vec3 vSkyAmbient;
in vec3 vHorizon;
in float vExposure;
flat in float vSkyLutValid;
#endif

void main() {
    ivec2 pixel = ivec2(gl_FragCoord.xy);
#ifdef VOXY
    vec3 color = compositeVoxyTranslucent(texelFetch(colortex6, pixel, 0).rgb,
        gl_FragCoord.xy, vJitter, vSunDirection, vMoonDirection, vLightDirection,
        vHorizon, vSkyLutValid, vDirectIrradiance, vSkyAmbient,
        WATER_BG_SNAPSHOT_HEADROOM / max(vExposure, 1e-5));
    outColor = vec4(color, 1.0);
    outSnapshot = vec4(clamp(color * vExposure / WATER_BG_SNAPSHOT_HEADROOM, 0.0, 1.0), 1.0);
#else
    outColor = texelFetch(colortex6, pixel, 0);
#endif
}
#endif
