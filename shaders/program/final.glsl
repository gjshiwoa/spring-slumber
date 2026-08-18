// 最终合成: final
// 骨架阶段直通输出 colortex0；曝光 / tonemap / gamma 在接入光照时启用
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/constants.glsl"
#include "/lib/common.glsl"
#include "/lib/uniforms.glsl"

VARYING vec2 vTexCoord;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

// 缓冲格式常量集中在 lib/constants.glsl（program 平铺 include，OptiFine/Iris 扫描展开后内容）
layout(location = 0) out vec4 outColor;

void main() {
    outColor = vec4(texture(colortex0, vTexCoord).rgb, 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    vTexCoord = gl_MultiTexCoord0.xy;
}

#endif
