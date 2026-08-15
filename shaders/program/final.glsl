// 最终合成: final
// 当前为最小实现: 把 gbuffers 写入 colortex0 的最终画面直通输出
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"
#include "/lib/formats.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

// 颜色缓冲格式（由 OptiFine/Iris 在 final 阶段识别）
const int colortex0Format = RGBA16F;
const int colortex4Format = RGBA16;
const int colortex5Format = RGBA16F;

layout(location = 0) out vec4 outColor;

void main() {
    outColor = texture(colortex0, vTexCoord);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
