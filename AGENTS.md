# AGENTS.md

## 项目简介

「春眠」是一个 Minecraft 光影包（shaderpack），适用于 OptiFine / Iris。

**定位**：低配 / 高兼容性，不使用激进的渲染特性。

## 参考文档

- Shader 开发文档：<https://shaders.properties/>

## 架构决策

- GLSL `#version 330 compatibility`
- 渲染路线：**轻量 deferred**（已定稿）
  - 不透明几何在 gbuffers 写 gbuffer（MRT 两张：`colortex4` 打包 albedo + 高光贴图、`colortex5` 观察空间法线 + 原始 lmcoord），**不写 colortex0/1**；`deferred_init` 解包 colortex4 的 albedo、反 gamma（`srgbToLinear`）后初始化线性 `colortex0`
  - 打包方式参考春雷：`pack4x8To2x16` 把 4×8bit 值对打包进两个 16bit 无符号通道（colortex4.rg = albedo RGBA、colortex4.ba = 高光 RGBA、colortex5.rg = 八面体观察空间法线、colortex5.ba = 原始 lmcoord）；lmcoord 存原始值，重映射（`remapLightmap`）移到读取端
  - 法线处理参考春雷 / 春v2：不用 `at_tangent` 属性，vsh 传观察空间位置 varying，fsh 用屏幕导数构造 cotangent frame TBN（`lib/common/utils/space.glsl` 的 `calculateTBN`），labPBR 贴图法线 `*2-1`（不翻 Y，与两家参考一致）左乘 TBN 变换到观察空间、归一化后八面体编码（`lib/common/utils/packing.glsl`）输出；无 normals 纹理时贴图为 (0.5, 0.5, 1.0)，结果即导数几何法线（读取端拿到的始终是观察空间法线）
  - 绘制时机决定路线（OptiFine/Iris 默认顺序：仅 `weather` / `water` / `hand_water` 在 deferred 之后）：
    - deferred **之前**的不透明几何 → 写 gbuffer，延迟光照
    - 前向半透明保留引擎混合、按 alpha 混合写 `colortex0`，框架阶段直接输出线性 tex 颜色（`srgbToLinear`），分两档：
      - **完整处理** `gbuffers_translucent`：deferred 之后的 water；光照接入后共享 `lib/lighting/lighting.glsl` 的 `shadeSurface`、雾 / 水面效果
      - **简单处理** `gbuffers_translucent_simple`：deferred 之后的 hand_water / weather 与 deferred 之前的 textured / textured_lit / particles（写 colortex0 会被 deferred 全屏覆盖，见已知限制）；扩展点为光照图轻量着色 / 雾，不接全量光照
      - 春雷式手动合成备选（关闭引擎混合、着色器内采样已有内容重新打包进 `colortex4.rg`，不写 colortex5，背景法线 / lm 保持完好）保留在 `program/gbuffers_color_textured.glsl`，当前未链接
      - 信标光柱 `beaconbeam`（参考春雷，`gbuffers_beacon`）：deferred 之前绘制但含**不透明核心 + 半透明外壳**，按 alpha 分支——核心（a ≥ `ALPHA_BEACON_CORE`）整像素写 gbuffer（自发光 `BEACON_CORE_EMISSIVE` 写入 specular.a、lm = 0、导数几何法线），外壳手动合成进 colortex4.rg、背景 specular 与 colortex5 读回写回；引擎混合须关
    - 引擎混合：shaders.properties 只对项目已存在的入口直接 `blend.* = off`，不改各程序 colortex 写法——`terrain / block / hand / entities`（打包 gbuffer 整像素覆盖写入）、`basic`（gbuffers_color 手动合成）与 `beaconbeam`（gbuffers_beacon 核心整像素写 + 外壳手动合成，引擎混合须关）关闭；`water`（完整处理）、`hand_water / weather / textured / textured_lit`（简单处理）保留引擎混合；lightning 入口已删除（沿回退链落到 textured，保留引擎混合）；未创建的拆分入口（`terrain_solid/cutout`、`*_translucent` 等）不列（Iris 按阶段名匹配混合配置、不随回退链继承，OptiFine 忽略未知阶段名）
  - **当前为效果骨架**：光照 / 天空仍为扩展点（效果库已备好暂不接入）；颜色管线已定型——`deferred_init` 反 gamma 初始化线性 `colortex0`，前向半透明线性混合，`composite_tonemap` 在线性域 AgX tonemap（春雷同款 minimal AgX，末段 pow 2.2 即「回到线性」，缓冲保持线性），`final` 做 gamma 矫正（`linearToSrgb`，全管线唯一离开线性空间的位置）；自动曝光已接入——亮度算法取春雷（bloom 图集最粗 tile 对数平均 + 0.18 key 直除 + 曝光域指数适应）、pass 设计取春v2（寄生 `composite_bloom_merge` 测光、colortex7 右上角单像素存储、全屏透传保值、tonemap 前乘一次），`AGX_ADDITIVE`（春雷值 0.6）为 AgX 曲线预缩放、与曝光系数各司其职
  - 无阴影贴图：直射光用光照图 skyLight 门控近似遮挡（避免阳光穿墙）的方案已写在 `lib/lighting/lighting.glsl`；`shadow` 阶段留作扩展点
