#include "/lib/common/globals/constants.glsl"
#ifdef SR_UPSCALE
vec2 jitter = voxyTaaJitter;
#else
vec2 jitter = TAA_JITTER_SAMPLES[frameCounter & 7] * TAA_JITTER_SCALE;
#endif
#if defined(SR_UPSCALE)
// Match Voxy setupViewport's float multiply followed by integer truncation.
return 2.0 * jitter / max(floor(vec2(viewWidth, viewHeight) * EFFECTIVE_RENDER_SCALE), vec2(1.0));
#elif defined(EFFECTIVE_RENDER_SCALE)
return 2.0 * jitter / (vec2(viewWidth, viewHeight) * EFFECTIVE_RENDER_SCALE);
#else
return 2.0 * jitter / vec2(viewWidth, viewHeight);
#endif
