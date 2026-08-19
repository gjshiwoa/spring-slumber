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
  - **当前为效果骨架**：光照 / 天空仍为扩展点（效果库已备好暂不接入）；颜色管线已定型——`deferred_init` 反 gamma 初始化线性 `colortex0`，前向半透明线性混合，`final` 单 pass 收尾（BSL / Complementary 同款合并、不占 composite 槽）：线性域 bloom 合成（`getBloom × BLOOM_STRENGTH` 相加）→ 乘自适应曝光 → AgX tonemap（春雷同款 minimal AgX，末段 pow 2.2 即「回到线性」，缓冲保持线性）→ gamma 矫正（`linearToSrgb`，全管线唯一离开线性空间的位置）；自动曝光已接入——亮度算法取春雷（bloom 图集最粗 tile 对数平均 + 0.18 key 直除 + 曝光域指数适应）、pass 设计取春v2（寄生上采样链末级 `composite_bloom_upsample`（composite12）测光、colortex7 曝光槽位 = 图集包围盒内单像素、写入区域透传保值、final 内 tonemap 前乘一次），`AGX_ADDITIVE`（春雷值 0.6）为 AgX 曲线预缩放、与曝光系数各司其职
  - TAA 已接入（24 包调研定档：单 pass、无速度缓冲的轻量实现，春雷 / 春v2 质量档 + 春v2 低配版 pass 结构，公式源 c13 / itrp）：全部 gbuffer 类 vsh 注入 Halton(2,3) 16 相位亚像素抖动（`lib/common/utils/jitter.glsl` 的 `applyTAAJitter`，查表纯 GLSL、不依赖 properties 自定义 uniform——旧版 OptiFine 兼容；gbuffers_empty / 全屏类不注入）；`composite_taa`（composite3，前向半透明全部完成后、bloom 链之前）单 pass 解析——depthtex0 取 3×3 最近片元锚点、矩阵链重投影上一帧（手部 NDC 深度 < 0.56 视为相机附着、相机位移清零），历史 colortex3 经 `catmullRom5` 内嵌锐化采样，Reinhard 域 + YCoCg 的 μ±γσ 方差钳制（保方向 clipAABB、γ 随深度置信自适应放宽），钳制 / 统计 / 混合在「线性色 × 上一帧自适应曝光」的归一化工作域进行、结果除回后输出与存储（春雷同思路——本管线曝光在 final 才应用，colortex0 原始值在暗景极小、tonemap 近似恒等且 σ 跌破 epsilon 地板会使钳制盒退化成不钳 → 低亮度拖影；composite3 读 colortex7 曝光槽位拿到的恰是上一帧适应值，vsh 取一次经 varying 传入，历史仍存未曝光线性值），当前帧权重 = 基础 0.05 + 速度项 + 解遮挡项（历史 a 通道存上帧最近片元线性深度做置信，itrp 同款打包位、不占新缓冲），出屏 / 首帧弃历史；bloom 图集与自动曝光测光自此吃抗锯齿后的稳定图像；性能四项（零画质损失）——纯天空像素早退（清除色恒定双写透传；**中心与十字邻域全无几何才早退**——判定顺便复用最近深度扫描的同一批样本，十字不含对角、仅对角有几何的单像素角点不受保护，c13 / Photon 同款取舍；轮廓边缘像素因 jitter 逐帧在天空 / 几何间翻转，须保留邻域锚点的全路径做时间累积，只看中心会致高对比轮廓闪烁爬行）、锚点观察空间位置单次重建（linearDepth 与重投影共用一组 mat4）、prevDepth 随 catmullRom5 的 a 通道一趟带回（免独立采样）、采样全部 textureLod 0；微损——方差统计与最近深度扫描均为十字 5-tap（各省 4 fetch；统计盒略粗由 γ 抬一档 1.5 / 2.25 补偿，深度扫描不含对角、仅对角有几何的角点不受保护，c13 / Photon 同款取舍）
  - 无阴影贴图：直射光用光照图 skyLight 门控近似遮挡（避免阳光穿墙）的方案已写在 `lib/lighting/lighting.glsl`；`shadow` 阶段留作扩展点
