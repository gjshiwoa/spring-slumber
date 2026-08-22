// 信标光柱 gbuffer: gbuffers_beacon（beaconbeam 入口）
// 参考 春雷 passes/06_gbuffers/beaconbeam.glsl：光柱在 deferred 之前绘制、
// 含不透明核心与半透明外壳两部分，按 alpha 分支处理（两分支都不吃引擎混合）：
//   不透明核心（a >= ALPHA_BEACON_CORE）：整像素写 gbuffer，自发光
//     （specular.a = BEACON_CORE_EMISSIVE，其余 specular 为 0）、无光照图（lm = 0）、
//     导数几何法线，随后随不透明几何一起经过 deferred_init
//   半透明外壳（a < ALPHA_BEACON_CORE）：春雷式手动合成，mix 进 colortex4.rg 打包颜色，
//     背景 specular（colortex4.ba）与法线 / lm（colortex5）texelFetch 读回原样写回
// fsh 前半 / vsh 后半，入口文件用 STAGE_FRAGMENT / STAGE_VERTEX 选择编译哪一半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/pipeline/varying_io.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/common/utils/packing.glsl"
#include "/lib/common/utils/jitter.glsl"

VARYING vec2 vTexCoord;
VARYING vec4 vColor;
VARYING vec3 vViewPos;

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:45 */

layout(location = 0) out vec4 outMaterial; // colortex4
layout(location = 1) out vec4 outDetail;  // colortex5

void main() {
    vec4 color = texture(tex, vTexCoord) * vColor;

    // 位置屏幕导数先于 discard 求好（同 gbuffers_opaque 的顺序约束：quad 内被提前终止的
    // 透明 texel 会使幸存像素的 dFdx/dFdy 拿到未定义值）；cross / normalize 推迟到核心分支，
    // 外壳分支不做这部分工作
    vec3 dp1 = dFdx(vViewPos);
    vec3 dp2 = dFdy(vViewPos);

    if (color.a < ALPHA_CUTOUT) discard; // cutout 透贴

    vec4 previousMaterial = texelFetch(colortex4, ivec2(gl_FragCoord.xy), 0);

    if (color.a < ALPHA_BEACON_CORE) {
        // 半透明外壳：手动合成进打包 albedo，背景 specular / 法线 / lm 原样写回
        vec3 previousColor = unpack2x16To4x8(previousMaterial.rg).rgb;
        color.rgb = mix(previousColor, color.rgb, color.a);
        outMaterial = vec4(pack4x8To2x16(vec4(color.rgb, 1.0)), previousMaterial.ba);
        outDetail = texelFetch(colortex5, ivec2(gl_FragCoord.xy), 0);
    } else {
        // 不透明核心：自发光整像素写 gbuffer
        vec3 viewNormal = geomNormalFromDerivatives(dp1, dp2);
        vec4 specularMap = vec4(0.0, 0.0, 0.0, BEACON_CORE_EMISSIVE);
        outMaterial = vec4(pack4x8To2x16(color), pack4x8To2x16(specularMap));
        outDetail = vec4(encodeOctahedral(viewNormal), vec2(0.0));
    }
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    gl_Position = applyTAAJitter(ftransform()); // TAA 亚像素抖动，composite_taa 统一解析
    vViewPos = (gl_ModelViewMatrix * gl_Vertex).xyz;
    vTexCoord = gl_MultiTexCoord0.xy;
    vColor = gl_Color;
}

#endif