- 入口文件按维度分目录：`shaders/world0/`（主世界）等；入口不含逻辑，只做宏定义 + `#include` program 文件
- `shaders/program/` 位于根目录，全维度共享（`#include` 用绝对路径 `/program/...`）；program 文件按**「阶段_功能」**命名（前缀 = 渲染阶段，后缀 = 该程序在此阶段做的事，不跟入口名、不带序号）：`gbuffers_opaque` / `gbuffers_opaque_entities` / `gbuffers_color` / `gbuffers_color_textured` / `gbuffers_translucent` / `gbuffers_translucent_simple` / `gbuffers_empty` / `gbuffers_sky` / `gbuffers_sky_tex`；全屏类中 **deferred 阶段用于初始化**（`deferred_init`）、composite 系按功能命名（`composite_tonemap` / `composite_bloom` / `composite_bloom_merge`，同一 program 由多个入口以宏区分级数时宏名写在入口，如 `BLOOM_LEVEL`；序号属于 world0 入口文件名，如 `composite14.fsh`），`final` 程序名保持不带功能后缀。world0 入口文件名是引擎阶段名、保持不变，只有 `#include` 指向变化
- varying 统一用 `VARYING` 宏声明（`lib/common/pipeline/varying_io.glsl` 中按阶段展开为 `in`/`out`），同一 varying 在 program 文件顶部只声明一次
- uniform 全部集中声明在 `lib/common/globals/uniforms.glsl`，program 文件不自行声明
- 常量全部集中声明在 `lib/common/globals/constants.glsl`（含缓冲格式 `colortexNFormat`、像素格式名称 `RGBA16`/`RGBA16F`、cutout 阈值、光照 / 天空颜色等）；OptiFine/Iris 扫描 include 展开后的内容
- **lib 文件之间不互相 include（无嵌套）**：依赖一律由 program 按需平铺引入；`constants.glsl` 须在 `pipeline/gbuffer_data.glsl` 之前（`remapLightmap` 依赖其常量），`sky.glsl` / `lighting.glsl` 所需的 uniforms / 常量同样由接入方先行 include
- 标识符命名避开 GLSL 保留字（`packed` / `filter` / `sample` / `input` / `output` 等）
- 采样纹理统一命名 `tex`
- program 文件中 fsh 写在前半部分，vsh 写在后半部分，用 `#ifdef STAGE_FRAGMENT` / `#ifdef STAGE_VERTEX` 分隔
- 每个 program 的 fsh 段必须含 `/* DRAWBUFFERS:... */` 注释指定输出通道（OptiFine/Iris 在 `#include` 展开后扫描该注释）；该行前后不得有其他注释内容，独占一行；输出用 `layout(location = N)` 显式绑定，location 按 DRAWBUFFERS 列表顺序编号；gbuffer 类程序写 `45` 两通道，deferred 之前的手动合成类写 `4`，deferred / composite / 前向 post-deferred 类写 `colortex0`（`composite_bloom_merge` 兼写 `07`：colortex7 角点存自适应曝光、其余透传）

