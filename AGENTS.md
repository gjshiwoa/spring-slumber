# AGENTS.md

## 项目简介

「春眠」是一个 Minecraft 光影包（shaderpack），适用于 OptiFine / Iris。

**定位**：低配 / 高兼容性，不使用激进的渲染特性。

## 参考文档

- Shader 开发文档：<https://shaders.properties/>

## 架构决策

- GLSL `#version 330 compatibility`
- 渲染路线：**轻量 deferred**（已定稿）
  - 不透明几何在 gbuffers 写 gbuffer（MRT 两张：`colortex4` 打包 albedo + 高光贴图、`colortex5` 观察空间法线 + 原始 lmcoord），**不写 colortex0/1**；`deferred` 解包 colortex4 后写 `colortex0`（骨架阶段为直通）
  - 打包方式参考春雷：`pack4x8To2x16` 把 4×8bit 值对打包进两个 16bit 无符号通道（colortex4.rg = albedo RGBA、colortex4.ba = 高光 RGBA、colortex5.rg = 八面体观察空间法线、colortex5.ba = 原始 lmcoord）；lmcoord 存原始值，重映射（`remapLightmap`）移到读取端
  - 法线处理参考春雷 / 春v2：不用 `at_tangent` 属性，vsh 传观察空间位置 varying，fsh 用屏幕导数构造 cotangent frame TBN（`lib/tbn.glsl` 的 `calculateTBN`），labPBR 贴图法线 `*2-1`（不翻 Y，与两家参考一致）左乘 TBN 变换到观察空间、归一化后八面体编码输出；无 normals 纹理时贴图为 (0.5, 0.5, 1.0)，结果即导数几何法线（读取端拿到的始终是观察空间法线）
  - 绘制时机决定路线（OptiFine/Iris 默认顺序：仅 `weather` / `water` / `hand_water` 在 deferred 之后）：
    - deferred **之前**的不透明几何 → 写 gbuffer，延迟光照
    - 前向半透明保留引擎混合、按 alpha 混合写 `colortex0`，框架阶段直接输出线性 tex 颜色（sRGB→线性，pow 2.2），分两档：
      - **完整处理** `gbuffers_water`：deferred 之后的 water；光照接入后共享 `lib/lighting.glsl` 的 `shadeSurface`、雾 / 水面效果
      - **简单处理** `gbuffers_translucent_simple`：deferred 之后的 hand_water / weather 与 deferred 之前的 textured / textured_lit / particles（写 colortex0 会被 deferred 全屏覆盖，见已知限制）；扩展点为光照图轻量着色 / 雾，不接全量光照
      - 春雷式手动合成备选（关闭引擎混合、着色器内采样已有内容重新打包进 `colortex4.rg`，不写 colortex5，背景法线 / lm 保持完好）保留在 `program/gbuffers_textured.glsl`，当前未链接
    - 引擎混合：shaders.properties 只对项目已存在的入口直接 `blend.* = off`，不改各程序 colortex 写法——`terrain / block / hand / entities`（打包 gbuffer 整像素覆盖写入）与 `basic / lightning`（gbuffers_color 手动合成，引擎混合须关）关闭；`water`（完整处理）、`hand_water / weather / textured / textured_lit`（简单处理）保留引擎混合；未创建的拆分入口（`terrain_solid/cutout`、`*_translucent` 等）不列（Iris 按阶段名匹配混合配置、不随回退链继承，OptiFine 忽略未知阶段名）
  - **当前为纯骨架阶段**：所有阶段只做数据直通，无任何效果（光照 / 天空 / tonemap 均为扩展点，效果库已备好暂不接入）；前向半透明已引入 sRGB→线性（pow 2.2），deferred / `final` 侧的颜色空间转换与曝光 + tonemap 随光照接入再统一
  - 无阴影贴图：直射光用光照图 skyLight 门控近似遮挡（避免阳光穿墙）的方案已写在 `lib/lighting.glsl`；`shadow` 阶段留作扩展点