- 入口文件按维度分目录：`shaders/world0/`（主世界）等；入口不含逻辑，只做宏定义 + `#include` program 文件
- `shaders/program/` 位于根目录，全维度共享（`#include` 用绝对路径 `/program/...`）；program 文件按**「阶段_功能」**命名（前缀 = 渲染阶段，后缀 = 该程序在此阶段做的事，不跟入口名、不带序号）：`gbuffers_opaque` / `gbuffers_opaque_entities` / `gbuffers_color` / `gbuffers_color_textured` / `gbuffers_translucent` / `gbuffers_translucent_simple` / `gbuffers_empty` / `gbuffers_sky` / `gbuffers_sky_tex`；全屏类中 **deferred 阶段用于初始化**（`deferred_init`）、composite 系按功能命名（`composite_taa` / `composite_bloom` / `composite_bloom_upsample`，同一 program 由多个入口以宏区分级数时宏名写在入口，如 `BLOOM_LEVEL`；序号属于 world0 入口文件名，如 `composite12.fsh`），`final` 程序名保持不带功能后缀（收尾合并 pass：bloom 合成 / 曝光 / AgX / gamma）。world0 入口文件名是引擎阶段名、保持不变，只有 `#include` 指向变化
- varying 统一用 `VARYING` 宏声明（`lib/common/pipeline/varying_io.glsl` 中按阶段展开为 `in`/`out`），同一 varying 在 program 文件顶部只声明一次
- uniform 全部集中声明在 `lib/common/globals/uniforms.glsl`，program 文件不自行声明
- 常量全部集中声明在 `lib/common/globals/constants.glsl`（含缓冲格式 `colortexNFormat`、像素格式名称 `RGBA16`/`RGBA16F`、cutout 阈值、光照 / 天空颜色等）；OptiFine/Iris 扫描 include 展开后的内容
- **lib 文件之间不互相 include（无嵌套）**：依赖一律由 program 按需平铺引入；`constants.glsl` 须在 `pipeline/gbuffer_data.glsl` 之前（`remapLightmap` 依赖其常量），`sky.glsl` / `lighting.glsl` 所需的 uniforms / 常量同样由接入方先行 include
- 标识符命名避开 GLSL 保留字（`packed` / `filter` / `sample` / `input` / `output` 等）
- 采样纹理统一命名 `tex`
- program 文件中 fsh 写在前半部分，vsh 写在后半部分，用 `#ifdef STAGE_FRAGMENT` / `#ifdef STAGE_VERTEX` 分隔
- 每个 program 的 fsh 段必须含 `/* DRAWBUFFERS:... */` 注释指定输出通道（OptiFine/Iris 在 `#include` 展开后扫描该注释）；该行前后不得有其他注释内容，独占一行；**多个入口共享同一 program 且输出缓冲不同时（composite_bloom_upsample：composite9~11 写 `1`、composite12 写 `17`），DRAWBUFFERS 下放到各入口文件、program 文件不再携带**（免展开后出现两条注释）；输出用 `layout(location = N)` 显式绑定，location 按 DRAWBUFFERS 列表顺序编号；gbuffer 类程序写 `45` 两通道，deferred 之前的手动合成类写 `4`，deferred / composite / 前向 post-deferred 类写 `colortex0`（`composite_taa` 兼写 `03`：colortex3 TAA 历史；composite12 入口的 `composite_bloom_upsample` 兼写 `17`：colortex7 曝光槽位存自适应曝光、图集包围盒其余透传，输出声明与写入逻辑由 `#if BLOOM_LEVEL == 0` 宏门控、composite9~11 编译期不含）

## 缓冲布局

