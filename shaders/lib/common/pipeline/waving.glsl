// 植物晃动（顶点位移，方案移植自春v2 lib/wavingPlants.glsl；其头注归属：搜狐畅游引擎部
// 「渲染TA实战：模型草美术效果分享」https://zhuanlan.zhihu.com/p/609035535）
// 分族复用 block.properties 五族（与 material.glsl 的 isVegetationId 同一列表、ID 成对维护）：
//   31 矮草 / 花 / 苗——仅上顶点（uv.t < 纹理中点，根部钉地）、仅水平；
//   10175 / 11175 双高植物下 / 上半——下半仅上顶点、上半全顶点，仅水平；
//   18 树叶 / 藤蔓——全顶点、含竖直分量；10176 其他植物不晃（只吃 SSS）
// 绝对世界坐标锚定：gbuffers_opaque（terrain）与 shadow 两侧同一函数、同一输入（世界坐标 / 时间 / 雨），
// 偏移逐位一致 → 贴图阴影与几何同步晃；距离门按「距玩家世界距离」（cameraPosition 在 shadow pass 亦为
// 玩家位置）同样两侧一致。顶点阶段意图（texture / textureSize 于 vsh 调用）。
// 依赖先行 include：lib/common/globals/constants.glsl（WAVING_* / WAVING_GUST_ROT / TAU）、
//   lib/common/globals/uniforms.glsl（noisetex / frameTimeCounter / rainStrength / cameraPosition）、
//   lib/common/utils/space.glsl（remapSaturate），由接入方平铺引入
#ifndef LIB_WAVING_GLSL
#define LIB_WAVING_GLSL

#ifdef STAGE_VERTEX

// 分族参数 →（幅度倍率, 竖直权重）；(0, ·) = 不晃。blockId 数值与 block.properties /
// isVegetationId 的 case 字面量成对维护；texCoordT / midTexCoordT 取原始属性 gl_MultiTexCoord0.t /
// mc_midTexCoord.t（不经 gl_TextureMatrix——属性域直接比较）——原版交叉面片 quad 的上半顶点 v 坐标
// 小于纹理中点，由此实现「上顶点晃、根部顶点不动」；block / hand 入口两属性未绑定（mc_Entity 恒 0
// 不命中族、midTexCoord 取 0 判定恒假），天然不晃
vec2 plantWavingParams(float blockId, float texCoordT, float midTexCoordT) {
    bool upperVertex = texCoordT < midTexCoordT;
    if (blockId == 31.0)    return upperVertex ? vec2(WAVING_SHORT_AMPLITUDE, 0.0) : vec2(0.0);
    if (blockId == 10175.0) return upperVertex ? vec2(WAVING_TALL_AMPLITUDE, 0.0) : vec2(0.0);
    if (blockId == 11175.0) return vec2(WAVING_TALL_AMPLITUDE, 0.0);
    if (blockId == 18.0)    return vec2(WAVING_LEAVES_AMPLITUDE, 1.0);
    return vec2(0.0);
}

// 风场偏移（世界系，格单位）：慢摆（低频 0.33 Hz、基幅 0.01 格，noisetex 低频相位扰动——逐草相位差）
// + 快摆（1 Hz、基幅 0.05 格）× 阵风带调制（xz 旋转 0.45 rad、x ×3 拉伸成带状、随时间 WAVING_GUST_SPEED 平移的
// 噪声 mask——晴天阈值 0.33 起风、雨天抬底 0.2·rain 整体更晃更连续）；三分量（rgb）各持独立相位，
// 水平轨迹不成直线。采样坐标公共 rcp 外提（低配 GPU 除法吞吐约 mul 的 1/4——三个坐标 6 div → 1 rcp +
// 乘法）；阵风 mask 用普通双线性（纹素 ~21-64 格、梯度极缓，smoothstep 加权不可分辨——曾用 textureNice
// 替代春v2 textureBicubic、该频段下降级省权重 ALU）；noisetex 分辨率 textureSize 运行读取（不假设默认档）
vec3 plantWavingField(vec3 worldPos, float amplitude, float yWeight) {
    float t = frameTimeCounter;
    float noiseRes = float(textureSize(noisetex, 0).x);

    float noiseRcp = 1.0 / (WAVING_NOISE_SCALE * noiseRes);

    vec3 rand0 = texture(noisetex, worldPos.xz * (noiseRcp * 0.25)).rgb;
    vec3 slow = 0.01 * sin((0.33 * WAVING_RATE * t + rand0) * TAU);

    vec3 rand1 = texture(noisetex, (worldPos.xz + vec2(693.4271)) * noiseRcp).rgb;
    vec3 fast = 0.05 * sin((WAVING_RATE * t + rand1) * TAU);

    vec2 gustCoord = WAVING_GUST_ROT * worldPos.xz;
    gustCoord = vec2(gustCoord.x * 3.0 + t * WAVING_GUST_SPEED, gustCoord.y);
    vec3 gust = texture(noisetex, gustCoord * (noiseRcp * (1.0 / 64.0))).rgb;
    fast *= remapSaturate(gust.g, 0.33 * (1.0 - rainStrength), 1.0, 0.2 * rainStrength, 1.0);

    vec3 offset = slow + fast;
    offset.y *= yWeight;
    return offset * amplitude;
}

// 总入口（两侧接入点）：观察位置进出——分族门控 → 世界坐标重建 → 距离门（距玩家世界距离的平滑淡出，
// gbuffers / shadow 同式）→ 风场偏移转回观察系。观察系换算矩阵由调用方按阶段传入（gbuffers 侧
// gbufferModelView(Inverse)、shadow 侧 shadowModelView(Inverse)），风场与距离门只吃世界系输入——
// 两侧同函数同输入 = 阴影同步的结构性保证。
// 门控顺序是性能关键：分族判定先于世界坐标重建——非植物顶点（地形的绝大多数）即刻返回、不付逆矩阵
// 乘法与零偏移的正向矩阵乘法；距离门必须在世界系度量（|viewPos| 仅 gbuffers 侧等于相机距离——shadow
// 侧眼点不在原点，两侧各用观察系长度会失同步），故远距植物顶点照付一次逆矩阵、由 fade ≤ 0 早退挡住
// 风场采样
vec4 applyPlantWaving(vec4 viewPos, mat4 viewToWorld, mat3 worldToView,
                      float blockId, float texCoordT, float midTexCoordT) {
    vec2 params = plantWavingParams(blockId, texCoordT, midTexCoordT);
    if (params.x <= 0.0) return viewPos;

    vec3 relativeWorldPos = (viewToWorld * viewPos).xyz;
    float fade = 1.0 - remapSaturate(length(relativeWorldPos),
                                     WAVING_DISTANCE - WAVING_FADE_RANGE, WAVING_DISTANCE, 0.0, 1.0);
    if (fade <= 0.0) return viewPos;

    vec3 offset = plantWavingField(relativeWorldPos + cameraPosition, params.x, params.y) * fade;
    return vec4(viewPos.xyz + worldToView * offset, viewPos.w);
}

#endif

#endif