- 入口文件按维度分目录：`shaders/world0/`（主世界）等；入口不含逻辑，只做宏定义 + `#include` program 文件
- `shaders/program/` 位于根目录，全维度共享（`#include` 用绝对路径 `/program/...`）；program 文件按渲染阶段加前缀命名（如 `gbuffers_*`）
- varying 统一用 `VARYING` 宏声明（`lib/common.glsl` 中按阶段展开为 `in`/`out`），同一 varying 在 program 文件顶部只声明一次
- uniform 全部集中声明在 `lib/uniforms.glsl`，program 文件不自行声明
- 常量全部集中声明在 `lib/constants.glsl`（含缓冲格式 `colortexNFormat`、像素格式名称 `RGBA16`/`RGBA16F`、cutout 阈值、光照 / 天空颜色等）；OptiFine/Iris 扫描 include 展开后的内容
- **lib 文件之间不互相 include（无嵌套）**：依赖一律由 program 按需平铺引入；`constants.glsl` 须在 `common.glsl` 之前（`remapLightmap` 依赖其常量），`sky.glsl` / `lighting.glsl` 所需的 uniforms / 常量同样由接入方先行 include
- 标识符命名避开 GLSL 保留字（`packed` / `filter` / `sample` / `input` / `output` 等）
- 采样纹理统一命名 `tex`
- program 文件中 fsh 写在前半部分，vsh 写在后半部分，用 `#ifdef STAGE_FRAGMENT` / `#ifdef STAGE_VERTEX` 分隔
- 每个 program 的 fsh 段必须含 `/* DRAWBUFFERS:... */` 注释指定输出通道（OptiFine/Iris 在 `#include` 展开后扫描该注释）；该行前后不得有其他注释内容，独占一行；输出用 `layout(location = N)` 显式绑定，location 按 DRAWBUFFERS 列表顺序编号；gbuffer 类程序写 `45` 两通道，deferred 之前的手动合成类写 `4`，deferred / 前向 post-deferred 类写 `colortex0`

## 缓冲布局

| 缓冲 | 格式 | 内容 | 写入者 |
|---|---|---|---|
| colortex0 | RGBA16F | deferred 之后 = 直通 / 光照后颜色 | deferred → 前向类（混合） |
| colortex1 | - | 预留 | - |
| colortex4 | RGBA16 | rg = 打包 albedo（tex × 顶点色，4x8→2x16），ba = 打包高光贴图 RGBA（4x8→2x16，labPBR） | gbuffer 类全量写入；textured / color 手动合成写入 rg |
| colortex5 | RGBA16 | rg = 八面体编码的观察空间法线（labPBR 贴图法线经导数 cotangent TBN 变换，无 normals 纹理时为导数几何法线），ba = 原始 lmcoord（读取端再重映射） | gbuffer 类 |
| depthtex0 | - | deferred 时刻仅含不透明几何深度，`deferred` 用 `depth >= 1` 区分天空（待光照接入后启用） | 引擎 |

- 位打包值粒度 1/65535，colortex4/5 必须是 16bit 无符号规范化格式（RGBA16），不可改为浮点格式

## 管线路线（world0）

| 路线 | program | 入口 | 说明 |
|---|---|---|---|
| deferred gbuffer | `gbuffers_terrain` | terrain, block, hand | MRT 写 colortex4/5（打包 albedo+高光 / 观察空间法线+原始 lm）+ cutout |
| deferred gbuffer | `gbuffers_entities` | entities | 同上，叠加 `entityColor` |
| 手动合成 | `gbuffers_color` | basic, lightning | 关闭引擎混合，着色器内合成打包进 colortex4.rg，纯顶点色（选框 / 闪电等非光照几何）；line 无入口，沿回退链落到 basic |
| 前向完整 | `gbuffers_water` | water | deferred 之后的半透明完整处理，引擎 alpha 混合写 colortex0，框架阶段线性 tex 直通；光照接入后共享 `shadeSurface` |
| 前向简单 | `gbuffers_translucent_simple` | hand_water, weather, textured, textured_lit | 半透明简单处理，引擎 alpha 混合写 colortex0，框架阶段线性 tex 直通；hand_water / weather 在 deferred 之后，textured 族在其之前（被覆盖，见已知限制）；particles 无入口，沿回退链落到 textured_lit |
| 禁用 | `gbuffers_empty` | skybasic, skytextured, clouds, armor_glint, beaconbeam, spidereyes, damagedblock | discard（天空禁用后天空像素为缓冲清除色） |
| 全屏 | `deferred` | deferred | 解包 colortex4 直通写 colortex0；光照核心扩展点 |
| 全屏 | `final` | final | 直通输出；曝光 / tonemap 扩展点 |