| 缓冲 | 格式 | 内容 | 写入者 |
|---|---|---|---|
| colortex0 | RGBA16F | 线性场景颜色（deferred_init 反 gamma 初始化；composite_taa 抗锯齿后即为终态——bloom 合成 / 曝光 / tonemap / gamma 全在 final 完成后直接输出屏幕、不写回；光照接入后为光照结果） | deferred_init → 前向类（线性混合）→ composite_taa → final（读） |
| colortex1 | R11F_G11F_B10F | bloom tile 图集：tile0 = 左上 1/4×1/4（屏幕 1/4 分辨率起步），tile1~4 右侧纵列堆叠边长 1/8~1/64，图集约占缓冲 10% 面积，tile 间隔 4 texel；无 alpha、无符号 11/11/10 浮点，较 RGBA16F 显存带宽减半（COD 核小负瓣写入钳 0，视觉无损） | composite_bloom（composite4~8 下采样）与 composite_bloom_upsample（composite9~12 上采样回卷，tile0 终态 = 合并后的完整泛光）写入 → final 消费 tile0（getBloom）、composite12 测光读 tile4，此后不再写入 |
| colortex3 | RGBA16F，clear = false | TAA 历史缓冲：rgb = 上帧混合色（线性 HDR），a = 上帧最近片元线性深度（解遮挡置信） | composite_taa（composite3）独占读写（DRAWBUFFERS:03 单程序 ping-pong，不依赖 flip.*） |
| colortex4 | RGBA16 | rg = 打包 albedo（tex × 顶点色，4x8→2x16），ba = 打包高光贴图 RGBA（4x8→2x16，labPBR） | gbuffer 类全量写入；textured / color 手动合成写入 rg |
| colortex5 | RGBA16 | rg = 八面体编码的观察空间法线（labPBR 贴图法线经导数 cotangent TBN 变换，无 normals 纹理时为导数几何法线），ba = 原始 lmcoord（读取端再重映射） | gbuffer 类 |
| colortex7 | RGBA16F，clear = false | 杂项数据缓冲：曝光槽位 1 texel（bloom 图集包围盒内 tile3/tile4 间隔，`exposureTexel()`）= 自适应曝光（r 通道，适应后曝光系数）；其余区域预留给天空盒纹理等杂项数据 | composite_bloom_upsample（composite12）槽位写入 / 图集包围盒其余透传 → composite_taa（composite3，钳制域归一化用上一帧值）与 final（应用本帧值）读取 |
| depthtex0 | - | deferred 时刻仅含不透明几何深度，`deferred_init` 用 `depth >= 1` 区分天空（待光照接入后启用）；composite 时刻含全部几何（半透明 + 手），composite_taa 取 3×3 最近片元做重投影锚点 | 引擎 |

- 位打包值粒度 1/65535，colortex4/5 必须是 16bit 无符号规范化格式（RGBA16），不可改为浮点格式
- **colortex7 槽位协议**（杂项缓冲，参考春v2 colortex7 实践）：曝光槽位 1 texel = 自适应曝光（`lib/post/exposure.glsl` 的 `exposureTexel()`，位于 bloom 图集包围盒内 tile3/tile4 间隔——写入者 composite12 只光栅化图集包围盒，槽位在包围盒内才能随链写入、无需为测光单开全屏 pass），天空盒等后续数据自分区槽位、单像素槽集中写成常量函数；任何 colortex7 写入者必须**透传其光栅化区域内不属于自己的槽位**（同位置 texelFetch 读回写回，写入区域整写、不可 discard——discard 连座丢弃全部附件）——内容随每次写入复制到另一块 surface，全部槽位跨帧、跨 main/alt 翻转存活（包围盒外区域无人写入亦无人读取，两块 surface 交替持有旧帧内容无碍），`colortex7Clear = false` 恒定，禁止依赖 `flip.*`

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
| 全屏 | `composite_taa` | composite3 | TAA 解析：gbuffer vsh 已注入 Halton 16 相位抖动（jitter.glsl），本 pass 读抖动后线性 colortex0 + depthtex0 十字最近片元锚点，矩阵链重投影采 colortex3 历史（catmullRom5 内嵌锐化），乘上一帧自适应曝光归一化（vsh 槽位取一次经 varying 传入，防低亮度钳制失效拖影）后做 Reinhard+YCoCg 方差钳制 + 速度 / 解遮挡自适应混合、除回曝光写回 colortex0，混合色 + 本帧锚点线性深度写 colortex3 历史；位于前向半透明全部完成后、bloom 链之前 |
| 全屏 | `composite_bloom` | composite4~8 | bloom 链式下采样金字塔 1/4~1/64 分辨率（BLOOM_LEVEL 0~4 由入口宏定义，c13 同款 1/4 起步）：tile < 本级的像素复制回写、tile = 本级的从上一级（或 colortex0）做 13-tap 高斯下采样（COD AW 核，春雷快速路径同款）写 colortex1 图集、其余 discard；vsh 把 quad 压缩到 tiles 0~本级包围盒只光栅化图集区域；无阈值，整幅 HDR 进金字塔 |
| 全屏 | `composite_bloom_upsample` | composite9~12 | bloom 渐进上采样回卷（BLOOM_LEVEL = 目标 tile 3~0 由入口宏定义，自粗向细）：tile k = 本级原始内容 × 级权重 + 上一 pass 已合并 tile k+1 的 4-tap tent 放大 2 倍相加（COD AW 式金字塔），粗级模糊经逐级 tent 累积成连续衰减——消除单次大倍率双线性放大的菱形网格与离散半径直接叠加的环状过渡（网格感 / 空隙感）；包围盒内非 tile 像素同样复制回写（不 discard——见 composite12 的 colortex7 整写），tile4 恒为原始下采样内容供 composite12 测光；vsh quad 压缩到全图集包围盒；链末级（BLOOM_LEVEL 0，composite12）兼自动曝光寄生存储（春v2 同款，不新增 pass、DRAWBUFFERS 17）——colortex7 曝光槽位（图集包围盒内 tile3/tile4 间隔）测 tile4 对数平均亮度（春雷算法；tile4 自 composite8 终态后只被复制回写，本 pass 读到的即最终内容、无同 pass 竞争）、与上一帧曝光指数平滑写回，其余像素 colortex7 同位置读回透传 |
| 全屏 | `final` | final | 收尾单 pass（BSL / Complementary 的 final 同款合并，不占 composite 槽）：读线性 colortex0（composite_taa 后、未曝光）+ colortex1 tile0（`getBloom` 4-tap tent 放大 4 倍、除以权重和归一）tonemap 前线性域合成（× `BLOOM_STRENGTH` 相加）→ 乘 colortex7 曝光槽位的自适应曝光（vsh 取一次经 varying 传入，免每像素对槽位 texelFetch）→ AgX tonemap（lib/post/tonemap.glsl）→ gamma 矫正（`linearToSrgb`，pow 1/2.2）输出到屏幕；全管线唯一离开线性空间的位置；原 composite13（bloom 合成）/ composite14（tonemap）两个全屏 pass 的 colortex0 读写往返与 colortex7 全屏透传（合计约 46B/px@1080p ≈ 95MB/帧）由此消除 |

