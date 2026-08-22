// 阴影贴图写入 pass: shadow（shadow 阶段）
// 引擎在本阶段把场景渲染进 shadowtex0（全几何深度）/ shadowtex1（仅不透明深度，两张由引擎自动分工），
// 本程序额外写 shadowcolor0 = albedo（彩色阴影透射色）；blend.shadow = off（整像素写入，见 shaders.properties）
// 顶点：ftransform 后线性扭曲 xy + 压缩 z——与读取端 lib/lighting/shadow.glsl 的
// relativeWorldToShadowScreen 逐字符对称；不注入 TAA jitter（阴影贴图按世界位置采样，抖动会错位）
// fsh 手动 alpha test（ALPHA_CUTOUT）实现 cutout 透贴（树影镂空），深度随 discard 一并丢弃；
// 无 waving（gbuffers 亦无摆动，两边几何一致才不闪烁）；水不特判（半透明进 tex0，彩色阴影给水下带色光照）
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/color.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/lighting/shadow.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:0 */

layout(location = 0) out vec4 outColor; // shadowcolor0：透射色（sRGB albedo，读取端 srgbToLinear）

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;
    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴（树叶等）

    outColor = vec4(color.rgb, 1.0);
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = ftransform();
    gl_Position.xy = shadowDistort(gl_Position.xy); // 正交投影 w = 1，clip 与 NDC 同值
    gl_Position.z *= SHADOW_DEPTH_SCALE;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
}

#endif