- `program/gbuffers_skybasic.glsl`、`program/gbuffers_skytextured.glsl` 已备好未链接（原版直通版本），重新启用天空时把入口指回即可
- `program/gbuffers_textured.glsl`（春雷式手动合成版本）已备好未链接，textured 族需要回退打包路线时把入口指回即可

- 缺失的 program 沿回退链 fallback（如 `hand_water → hand → textured_lit`），禁用某阶段必须显式创建入口指向 gbuffers_empty
- 以下入口**不创建文件**，靠回退链落到主 program：`terrain_solid/cutout → terrain`、`block_translucent → block`、`entities_translucent → entities`、`line → basic`、`particles / particles_translucent → textured_lit`
- `entities_glowing` 仅 OptiFine 识别、Iris 不使用，不创建

## lib 一览

- `lib/common.glsl`：`VARYING` 宏、`remapLightmap`（依赖 `constants.glsl` 先行 include）
- `lib/constants.glsl`：全部常量集中声明（缓冲格式、像素格式名称 `RGBA16`/`RGBA16F`、cutout 阈值、光照 / 天空颜色等）
- `lib/uniforms.glsl`：全部 uniform 集中声明
- `lib/encoding.glsl`：八面体法线编解码
- `lib/tbn.glsl`：导数 cotangent frame（`calculateTBN` / `calculateGeomNormal`，春雷 / 春v2 同款）——贴图法线到观察空间的变换；仅片段阶段可用，无依赖
- `lib/packing.glsl`：位打包工具（`pack4x8To2x16` / `unpack2x16To4x8` 等，参考春雷）
- `lib/sky.glsl`：天空颜色（昼夜 / 黄昏 / 雨天渐变）——**已备好，暂不接入**；依赖先行 include `uniforms.glsl` / `constants.glsl`
- `lib/lighting.glsl`：`shadeSurface` 光照主入口（deferred 与前向共用）——**已备好，暂不接入**；依赖先行 include `uniforms.glsl` / `constants.glsl` / `sky.glsl`

## 当前状态

纯管线骨架，无任何效果：gbuffer 只写 colortex4/5（春雷式位打包），颜色由 deferred 解包 colortex4 直通写 colortex0（未转线性）；前向半透明（water / hand_water / weather / textured 族）输出线性 tex 颜色（pow 2.2）混合进 colortex0。无光照 / 天空 / tonemap。天空入口（skybasic / skytextured）链接到空程序，天空像素显示缓冲清除色。

已知限制（均为后续扩展点）：

- 几何法线不单独存储：已随导数 TBN 并入 colortex5 的观察空间法线（无 normal 贴图像素即几何法线，但有贴图法线的像素无法还原几何法线）；光照若需二者分离（如天空环境光半球 / 湿地面混合），参考春雷 normalOV 单独存通道
- 手动合成类程序（color；`gbuffers_textured` 手动合成版当前未链接）读取正在写入的 colortex4（texelFetch 当前附件，春雷同款做法），个别驱动上属于未定义行为；高光 ba 通道在混合处随 alpha 衰减
- 光照：`deferred` 读 colortex4/5 + depthtex0 计算后写回；`gbuffers_water` 前向共享 `lib/lighting.glsl`
- 天空：`gbuffers_skybasic` 接入 `lib/sky.glsl` 程序化渐变
- 颜色空间：接入光照时引入 sRGB↔线性 与 `final` 的曝光 + tonemap（替换直通）
- 无 shadow 阶段：阴影贴图 + PCF 可直接加在 `deferred` 内（gbuffer 已有法线与深度）
- 无雾 / 水下效果：可在 `deferred` 与前向程序里基于视距混合 `getSkyColor`
- `composite` 阶段（bloom 等）尚未启用
- 半透明实体 / 半透明方块实体（Iris 的 `entities_translucent` / `block_translucent`）沿回退链落到 `entities` / `block` 程序；其引擎混合已随主程序关闭（不再串扰），透明部分暂按不透明写入，正确的半透明表现留待后续显式处理
- textured / textured_lit / particles（particles 无入口，经 textured_lit 回退）改走前向后仍在 deferred 之前绘制，写入的 colortex0 会被 deferred 全屏覆盖（这些几何暂不可见），待后续处理：Iris 可设 `particles.ordering` 调整粒子时机，或 textured 族改回手动合成路线（`program/gbuffers_textured.glsl`）
