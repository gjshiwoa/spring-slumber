// 水焦散图案（写入侧，shadow pass 专用；消费端 = lib/lighting/shadow.glsl 彩色阴影分支的水标记路径）
// 春v2 computeCausticsWithDispersion 纯色移植（色散分支删）：世界坐标经 缩放 → 旋转 → 压扁 → 时间平移
// 后单次采样 noisetex 双通道，(1-g) × mix(r, 1, MOD) 组合、pow 提对比成焦散网——零差分 / 零 fbm，
// 1 fetch / 水面阴影纹素。压扁 = 噪声 y 向频率 ×4、波纹沿旋转后 x 拉长成条带状涟漪（春v2 观感来源）。
// 图案按绝对世界 xz 锚定（相机无关、不随移动游移），y 斜置项（CAUSTICS_TILT）让不同高度的流动
// 水面错开采样平面——跌水 / 阶梯水免竖直条纹。雨天网抹平（×(1-0.9·rain)）。
// 存储协议见 constants.glsl 水焦散分区：返回值不含 tint，调用方（program/shadow.glsl）乘生物群系
// 水色 vColor.rgb 后整包 ≤1 写入 rgba8 的 shadowcolor0，HDR 焦点在读取端重建。
// 仅片段阶段（noisetex 纹理采样不可入 vsh）；依赖由接入方先行 include：
//   constants.glsl（WATER_CAUSTICS / CAUSTICS_*）+ uniforms.glsl（noisetex / frameTimeCounter / rainStrength）
#ifdef STAGE_FRAGMENT

// 焦散透射强度 [CAUSTICS_BASE, 1]（纯色标量，调用方乘 tint）
float waterCaustics(vec3 worldPos) {
    vec2 p = worldPos.xz - worldPos.y * CAUSTICS_TILT;
    p *= CAUSTICS_SCALE;                    // 缩放：世界块 → noisetex uv（texel ≈ 0.26 块，春v2 密度折算）
    p = CAUSTICS_ROT * p;                   // 旋转：波纹不与坐标轴对齐（春v2 -0.45 rad 同值）
    p.y *= CAUSTICS_SQUASH;                 // 压扁：y 向频率 ×4 → 波纹沿旋转后 x 拉长成条带（春v2 z×4 同值）
    p -= CAUSTICS_DRIFT * frameTimeCounter; // 平移：条带沿法向滚动（-= 与春v2 `sampleUV -=` 同号、世界系流向一致）

    // 双通道组合（春v2 evalCaustRemapped 同式）：主通道取反挑波谷、次通道轻度调制，pow 收网
    vec2 n = textureLod(noisetex, p, 0.0).xy;
    float web = (1.0 - n.y) * mix(n.x, 1.0, CAUSTICS_MOD);
    web = pow(web, CAUSTICS_POWER);
    // 雨天水面糙化 → 焦散网抹平（网谷即 CAUSTICS_BASE 背景不受影响，晴天 / 雨天过渡无缝）
    web *= 1.0 - 0.9 * rainStrength;

    return CAUSTICS_BASE + (1.0 - CAUSTICS_BASE) * web;
}

#endif
