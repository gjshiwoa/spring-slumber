// 水波高度场与法线（仅片段阶段；2026-10 自 lib/lighting/water.glsl 按功能拆分，git 历史含合并
// 形态）：水面前向框架的波形供给，方案移植自春v2 waterNormal.glsl 的 getwaves1（afl_ext Very fast
// procedural ocean 与 reinder Misty Lake 两 Shadertoy 谱系，与 2D 云同族 noisetex 3D-from-2D 值噪声
// fbm）。上游条款：afl_ext 部分为 MIT（声明原样保留于下）；Misty Lake（CC BY-NC-SA 4.0）仅取其
// 旋转矩阵常量与思路——数值常量与思想不受版权保护，未复制其代码表达。
//
// ---- 上游许可（"Very fast procedural ocean"，随代码发布的 MIT 声明原样保留；依 MIT 条款：
//      版权与许可声明须随副本保留）----
// Copyright (c) 2017-2024 afl_ext
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.**水波法线不走局部 TBN**（春v2 deferred21 路线，按其 getWaveNormalDH / normalFrom3Points）：
// 高度场按绝对世界 xz 求值，法线 = 世界系三点高度差分叉积（p、p+εx、p+εz）——与纹理坐标 / 几何
// 导数无关，折射与反射共用同一世界法线；世界锚定（+cameraPosition）保证水面平移时波形稳定。
// 消费方：lib/water/surface.glsl（shadeWaterSurface——法线在波面重定基后消费，竖直流面反射修复
// 见该文件头注与函数内段注）。
// 性能（按真实纹理 fetch 计——旧头注曾按「3D 采样」折半计 18/30，实际纹理 fetch 为其两倍）：每高度
// 求值 = fbm 双层 ×2 octave × 切层 2 = 8 fetch——法线差分 3 求值 = 24、WAVE_PARALLAX 再 +2 求值 =
// 40（删视差宏回 24）。2026-10-08 恢复粗糙度 mask：全像素共享单次 +2 fetch，
// 开启 WAVE_ROUGHNESS_MASK 后为 26 / 42；关闭即回原采样预算。嫌重砍 pB 层（每求值 −4）。
// 采样基元与焦散侧成对维护（lib 不嵌套、两处就地镜像）：waterNoiseTexel / waterNoise3D ↔
// lib/lighting/caustics.glsl 的 causticsNoiseTexel / causticsNoise3D（2026-10 焦散噪声 3D 化起
// 同构造，constants.glsl 的 CAUSTICS_* 段注同引）。
// 依赖由接入的 program 先行 include（lib 文件不嵌套）：constants.glsl（WAVE_* /
// noiseTextureResolution）、uniforms.glsl（noisetex / frameTimeCounter）、utils/space.glsl
//（remapSaturate，仅 WAVE_ROUGHNESS_MASK 开启时需要）
#ifndef LIB_WATER_WAVES_GLSL
#define LIB_WATER_WAVES_GLSL

#ifdef STAGE_FRAGMENT

// ---------------- 波形高度场（春v2 waterNormal.glsl 移植，type 1「Misty Lake」默认档） ----------------

// noisetex 纹素采样（iq Better Filtering——MIT，Copyright (c) 2013 Inigo Quilez，许可全文见
// lib/common/utils/filters.glsl 头部；春v2 textureN 的标量版）：uv 归一化域入参，smoothstep
// 加权双线性——值噪声的胞间插值平滑（纹理原生 bilinear 的三角权重会有菱形取向纹）
float waterNoiseTexel(vec2 uv) {
    vec2 t = uv * float(noiseTextureResolution) + 0.5;
    vec2 i = floor(t);
    vec2 f = t - i;
    f = f * f * (3.0 - 2.0 * f);
    return textureLod(noisetex, (i + f - 0.5) / float(noiseTextureResolution), 0.0).x;
}

// 3D 值噪声从 2D 纹理采样（SEUS 构造，春v2 noise3DFrom2D 同款）：z 以 17 texel 偏移切层、层间
// 线性插值；REPEAT 寻址 + fract 包装消化任意坐标域（uv 亦随 float 精度在 ~1e4+ 世界坐标衰减，BSL 同款行为）
float waterNoise3D(vec3 p) {
    vec3 shifted = p + vec3(0.5);
    vec3 voxel = floor(shifted);
    vec3 f = shifted - voxel;
    vec2 uvLower = voxel.xy + voxel.z * vec2(17.0) + f.xy;
    vec2 uvUpper = uvLower + vec2(17.0);
    float lo = waterNoiseTexel((uvLower + vec2(0.5)) / float(noiseTextureResolution));
    float hi = waterNoiseTexel((uvUpper + vec2(0.5)) / float(noiseTextureResolution));
    return mix(lo, hi, f.z);
}

// 波形 fbm 骨架旋转（数值常量取自 reinder Misty Lake，春v2 WAVE1_M3 同值——仅取矩阵数值与
// 思路、未复制其代码表达，条款分析见文件头）
const mat3 WAVE1_M3 = mat3( 0.00,  0.80,  0.60,
                           -0.80,  0.36, -0.48,
                           -0.60, -0.48,  0.64 );

// 双 octave fbm（春v2 waterFBM iterations = 10 档：2 次求值 / 0.75 归一）
float waterFbm(vec3 p, float footprint) {
    float f = 0.0;
    f += 0.5000 * waterNoise3D(p);
    p = WAVE1_M3 * p * 2.02;
    // 未解析的高频 octave 收敛到噪声均值，保持平均波高；第一 octave 保留大波形。
    float detailWeight = 1.0 - smoothstep(WAVE_FILTER_LOW, WAVE_FILTER_HIGH, footprint * 2.02);
    f += 0.2500 * mix(0.5, waterNoise3D(p), detailWeight);
    p = WAVE1_M3 * p * 2.03;
    return f / 0.75;
}