## 缓冲布局

| 缓冲 | 格式 | 内容 | 写入者 |
|---|---|---|---|
| colortex0 | RGBA16F | 线性场景颜色（deferred_init 反 gamma 初始化；composite_tonemap 后为 tonemap 后的线性显示参考色；光照接入后为光照结果） | deferred_init → 前向类（线性混合）→ composite_tonemap → final |
| colortex1 | RGBA16F | bloom tile 图集：tile0 = 左上 1/4×1/4（屏幕 1/4 分辨率起步），tile1~4 右侧纵列堆叠边长 1/8~1/64，图集约占缓冲 10% 面积，tile 间隔 4 texel | composite_bloom 链（composite8~12）写入 → composite_bloom_merge（composite13）消费 |
| colortex4 | RGBA16 | rg = 打包 albedo（tex × 顶点色，4x8→2x16），ba = 打包高光贴图 RGBA（4x8→2x16，labPBR） | gbuffer 类全量写入；textured / color 手动合成写入 rg |
| colortex5 | RGBA16 | rg = 八面体编码的观察空间法线（labPBR 贴图法线经导数 cotangent TBN 变换，无 normals 纹理时为导数几何法线），ba = 原始 lmcoord（读取端再重映射） | gbuffer 类 |
| colortex7 | RGBA16F，clear = false | 杂项数据缓冲：右上角 1 texel = 自适应曝光（r 通道，适应后曝光系数）；其余区域预留给天空盒纹理等杂项数据 | composite_bloom_merge（composite13）角点写入 / 其余透传 → composite_tonemap（composite14）读角点应用 |
| depthtex0 | - | deferred 时刻仅含不透明几何深度，`deferred_init` 用 `depth >= 1` 区分天空（待光照接入后启用） | 引擎 |

- 位打包值粒度 1/65535，colortex4/5 必须是 16bit 无符号规范化格式（RGBA16），不可改为浮点格式
- **colortex7 槽位协议**（杂项缓冲，参考春v2 colortex7 实践）：右上角 1 texel = 自适应曝光（`lib/post/exposure.glsl` 的 `exposureTexel()`），天空盒等后续数据自分区槽位、单像素槽集中写成常量函数；任何 colortex7 写入者必须**全屏透传不属于自己的区域**（同位置 texelFetch 读回写回）——内容随每次写入复制到另一块 surface，全部槽位跨帧、跨 main/alt 翻转存活，`colortex7Clear = false` 恒定，禁止依赖 `flip.*`

## 管线路线（world0）

