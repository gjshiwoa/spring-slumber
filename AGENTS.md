# AGENTS.md

## 项目简介

「春眠」是一个 Minecraft 光影包（shaderpack），适用于 OptiFine / Iris。

**定位**：低配 / 高兼容性，不使用激进的渲染特性。

## 参考文档

- Shader 开发文档：<https://shaders.properties/>

## 架构决策

- GLSL `#version 330 compatibility`
- 渲染路线：轻量 deferred（待定，待最终架构确定）
- 入口文件按维度分目录：`shaders/world0/`（主世界）等；入口不含逻辑，只做宏定义 + `#include` program 文件
- `shaders/program/` 位于根目录，全维度共享（`#include` 用绝对路径 `/program/...`）；program 文件按渲染阶段加前缀命名（如 `gbuffers_*`）
- varying 统一用 `VARYING` 宏声明（`lib/common.glsl` 中按阶段展开为 `in`/`out`），同一 varying 在 program 文件顶部只声明一次
- uniform 全部集中声明在 `lib/uniforms.glsl`，program 文件不自行声明
- 像素格式名称（`RGBA16`、`RGBA16F` 等）集中在 `lib/formats.glsl` 提前声明，供 `colortexNFormat` 常量指令引用
- 采样纹理统一命名 `tex`
- program 文件中 fsh 写在前半部分，vsh 写在后半部分，用 `#ifdef STAGE_FRAGMENT` / `#ifdef STAGE_VERTEX` 分隔
- 每个 program 的 fsh 段必须含 `/* DRAWBUFFERS:... */` 注释指定输出通道（OptiFine/Iris 在 `#include` 展开后扫描该注释）；该行前后不得有其他注释内容，独占一行；输出用 `layout(location = N)` 显式绑定，当前全部写 colortex0

## 当前状态

最小骨架：`world0/` 内含 20 个 gbuffers 入口（标准 18 + Iris 的 particles / lightning）。已启用：`gbuffers_terrain` → 同名 program（纹理 × 顶点色 + cutout 裁剪），`gbuffers_entities` → 同名 program（额外叠加 `entityColor`），`gbuffers_basic` → `gbuffers_color`（仅顶点色），`final` → `program/final.glsl`（采样 `colortex0` 直通输出；格式：`colortex0`/`colortex5` RGBA16F，`colortex4` RGBA16）；`gbuffers_textured` 暂无入口指向，留作共用基础程序；其余全部指向 `program/gbuffers_empty.glsl`（禁用）。

- 缺失的 program 沿回退链 fallback（如 `hand_water → hand → textured_lit`），禁用某阶段必须显式创建入口指向 gbuffers_empty
- 以下可选拆分**不创建文件**，靠回退链落到主 program：`terrain_solid/cutout → terrain`、`block_translucent → block`、`entities_translucent → entities`、`particles_translucent → particles`
- `entities_glowing` 仅 OptiFine 识别、Iris 不使用，不创建

其余结构待架构定稿后生成。
