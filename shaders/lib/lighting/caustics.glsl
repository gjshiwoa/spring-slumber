// 水焦散图案（写入侧，shadow pass 专用；消费端 = lib/lighting/shadow.glsl 彩色阴影分支的水标记路径）
// 春v2 computeCausticsWithDispersion 纯色移植（色散分支删）：世界坐标经 缩放 → 旋转 → 压扁 → 时间平移
// 后采样噪声双通道，(1-g) × mix(r, 1, MOD) 组合、pow 提对比成焦散网——零差分 / 零 fbm。压扁 = 噪声
// y 向频率 ×4、波纹沿旋转后 x 拉长成条带状涟漪（春v2 观感来源）。
// **三维噪声（2026-10）**：采样自 SEUS 3D-from-2D 值噪声（与水波高度场 lib/water/waves.glsl 的
// waterNoiseTexel / waterNoise3D 同构造——lib 不嵌套、就地镜像成对维护），z 维 = 时间演化
//（CAUSTICS_EVOLVE 格/秒）。原 2D 单 fetch 的图案只沿压扁轴刚性平移（平移感重），3D 化后平移的
// 同时图案形态沿 z 连续换形（z 走 1 格 = 换一副不相关的网）。双通道 = 同一构造两次求值（次通道
// 固定 texel 偏移取独立随机场）、层间插值各 2 fetch，计 4 fetch / 水面阴影纹素（原 1）。
// 图案按绝对世界 xz 锚定（相机无关、不随移动游移），y 斜置项（CAUSTICS_TILT）让不同高度的流动
// 水面错开采样平面——跌水 / 阶梯水免竖直条纹。雨天网抹平（×(1-0.9·rain)）。
// 存储协议见 constants.glsl 水焦散分区：返回值不含 tint，调用方（program/shadow.glsl）乘生物群系
// 水色 vColor.rgb 后整包 ≤1 写入 rgba8 的 shadowcolor0，HDR 焦点在读取端重建。
// 仅片段阶段（noisetex 纹理采样不可入 vsh）；依赖由接入方先行 include：
//   constants.glsl（WATER_CAUSTICS / CAUSTICS_* / noiseTextureResolution）+ uniforms.glsl
//  （noisetex / frameTimeCounter / rainStrength）
#ifdef STAGE_FRAGMENT

// noisetex 纹素采样（iq Better Filtering——MIT，Copyright (c) 2013 Inigo Quilez，许可全文见
// lib/common/utils/filters.glsl 头部；lib/water/waves.glsl waterNoiseTexel 的就地镜像）：uv 归一化域入参，
// smoothstep 加权双线性——值噪声的胞间插值平滑（纹理原生 bilinear 的三角权重会有菱形取向纹）
float causticsNoiseTexel(vec2 uv) {
    vec2 t = uv * float(noiseTextureResolution) + 0.5;
    vec2 i = floor(t);
    vec2 f = t - i;
    f = f * f * (3.0 - 2.0 * f);
    return textureLod(noisetex, (i + f - 0.5) / float(noiseTextureResolution), 0.0).x;
}

// 3D 值噪声从 2D 纹理采样（SEUS 构造，lib/water/waves.glsl waterNoise3D 同款）双通道版：z 以 17 texel 偏移
// 切层、层间线性插值；次通道固定 texel 偏移取独立随机场（同一纹理无第四通道可读）。入参 p 为
// lattice 格单位（1 格 = 1 texel）；REPEAT 寻址消化任意坐标域（uv 亦随 float 精度在 ~1e4+ 世界
// 坐标衰减，BSL / 波形侧同款行为）
vec2 causticsNoise3D(vec3 p) {
    vec3 shifted = p + vec3(0.5);
    vec3 voxel = floor(shifted);
    vec3 f = shifted - voxel;
    vec2 uvLower = voxel.xy + voxel.z * vec2(17.0) + f.xy;
    vec2 uvUpper = uvLower + vec2(17.0);
    vec2 uvLowerB = uvLower + vec2(97.0, 57.0);
    vec2 uvUpperB = uvLowerB + vec2(17.0);
    float loA = causticsNoiseTexel((uvLower  + vec2(0.5)) / float(noiseTextureResolution));
    float hiA = causticsNoiseTexel((uvUpper  + vec2(0.5)) / float(noiseTextureResolution));
    float loB = causticsNoiseTexel((uvLowerB + vec2(0.5)) / float(noiseTextureResolution));
    float hiB = causticsNoiseTexel((uvUpperB + vec2(0.5)) / float(noiseTextureResolution));
    return vec2(mix(loA, hiA, f.z), mix(loB, hiB, f.z));
}

// 焦散透射强度 [CAUSTICS_BASE, 1]（纯色标量，调用方乘 tint）
float waterCaustics(vec3 worldPos) {
    vec2 p = worldPos.xz - worldPos.y * CAUSTICS_TILT;
    p *= CAUSTICS_SCALE;                    // 缩放：世界块 → noisetex uv（texel ≈ 0.65 块，春v2 密度折算）
    p = CAUSTICS_ROT * p;                   // 旋转：波纹不与坐标轴对齐（春v2 -0.45 rad 同值）
    p.y *= CAUSTICS_SQUASH;                 // 压扁：y 向频率 ×4 → 波纹沿旋转后 x 拉长成条带（春v2 z×4 同值）
    p -= CAUSTICS_DRIFT * frameTimeCounter; // 平移：条带沿法向滚动（-= 与春v2 `sampleUV -=` 同号、世界系流向一致）

    // 双通道 3D 噪声：uv 域 → lattice 格域（×分辨率，胞尺寸与旧 2D 直采逐位同密度）；z = 时间演化，
    // 平移的同时图案形态连续换形（见文件头）
    vec2 n = causticsNoise3D(vec3(p * float(noiseTextureResolution), frameTimeCounter * CAUSTICS_EVOLVE));
    float web = (1.0 - n.y) * mix(n.x, 1.0, CAUSTICS_MOD);
    web = pow(web, CAUSTICS_POWER);
    // 雨天水面糙化 → 焦散网抹平（网谷即 CAUSTICS_BASE 背景不受影响，晴天 / 雨天过渡无缝）
    web *= 1.0 - 0.9 * rainStrength;

    return CAUSTICS_BASE + (1.0 - CAUSTICS_BASE) * web;
}

#endif