// 波形主尺度旋转（春v2 rotate2D(p, θ) = mat2(cosθ, −sinθ, sinθ, cosθ) 的三角值预算折叠，
// CAUSTICS_ROT 同纪律）；θA = −0.75、θB = −0.30
const mat2 WAVE_ROT_A = mat2( 0.7316889,  0.6816388, -0.6816388, 0.7316889);
const mat2 WAVE_ROT_B = mat2( 0.9553365,  0.2955202, -0.2955202, 0.9553365);

#ifdef WAVE_ROUGHNESS_MASK
// 粗糙度 mask（春v2 getwaves1RoughnessMask 同款）：两组慢漂移低频采样调制波形对比——波团有疏密。
// **mask 单次求值共享（2026-10 性能）**：mask 特征尺度 ~56 / ~22 格（0.018 / 0.045 频率），而消费
// 它的高度求值点散布 ≤ ~0.8 格（法线差分 ε = 0.05 ×2 + 视差位移 ≤ 0.75）——逐点求值与共享值之差
// 为波长 1~3% 量级、远低于波场自身平滑度，故由 shadeWaterSurface 在波形采样锚点一次算好传入
//（省每求值 2 fetch：法线 3 求值 + 视差 2 求值合计 50 → 42）；锚点取视差前的去抖 worldPos.xz
//（帧间稳定，mask 不随视差迭代漂移）
float waterWaveRoughnessMask(vec2 pos) {
    float tM = frameTimeCounter * WAVE_SPEED * 0.06;
    vec2 mp0 = pos * 0.018 + vec2(tM, tM * 0.7);
    vec2 mp1 = pos * 0.045 - vec2(tM * 0.5, tM * 0.9) + vec2(53.1, 11.7);
    float m0 = waterNoiseTexel(mp0 / float(noiseTextureResolution));
    float m1 = waterNoiseTexel(mp1 / float(noiseTextureResolution));
    float mask = mix(m0, m1, 0.33);
    return remapSaturate(mask, 0.25, 0.75, 0.33, 1.0);
}

#endif

// 波形高度原始值（春v2 getwaves1 同构）：双旋转拉伸层 mix；
// 粗糙度 mask 在 surface.glsl 单次求值并乘入 amplitude，全部高度采样共享。高度域 ~[0,1]。
float waterWaveHeightRaw(vec2 pos, float footprint) {
    float t = frameTimeCounter * WAVE_SPEED * 3.0;

    vec2 pA = WAVE_ROT_A * (pos * 0.35);
    pA.y *= 4.0;
    float tA = t * 0.3;
    pA -= vec2(0.0, tA);
    float hA = waterFbm(vec3(pA, tA * 0.5), footprint * 1.4);

    vec2 pB = WAVE_ROT_B * (pos * 0.4);
    pB.y *= 4.0;
    float tB = t * 0.35;
    pB -= vec2(0.0, tB);
    float hB = waterFbm(vec3(pB, tB * 0.5), footprint * 1.6);

    return mix(hA, hB, 0.33);
}

// 波形高度（世界锚定入口）：频率缩放 + 波幅混入系数 amplitude 由调用方传入——春v2 type1 以
// pow(WAVE_HEIGHT, 1.35) 混入（WAVE_HEIGHT 即法线坡度的实际旋钮），本包再乘掠视角衰减
//（|dot(视线, 水面几何法线)| 线性，surface.glsl 内算好传入；取代曾有的 WAVE_FADE_* 距离淡出
//——2026-10 嫌远水太平移除，git 历史含完整形态，两代衰减均经本系数施加、字段自身不做距离 /
// 视角淡出）。amplitude → 0 时高度恒 1（平水基准）——法线差分恒 up、视差
// g0 = 0，整支波形消费随系数一致收敛、无残留路径
float waterWaveHeightFiltered(vec2 worldXz, float amplitude, float footprint) {
    float waveHeight = waterWaveHeightRaw(worldXz * WAVE_FREQUENCY, footprint * WAVE_FREQUENCY);
    return clamp(mix(1.0, waveHeight, amplitude), 0.0, 1.0);
}

// **水波法线（春v2 deferred21 的 getWaveNormalDH / normalFrom3Points 路线）**：世界系三点高度
// 差分——cross(tZ, tX) 的 y 分量 = ε² > 0 恒朝上，守卫翻转只防退化；不用 TBN / 几何导数，
// 折射与反射共用同一世界法线。ε 以 WAVE_NORMAL_EPS 为下限，按像素足迹增大且封顶；amplitude 由
// 调用方传入（waterWaveHeightFiltered 段注）
float waterWaveHeight(vec2 worldXz, float amplitude) {
    return waterWaveHeightFiltered(worldXz, amplitude, 0.0);
}

vec3 waterWaveNormalW(vec2 worldXz, float amplitude, float footprint) {
    // 足迹由入口先于 discard 求导传入；按像素而非世界距离过滤，保留低频波形。
    float normalStep = clamp(footprint * WAVE_FILTER_NORMAL_SCALE, WAVE_NORMAL_EPS, WAVE_FILTER_NORMAL_MAX);
    float hC = waterWaveHeightFiltered(worldXz, amplitude, footprint);
    float hX = waterWaveHeightFiltered(worldXz + vec2(normalStep, 0.0), amplitude, footprint);
    float hZ = waterWaveHeightFiltered(worldXz + vec2(0.0, normalStep), amplitude, footprint);
    vec3 n = normalize(cross(vec3(0.0, hZ - hC, normalStep),
                             vec3(normalStep, hX - hC, 0.0)));
    return n.y < 0.0 ? -n : n;
}

#endif

#endif
