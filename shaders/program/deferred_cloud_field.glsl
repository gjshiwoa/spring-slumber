// 云形状场生成 pass: deferred_cloud_field（deferred 槽，world0/deferred 入口）
// 在不透明 gbuffers 之后、deferred1（deferred_init，场的消费者）之前，把 2D 云的低频形状场写进
// colortex1 图集右侧槽位（布局矩形 bloom.glsl 的 cloudFieldRect，128×128 texel、窗口跟相机、
// 世界锚定）——deferred1 的伪自阴影探针经 sampleCloudField 同帧 bilinear 消费，零滞后。
// 时序自洽性：引擎对颜色缓冲的 clear 发生在 gbuffers 之后、deferred 链之前——场的写入在 clear
// 后、消费在下一 clear 前，colortex1Clear 无需置 false；bloom 链（composite4~12）只写图集区域、
// 与场槽位互斥（cloudFieldRect 结构性保证）。
// 生成成本 128² × 9 hash ≈ 0.15M/帧，换 deferred1 云像素探针 9 hash 内联求值 → 2 次 bilinear
// fetch（机制与 Nyquist / 窗口论证见 clouds.glsl 的 cloudFieldShape / sampleCloudField）。
// quad 压缩到槽位矩形（绝对 texel 域——不走 FULLSCREEN_RENDER_REGION / TAAU 子区域缩放，场
// 槽位与渲染比例无关）；fsh 全部经 gl_FragCoord 取纹素、无 varying。CLOUDS_2D 关闭时 vsh 移出
// 裁剪空间 + fsh discard（该槽位无其他职责）。fsh 前半 / vsh 后半

#include "/lib/common/globals/constants.glsl"
#include "/lib/common/globals/uniforms.glsl"
#include "/lib/common/utils/filters.glsl"
#include "/lib/common/utils/space.glsl"
#include "/lib/post/bloom.glsl"
#include "/lib/common/utils/noise.glsl"
#include "/lib/atmosphere/clouds.glsl"

// ================================ FRAGMENT ================================
#ifdef STAGE_FRAGMENT

/* DRAWBUFFERS:1 */

layout(location = 0) out vec4 outColor;

void main() {
#ifdef CLOUDS_2D
    ivec2 pixel = ivec2(gl_FragCoord.xy);
    vec4 rect = cloudFieldRect();
    if (all(greaterThanEqual(vec2(pixel), rect.xy))
     && all(lessThan(vec2(pixel), rect.xy + rect.zw))) {
        // texel 中心对应的世界 xz（窗口跟相机锚定）→ 角域 → 低频形状，r 通道 [0,1]；矩形边缘
        // 半 texel 容差带（驱动光栅化差异）落在槽位外 gutter、写 0 无读者
        vec2 texelLocal = (vec2(pixel) - rect.xy + 0.5) / rect.zw;
        vec2 worldXz = cameraPosition.xz + (texelLocal - 0.5) * CLOUDS_2D_FIELD_WORLD;
        outColor = vec4(cloudFieldShape(worldXz / (EARTH_RADIUS + CLOUDS_2D_HEIGHT)), 0.0, 0.0, 1.0);
    } else {
        outColor = vec4(0.0);
    }
#else
    discard;
#endif
}

#endif

// ================================= VERTEX =================================
#ifdef STAGE_VERTEX

void main() {
    vec4 pos = ftransform();
#ifdef CLOUDS_2D
    // 全屏 quad 压缩到场槽位矩形：quadUv [0,1]² → [rectMin, rectMax] uv（缓冲归一化）
    vec2 quadUv = pos.xy / pos.w * 0.5 + 0.5;
    vec2 bufSize = vec2(textureSize(colortex1, 0));
    vec4 rect = cloudFieldRect();
    vec2 rectMinUv = rect.xy / bufSize;
    vec2 rectMaxUv = (rect.xy + rect.zw) / bufSize;
    vec2 rectUv = mix(rectMinUv, rectMaxUv, quadUv);
    pos.xy = (rectUv * 2.0 - 1.0) * pos.w;
    gl_Position = pos;
#else
    gl_Position = vec4(2.0, 2.0, 2.0, 1.0); // 移出裁剪空间，光栅化前整体裁掉
#endif
}

#endif