- `program/gbuffers_sky.glsl`、`program/gbuffers_sky_tex.glsl` 已备好未链接（原版直通版本，对应 skybasic / skytextured 入口），重新启用天空时把入口指回即可
- `program/gbuffers_color_textured.glsl`（春雷式手动合成版本）已备好未链接，textured 族需要回退打包路线时把入口指回即可
- **composite 编号约定**：deferred / composite 编号不超过 14；composite3 = TAA（bloom 链之前的最后一级前置效果），composite4~8 = bloom 下采样链，composite9~12 = bloom 上采样回卷链（composite12 兼曝光槽位写入），composite13 / composite14 空出（原 bloom 合并 / tonemap 已并入 final，曾各占一席）；composite0~2 预留给 TAA 之前的效果（新效果从 2 往前排），13 / 14 留给 bloom 链之后的效果——需要 TAA 与 bloom 链**之间**的槽位（如 DOF / 运动模糊）时把 TAA 挪到 composite2 腾出 composite3 即可（一处入口改名）

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
- `filters.glsl`：通用采样 / 滤波工具（`textureNice` 平滑双线性、`tentFilter4` 4-tap 对角 tent 上采样核、`downsample13Tap` COD AW 下采样核、`catmullRom5` 5-tap 锐化 Catmull-Rom 重采样（春v2 同款，TAA 历史采样用，锐度并入重采样免单独锐化 pass；返回 **rgba 全通道**——a = 上帧深度随同一组权重一趟带回，tap 全部显式 Lod0），对应春雷 filters.glsl）——函数全部显式传参，无 uniforms / 常量依赖，任何 program 可直接引入
- `space.glsl`：坐标空间构造——导数 cotangent frame（`calculateTBN` / `calculateGeomNormal`，春雷 utils/space.glsl 同位，仅片段阶段）
- `packing.glsl`：数据打包 / 编码——位打包（`pack4x8To2x16` / `unpack2x16To4x8` 等）+ 八面体映射（`encodeOctahedral` / `decodeOctahedral`，单位向量 ↔ 二维 [0,1]，不限法线用途），与春雷 packing.glsl 同文件组织
- `jitter.glsl`：TAA 亚像素抖动注入——`taaJitterSample` / `taaJitterUV`（像素 / uv 域取值）、`applyTAAJitter`（vsh clip 空间平移，乘 w 保透视）、`applyJitter` / `applyInverseJitter`（uv 域补偿对，未来 SSR / SSAO 屏幕坐标去抖用，春雷同款）；Halton(2,3) 16 相位表集中存 constants.glsl；依赖先行 include `constants.glsl` / `uniforms.glsl`