| 路线 | program | 入口 | 说明 |
|---|---|---|---|
| deferred gbuffer | `gbuffers_opaque` | terrain, block, hand | MRT 写 colortex4/5（打包 albedo+高光 / 观察空间法线+原始 lm）+ cutout |
| deferred gbuffer | `gbuffers_opaque_entities` | entities | 同上，叠加 `entityColor` |
| 手动合成 | `gbuffers_color` | basic | 关闭引擎混合，着色器内合成打包进 colortex4.rg，纯顶点色（选框等非光照几何）；line 无入口沿回退链落到 basic，lightning 入口已删除、落到 textured |
| 信标光柱 | `gbuffers_beacon` | beaconbeam | deferred 之前绘制，按 alpha 分支：不透明核心整像素写 gbuffer（自发光、lm = 0、导数几何法线），半透明外壳手动合成进 colortex4.rg、背景 specular / colortex5 读回写回；引擎混合关，参考春雷 |
| 前向完整 | `gbuffers_translucent` | water | deferred 之后的半透明完整处理，引擎 alpha 混合写线性 colortex0，框架阶段线性 tex 直通；光照接入后共享 `shadeSurface` |
| 前向简单 | `gbuffers_translucent_simple` | hand_water, weather, textured, textured_lit | 半透明简单处理，引擎 alpha 混合写线性 colortex0，框架阶段线性 tex 直通；hand_water / weather 在 deferred 之后，textured 族在其之前（被覆盖，见已知限制）；particles 无入口，沿回退链落到 textured_lit |
| 禁用 | `gbuffers_empty` | skybasic, skytextured, clouds, armor_glint, spidereyes, damagedblock | discard（天空禁用后天空像素为缓冲清除色） |
| 全屏 | `deferred_init` | deferred | 初始化 pass：解包 colortex4 的 albedo，反 gamma 写线性 colortex0；光照核心扩展点 |
| 全屏 | `composite_bloom` | composite8~12 | bloom 链式下采样金字塔 1/4~1/64 分辨率（BLOOM_LEVEL 0~4 由入口宏定义，c13 同款 1/4 起步）：tile < 本级的像素复制回写、tile = 本级的从上一级（或 colortex0）做 13-tap 高斯下采样（COD AW 核，春雷快速路径同款）写 colortex1 图集、其余 discard；vsh 把 quad 压缩到 tiles 0~本级包围盒只光栅化图集区域；无阈值，整幅 HDR 进金字塔 |
| 全屏 | `composite_bloom_merge` | composite13 | bloom 上采样合并 + 场景合成：读 colortex1 tile 图集（`getBloom`，5 tile 双线性放大加权平均），乘 `BLOOM_STRENGTH` 与线性 colortex0 相加写回 colortex0（tonemap 前线性域），图集自此被消费；兼自动曝光寄生存储（春v2 同款，不新增 pass）——右上角 1 texel 测 tile4 对数平均亮度（春雷算法）、与上一帧曝光指数平滑写 colortex7 角点，其余像素 colortex7 透传 |
| 全屏 | `composite_tonemap` | composite14 | 位于 bloom 合成（composite13）之后、final 之前；读线性 colortex0（已含 bloom），乘 colortex7 角点的自适应曝光后做 AgX tonemap（lib/post/tonemap.glsl）写回 |
| 全屏 | `final` | final | gamma 矫正（`linearToSrgb`，pow 1/2.2）输出到屏幕；全管线唯一离开线性空间的位置 |

- `program/gbuffers_sky.glsl`、`program/gbuffers_sky_tex.glsl` 已备好未链接（原版直通版本，对应 skybasic / skytextured 入口），重新启用天空时把入口指回即可
- `program/gbuffers_color_textured.glsl`（春雷式手动合成版本）已备好未链接，textured 族需要回退打包路线时把入口指回即可
- **composite 编号约定**：deferred / composite 编号不超过 14；composite8~12 = bloom 下采样链，composite13 = bloom 上采样合并，composite14 = tonemap（final 前最后一级），composite0~7 预留给后续 pass（新效果从 7 往前排、bloom 链与 tonemap 始终居 8~14）

- 缺失的 program 沿回退链 fallback（如 `hand_water → hand → textured_lit`），禁用某阶段必须显式创建入口指向 gbuffers_empty
- 以下入口**不创建文件**，靠回退链落到主 program：`terrain_solid/cutout → terrain`、`block_translucent → block`、`entities_translucent → entities`、`line → basic`、`particles / particles_translucent → textured_lit`、`lightning → textured`（lightning 原入口已删除）
- `entities_glowing` 仅 OptiFine 识别、Iris 不使用，不创建

## lib 一览（文件夹分类对齐春雷：`common/{globals,pipeline,utils}` / `atmosphere` / `lighting` / `post`，按效果域扩展 `surface` 等）

**lib/common/globals/**（全局声明，几乎每个 program 都引）

- `constants.glsl`：全部常量集中声明（缓冲格式、像素格式名称 `RGBA16`/`RGBA16F`、cutout 阈值、光照 / 天空颜色、AgX / Bloom 参数等）
- `uniforms.glsl`：全部 uniform 集中声明

**lib/common/pipeline/**（管线接口）

- `varying_io.glsl`：`VARYING` 宏（顶点阶段展开为 `out`、片段阶段为 `in`，对应春雷 pipeline/varying_io.glsl）
- `gbuffer_data.glsl`：gbuffer 数据读取端工具——`remapLightmap` 光照图重映射（依赖 `constants.glsl` 先行 include，对应春雷 pipeline/gbuffer_data.glsl 的读取换算部分）；光照接入后在此扩展 colortex4/5 的解包读取

**lib/common/utils/**（通用工具，函数级复用）

- `color.glsl`：颜色空间转换（`srgbToLinear` 反 gamma / `linearToSrgb` gamma 矫正，pow 2.2 近似；`rgbToLuma` Rec.709 相对亮度，对应春雷 utils/color.glsl）
- `filters.glsl`：通用采样 / 滤波工具（`textureNice` 平滑双线性、`downsample13Tap` COD AW 下采样核，对应春雷 filters.glsl）——函数全部显式传参，无 uniforms / 常量依赖，任何 program 可直接引入
- `space.glsl`：坐标空间构造——导数 cotangent frame（`calculateTBN` / `calculateGeomNormal`，春雷 utils/space.glsl 同位，仅片段阶段）
- `packing.glsl`：数据打包 / 编码——位打包（`pack4x8To2x16` / `unpack2x16To4x8` 等）+ 八面体映射（`encodeOctahedral` / `decodeOctahedral`，单位向量 ↔ 二维 [0,1]，不限法线用途），与春雷 packing.glsl 同文件组织

**lib/atmosphere/**（大气 / 天空）

- `sky.glsl`：天空颜色（昼夜 / 黄昏 / 雨天渐变）——**已备好，暂不接入**；依赖先行 include `uniforms.glsl` / `constants.glsl`

**lib/lighting/**（光照）

- `lighting.glsl`：`shadeSurface` 光照主入口（deferred 与前向共用）——**已备好，暂不接入**；依赖先行 include `uniforms.glsl` / `constants.glsl` / `atmosphere/sky.glsl`

**lib/post/**（后处理）

- `bloom.glsl`：bloom tile 图集布局（`bloomTileRect`，金字塔 1/4~1/64 分辨率、c13 同款 1/4 起步）、链式下采样（`bloomDownsampleTile`，调用 filters.glsl 的 `downsample13Tap`，tap 步长 `BLOOM_BLUR_STEP` 源纹素）、合并入口（`getBloom`，调用 filters.glsl 的 `textureNice`）——**已接入** `composite_bloom` / `composite_bloom_merge`；矩形计算用 `textureSize` 运行时推导、不假设缓冲分辨率（不依赖 size.buffer，低版本 OptiFine 兼容）；性能取舍——下采样 13-tap、上采样 textureNice（单采样）、合并 5 tap 全屏（含场景相加与强度合成）、链 pass 的 vsh 做 quad 压缩只光栅化图集区域（全屏 discard 浪费填充率）；依赖先行 include `constants.glsl` / `uniforms.glsl` / `filters.glsl`
- `tonemap.glsl`：AgX tonemap（春雷同款 minimal AgX，`agx` 入口）——**已接入** `composite_tonemap`；末段 pow 2.2 为「回到线性」，输出仍线性；依赖先行 include `constants.glsl`
- `exposure.glsl`：自动曝光（亮度算法春雷同款、pass 设计春v2 同款）——`exposureTexel` colortex7 右上角槽位、`sceneAverageLuminance` bloom 图集最粗 tile（tile4）全纹素对数平均、`targetExposure` 0.18 key 直除、`adaptedExposure` 曝光域指数平滑（帧率无关、首帧守卫）、`readAdaptedExposure` 读取端——**已接入** `composite_bloom_merge`（角点测光写入）/ `composite_tonemap`（tonemap 前乘一次）；测光含天空像素（与两家参考一致）；依赖先行 include `constants.glsl` / `uniforms.glsl` / `bloom.glsl` / `color.glsl`（rgbToLuma）

## 当前状态

效果骨架：gbuffer 只写 colortex4/5（春雷式位打包，albedo 存原始 sRGB），`deferred_init` 解包 colortex4 反 gamma 初始化线性 colortex0；前向半透明（water / hand_water / weather / textured 族）线性混合进 colortex0；`composite_bloom`（composite8~12）生成 bloom tile 图集，`composite_bloom_merge`（composite13）上采样合并并乘强度与场景相加写回 colortex0，兼在 colortex7 右上角做自动曝光测光与时间适应（角点写入、其余透传）；`composite_tonemap`（composite14）乘自适应曝光后 AgX tonemap 回到线性写回；`final` gamma 矫正输出。无光照 / 天空。天空入口（skybasic / skytextured）链接到空程序，天空像素显示清除色经 tonemap / gamma 管线后的结果。

已知限制（均为后续扩展点）：

- 几何法线不单独存储：已随导数 TBN 并入 colortex5 的观察空间法线（无 normal 贴图像素即几何法线，但有贴图法线的像素无法还原几何法线）；光照若需二者分离（如天空环境光半球 / 湿地面混合），参考春雷 normalOV 单独存通道
- 手动合成类程序（color、beacon 外壳分支；`gbuffers_color_textured` 手动合成版当前未链接）读取正在写入的 colortex4（beacon 外壳还读 colortex5）（texelFetch 当前附件，春雷同款做法），个别驱动上属于未定义行为；高光 ba 通道在混合处随 alpha 衰减；`composite_bloom_merge` 的 colortex7 全屏透传同款（读正在写的附件）
- 光照：`deferred_init` 读 colortex4/5 + depthtex0 计算后写回；`gbuffers_translucent` 前向共享 `lib/lighting/lighting.glsl`
- 天空：`gbuffers_sky` 接入 `lib/atmosphere/sky.glsl` 程序化渐变
- 自动曝光：已接入（春雷亮度算法：tile4 对数平均 + 0.18 key 直除 + 曝光域指数适应；春v2 pass 设计：寄生 composite13、colortex7 右上角单像素、全屏透传 + clear=false 跨帧保值、tonemap 前乘一次）。测光含天空像素（与春雷 / 春v2 一致），当前天空为清除色 0，大面积天空入画会把 avgLum 拉向 `AUTO_EXPOSURE_MIN_LUMINANCE`、曝光明显偏高（地面近过曝），天空接入后自然恢复；骨架期如需画面正常可临时收紧 `targetExposure` 上限（如 4.0）。RGBA16F 半精度下曝光实际被 MIN_LUMINANCE 约束在 ≤ 720，无溢出；适应步长（RATE 2.0 下 60fps 每帧约 3%）远大于半精度 0.1% 量化步长，无卡顿风险
- 无 shadow 阶段：阴影贴图 + PCF 可直接加在 `deferred_init` 内（gbuffer 已有法线与深度）
- 无雾 / 水下效果：可在 `deferred_init` 与前向程序里基于视距混合 `getSkyColor`
- composite 编号已用：8~12（bloom 下采样链）、13（bloom 上采样合并）、14（tonemap）；0~7 预留
- bloom 无阈值（与春雷 / 春 v2 / BSL 等全部参考一致）：整幅 HDR 直接进金字塔，靠亮度自然衰减；当前无光照画面整体呈轻微柔光属预期，光照接入后 HDR 值自动分层；如需阈值可在 `bloomDownsampleTile` 的 k = 0 分支加 soft knee
- bloom 链每个 pass 重写自己需要的全部 tile（低级 tile 复制回写）：跨 pass 保值对 OptiFine / Iris 的 main/alt 缓冲翻转语义免疫，无需 `flip.*` 配置（春雷靠 `flip.*=false` 累积图集的做法依赖引擎语义细节，本方案规避）；colortex1 为全尺寸缓冲仅图集区域被采样（不用 `size.buffer`，低版本 OptiFine 不支持），后续如需省显存 / 带宽可降级 `R11F_G11F_B10F`（bloom 不需要 alpha）
- 半透明实体 / 半透明方块实体（Iris 的 `entities_translucent` / `block_translucent`）沿回退链落到 `entities` / `block` 程序；其引擎混合已随主程序关闭（不再串扰），透明部分暂按不透明写入，正确的半透明表现留待后续显式处理
- textured / textured_lit / particles / lightning（particles 无入口经 textured_lit 回退，lightning 入口已删除经 textured 回退）改走前向后仍在 deferred 之前绘制，写入的 colortex0 会被 deferred 全屏覆盖（这些几何暂不可见），待后续处理：Iris 可设 `particles.ordering` 调整粒子时机，或 textured 族改回手动合成路线（`program/gbuffers_color_textured.glsl`）