**lib/atmosphere/**（大气 / 天空）

- `sky.glsl`：天空颜色（昼夜 / 黄昏 / 雨天渐变）——**已备好，暂不接入**；依赖先行 include `uniforms.glsl` / `constants.glsl`

**lib/lighting/**（光照）

- `lighting.glsl`：`shadeSurface` 光照主入口（deferred 与前向共用）——**已备好，暂不接入**；依赖先行 include `uniforms.glsl` / `constants.glsl` / `atmosphere/sky.glsl`

**lib/post/**（后处理）

- `bloom.glsl`：bloom tile 图集布局（`bloomTileRect`，金字塔 1/4~1/64 分辨率、c13 同款 1/4 起步）、链式下采样（`bloomDownsampleTile`，调用 filters.glsl 的 `downsample13Tap`，tap 步长 `BLOOM_BLUR_STEP` 源纹素）、渐进上采样回卷（`bloomUpsampleTile`，本级原始内容 × 级权重 + 已合并粗级经 `tentFilter4` 放大 2 倍相加，COD AW 式金字塔回卷）、合并入口（`getBloom`，只读回卷后的 tile0、tent 放大 4 倍、除以权重和 3.0 归一）——**已接入** `composite_bloom` / `composite_bloom_upsample` / `final`；矩形计算用 `textureSize` 运行时推导、不假设缓冲分辨率（不依赖 size.buffer，低版本 OptiFine 兼容）；性能取舍——下采样 13-tap、上采样 tent 4-tap、回卷链 pass 只光栅化图集包围盒（~10% 屏幕）、vsh quad 压缩、final 合并仅 4 tap（旧版 5 tile 各自直接放大 4~64 倍为 5 tap，且最粗 tile 的 64 倍单双线性产生菱形网格、离散半径叠加产生环状过渡——回卷结构用 4 个廉价小 pass 换掉全屏多采样，质量根治且总算力更低）；依赖先行 include `constants.glsl` / `uniforms.glsl` / `filters.glsl`
- `tonemap.glsl`：AgX tonemap（春雷同款 minimal AgX，`agx` 入口）——**已接入** `final`（bloom 合成、乘曝光之后）；末段 pow 2.2 为「回到线性」，输出仍线性；依赖先行 include `constants.glsl`
- `exposure.glsl`：自动曝光（亮度算法春雷同值、pass 设计春v2 同款）——`exposureTexel` colortex7 曝光槽位（bloom 图集包围盒内 tile3/tile4 间隔 texel，`bloomTileRect` 运行时推导、不假设缓冲分辨率；写入端 composite12 与读取端共用本函数、位置恒一致）、`sceneAverageLuminance` bloom 图集最粗 tile（tile4）上固定 16 点均匀抖动采样核（`EXPOSURE_SAMPLE_KERNEL`，4×4 每单元一个随机点）对数平均、`targetExposure` 0.18 key 直除、`adaptedExposure` 曝光域指数平滑（帧率无关、首帧守卫）、`readAdaptedExposure` 读取端——**已接入** `composite_bloom_upsample`（composite12 槽位测光写入）/ `composite_taa`（钳制域归一化乘上一帧值）/ `final`（tonemap 前乘一次）；采样规模与春v2 的 16 点盘采样同档（tile4 内容极低频，估计均值充分），测光成本与分辨率解耦、固定核帧间稳定；测光含天空像素（与两家参考一致）；依赖先行 include `constants.glsl` / `uniforms.glsl` / `bloom.glsl` / `color.glsl`（rgbToLuma）
- `taa.glsl`：TAA 解析核心——`closestDepthCross`（depthtex0 十字 5-tap 最近片元锚点，c13 closestToCamera5taps / Photon get_closest_fragment 同形，越界钳回边缘，中心深度由调用方传入；天空早退顺便复用同批样本判定）、`screenToView` / `reprojectViewToPreviousUV`（当前帧逆推世界 + 相机增量 + 上帧正推的通用矩阵链，手部相机附着处理；viewPos 入参、与 linearDepth 共用一次重建）、钳制域工具（`taaTonemap` / `taaInverseTonemap` Reinhard 压缩 + `rgbToYCoCg` / `yCoCgToRgb`）、`clipHistoryToNeighborhood`（十字 5-tap μ/σ 方差钳制，保方向截到盒面，γ 抬一档补偿盒粗化；盒 Y 通道戴 `TAA_TONEMAP_DOMAIN_MAX` 0.995 上界帽——高对比边缘 μ+γσ 可越出 1，落点 Y>1 会使逆变换分母变负、被 epsilon 地板放大 1e5 倍致边缘极亮爆闪）、`resolveTAA` 主入口（速度作用在当前像素坐标——`uv − velocity`，锚点只提供位移量，c13 / 春v2 同款；**曝光归一化工作域**——统计 / 钳制 / 混合乘上一帧自适应曝光（调用方经 varying 传参）、结果除回，防低亮度 σ 跌破 epsilon 地板致钳制失效拖影（春雷同思路）；速度 / 解遮挡自适应混合、出屏与首帧守卫、历史 a 通道线性深度置信、纯天空像素早退——中心与十字邻域全无几何才双写透传（轮廓边缘像素走邻域锚点全路径防闪烁爬行）、历史 a 写 `TAA_DEPTH_SENTINEL` 哨兵，天空接入后改为相机旋转速度路径）——**已接入** `composite_taa`；春雷 + 春v2 的合体精简（速度就地重投影不建速度缓冲、历史 a 打包深度置信取 itrp）；性能：非天空最坏 16 fetch（1 当前 + 5 深度 + 5 统计 + 5 历史）、天空内部 6 fetch（5 深度 + 1 颜色）；依赖先行 include `constants.glsl` / `uniforms.glsl` / `filters.glsl`（catmullRom5），当前帧 jitter 补偿量由调用方传参（composite_taa 经 varying）

## 当前状态

效果骨架：gbuffer 只写 colortex4/5（春雷式位打包，albedo 存原始 sRGB），`deferred_init` 解包 colortex4 反 gamma 初始化线性 colortex0；前向半透明（water / hand_water / weather / textured 族）线性混合进 colortex0；`composite_taa`（composite3）对抖动后的 colortex0 做 TAA 解析（gbuffer vsh 已注入 Halton 16 相位抖动；重投影采 colortex3 历史 + 方差钳制 + 速度 / 解遮挡置信混合，写回 colortex0、混合色与锚点线性深度存 colortex3 供下帧）；`composite_bloom`（composite4~8）下采样生成 bloom tile 图集，`composite_bloom_upsample`（composite9~12）自粗向细回卷把全部级合并进 tile0，链末级 composite12 兼在 colortex7 曝光槽位做自动曝光测光与时间适应（槽位写入、图集包围盒其余透传）；`final` 单 pass 完成 bloom 合成（tile0 tent 放大 × `BLOOM_STRENGTH` 相加）→ 乘自适应曝光 → AgX tonemap → gamma 矫正输出屏幕。无光照 / 天空。天空入口（skybasic / skytextured）链接到空程序，天空像素显示清除色经 tonemap / gamma 管线后的结果。

已知限制（均为后续扩展点）：

- 几何法线不单独存储：已随导数 TBN 并入 colortex5 的观察空间法线（无 normal 贴图像素即几何法线，但有贴图法线的像素无法还原几何法线）；光照若需二者分离（如天空环境光半球 / 湿地面混合），参考春雷 normalOV 单独存通道
- 手动合成类程序（color、beacon 外壳分支；`gbuffers_color_textured` 手动合成版当前未链接）读取正在写入的 colortex4（beacon 外壳还读 colortex5）（texelFetch 当前附件，春雷同款做法），个别驱动上属于未定义行为；高光 ba 通道在混合处随 alpha 衰减；composite12 的 colortex7 包围盒透传同款（读正在写的附件）
- 光照：`deferred_init` 读 colortex4/5 + depthtex0 计算后写回；`gbuffers_translucent` 前向共享 `lib/lighting/lighting.glsl`
- 天空：`gbuffers_sky` 接入 `lib/atmosphere/sky.glsl` 程序化渐变
- 自动曝光：已接入（春雷亮度算法：tile4 对数平均 + 0.18 key 直除 + 曝光域指数适应；春v2 pass 设计：寄生 bloom 链、colortex7 曝光槽位 = 图集包围盒内单像素、写入区域整写透传 + clear=false 跨帧保值、final 内 tonemap 前乘一次）。测光含天空像素（与春雷 / 春v2 一致），当前天空为清除色 0，大面积天空入画会把 avgLum 拉向 `AUTO_EXPOSURE_MIN_LUMINANCE`、曝光明显偏高（地面近过曝），天空接入后自然恢复；骨架期如需画面正常可临时收紧 `targetExposure` 上限（如 4.0）。RGBA16F 半精度下曝光实际被 MIN_LUMINANCE 约束在 ≤ 720，无溢出；适应步长（RATE 2.0 下 60fps 每帧约 3%）远大于半精度 0.1% 量化步长，无卡顿风险。colortex7 槽位已移入图集包围盒由 composite12 随链写入（测光源保持 tile4：该 pass 读 colortex1 为上一 pass 终态、tile4 无同 pass 竞争），全屏透传成本归零；未来天空盒等杂项数据进 colortex7 时沿槽位协议自分区即可
- TAA：已接入（composite3 单 pass，无速度缓冲）。已知取舍——动态实体无逐物体速度（22 个参考包同款：纯相机重投影，实体自身运动靠方差钳制收敛，未来需要时在 gbuffer 加速度通道）；水面波动逐帧变化、重投影为近似（与参考一致）；十字锚定不含对角（仅对角有几何的单像素角点可能轻微闪烁，c13 / Photon 同款）；天空走零速度全量累积分支（当前清除色恒定故稳定，天空接入后改为相机旋转速度）；手部仅「相机附着 + 权重下限抬高」近似（BSL / Photon 同取舍）；粒子已知限制不变（textured 族 deferred 前写入仍被覆盖）
- 无 shadow 阶段：阴影贴图 + PCF 可直接加在 `deferred_init` 内（gbuffer 已有法线与深度）
- 无雾 / 水下效果：可在 `deferred_init` 与前向程序里基于视距混合 `getSkyColor`
- composite 编号已用：3（TAA）、4~8（bloom 下采样链）、9~12（bloom 上采样回卷链，12 兼曝光槽位）；0~2、13 / 14 预留（bloom 合成与 tonemap 原占 13 / 14，已并入 final）
- bloom 无阈值（与春雷 / 春 v2 / BSL 等全部参考一致）：整幅 HDR 直接进金字塔，靠亮度自然衰减；当前无光照画面整体呈轻微柔光属预期，光照接入后 HDR 值自动分层；如需阈值可在 `bloomDownsampleTile` 的 k = 0 分支加 soft knee
- bloom 链（下采样与上采样回卷）每个 pass 重写自己需要的全部 tile（本 pass 不重算的 tile 复制回写）：跨 pass 保值对 OptiFine / Iris 的 main/alt 缓冲翻转语义免疫，无需 `flip.*` 配置（春雷靠 `flip.*=false` 累积图集的做法依赖引擎语义细节，本方案规避）；colortex1 为全尺寸缓冲仅图集区域被采样（不用 `size.buffer`，低版本 OptiFine 不支持），已降级 `R11F_G11F_B10F`（无 alpha、无符号 11/11/10 浮点）：显存与带宽减半，COD 下采样核的小负瓣写入时钳 0，bloom 视觉无损
- 半透明实体 / 半透明方块实体（Iris 的 `entities_translucent` / `block_translucent`）沿回退链落到 `entities` / `block` 程序；其引擎混合已随主程序关闭（不再串扰），透明部分暂按不透明写入，正确的半透明表现留待后续显式处理
- textured / textured_lit / particles / lightning（particles 无入口经 textured_lit 回退，lightning 入口已删除经 textured 回退）改走前向后仍在 deferred 之前绘制，写入的 colortex0 会被 deferred 全屏覆盖（这些几何暂不可见），待后续处理：Iris 可设 `particles.ordering` 调整粒子时机，或 textured 族改回手动合成路线（`program/gbuffers_color_textured.glsl`）
