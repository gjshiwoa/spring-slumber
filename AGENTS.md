# AGENTS.md

## 项目简介

「春眠」是一个 Minecraft 光影包（shaderpack），适用于 OptiFine / Iris。

**定位**：低配 / 高兼容性，不使用激进的渲染特性。

## 参考文档

- Shader 开发文档：<https://shaders.properties/>

## 架构决策

### 总路线与文件组织

- GLSL `#version 330 compatibility`
- **轻量 deferred**（已定稿）：不透明几何在 gbuffers 写 gbuffer（MRT 两张 `colortex4/5`，不写 colortex0/1），`deferred_init` 解包 albedo、反 gamma（`srgbToLinear`）后初始化线性 `colortex0`
- 入口文件按维度分目录（`shaders/world0/` = 主世界）；入口不含逻辑，只做宏定义 + `#include`；`shaders/program/` 全维度共享（`#include` 绝对路径 `/program/...`）；world0 入口文件名 = 引擎阶段名、保持不变，只有 `#include` 指向变化
- program 按**「阶段_功能」**命名（前缀 = 渲染阶段，后缀 = 该程序做的事，不跟入口名、不带序号）；同一 program 由多入口以宏区分级数时，宏名写在入口（如 `BLOOM_LEVEL`）；序号属于 world0 入口文件名（如 `composite12.fsh`）；`final` 不带功能后缀（收尾合并 pass）；另有非链接的共享顶点着色器 `fullscreen_vsh`
- 缺失的 program 沿回退链 fallback（如 `hand_water → hand → textured_lit`）；禁用某阶段必须显式创建入口指向 `gbuffers_empty`
- 以下入口**不创建文件**、靠回退链落到主 program：`terrain_solid/cutout → terrain`、`block_translucent → block`、`entities_translucent → entities`、`line → basic`、`particles / particles_translucent → textured_lit`、`lightning → textured`；`entities_glowing` 仅 OptiFine 识别、不创建

### 代码约定

- varying 统一用 `VARYING` 宏声明（`varying_io.glsl` 按阶段展开为 `in`/`out`），同一 varying 在 program 顶部只声明一次；例外——通用全屏 vsh 的帧数据 varying：vsh 侧集中 `out`、各 fsh 按需 `in`（同名匹配链接，未声明的由链接器剔除、零成本）
- uniform 全部集中在 `lib/common/globals/uniforms.glsl`，常量全部集中在 `lib/common/globals/constants.glsl`（含缓冲格式 `colortexNFormat`、cutout 阈值、`MATERIAL_*` / `PLANT_*` / `BLOCK_*`、光照 / 天空 / TAA / bloom 参数等）；OptiFine/Iris 扫描 include 展开后的内容
- **lib 文件之间不互相 include（无嵌套）**：依赖由 program 按需平铺引入；`constants.glsl` 须在 `pipeline/gbuffer_data.glsl` 之前（`remapLightmap` 依赖常量）；`sky.glsl` / `lighting.glsl` 等所需的 uniforms / 常量同样由接入方先行 include（各 lib 文件头注明依赖）
- 标识符避开 GLSL 保留字（`packed` / `filter` / `sample` / `input` / `output` 等）；采样纹理统一命名 `tex`
- program 文件 fsh 在前、vsh 在后，`#ifdef STAGE_FRAGMENT` / `#ifdef STAGE_VERTEX` 分隔；带 gsh 的 program 另加 `#ifdef STAGE_GEOMETRY` 段（见「物品标记」）；使用通用全屏 vsh 的 program 无 vsh 段
- fsh 段必须含 `/* DRAWBUFFERS:... */` 注释（引擎在 include 展开后扫描），独占一行、前后不得有其他注释；多入口共享 program 且输出不同时（`composite_bloom_upsample`：composite9~11 写 `1`、composite12 写 `17`）DRAWBUFFERS 下放到入口文件；输出用 `layout(location = N)` 显式绑定，location 按 DRAWBUFFERS 顺序。常规取值：gbuffer 类 `45`、手动合成类 `4`、deferred / composite / post-deferred 类 `0`（`composite_taa` 兼写 `03`、composite12 入口兼写 `17` 由 `#if BLOOM_LEVEL == 0` 门控）、shadow 阶段 `0`（= shadowcolor0）

### gbuffer 打包与物品标记

- 春雷式位打包（`pack4x8To2x16`）：colortex4.rg = albedo RGBA、colortex4.ba = 高光贴图 RGBA（labPBR）、colortex5.rg = 八面体观察空间法线、colortex5.ba = 原始 lmcoord（重映射 `remapLightmap` 移到读取端）
- **物品标记占 albedo 的 a 通道**（texcolor 的 a 在 cutout 判定后职责已尽，8bit 槽位复用；读取端 `unpack2x16To4x8(...).a × 255` 判定）：`MATERIAL_NONE` = 0 / `MATERIAL_VEGETATION` = 251 / `MATERIAL_SOLID` = 252（显式排除，SSS 取 0；253~255 预留）。当前唯一显式映射：草方块 `shaders/block.properties` 定义 `block.10001=minecraft:grass_block`，ID 与 constants.glsl 的 `BLOCK_GRASS_BLOCK` **成对维护、两端同步**
- 植被为 **terrain 入口专属 gsh 程序化判定**（春雷 `isLikelyPlantTriangle`：三角形几何法线「垂直交叉面片」× 顶点色「生物群系染色」chroma 两信号取或），按 per-triangle 分类经 flat varying `vMaterialID` 下传、fsh 写入 a 通道；vsh 先经 `mc_Entity.x` 写显式标记（草方块 → `MATERIAL_SOLID`，压制其染色顶面误报；block / hand 入口 mc_Entity 无引擎填充、回落空标记），gsh 仅空标记时兜底
- gsh 挂接机制（GLSL 单命名空间、in/out 不得同名）：terrain 入口额外定义 `OPAQUE_GSH`，program vsh 编译侧据此把输出 varying 挂 `vGsh` 前缀给 gsh、gsh 输出还原原名衔接 fsh；block / hand 不定义该宏、无 gsh，vsh 原名直连零成本
- texcolor 经半透明混合的程序（entityColor 的 entities、手动合成的 beacon 外壳 / color / color_textured）混合只作用 rgb，**标记不参与混合、a 通道整像素置 `MATERIAL_NONE`**；不写 colortex4/5 的 pass 与标记无关

### 法线

- 不用 `at_tangent`：vsh 传观察空间位置 varying，fsh 用屏幕导数构造 cotangent frame TBN（`calculateTBN`——导数入参，构造本身不含 dFdx/dFdy；**导数必须先于 discard 集中求好**，discard 后 quad 内幸存像素导数未定义；TBN 构造与 normals 采样推迟到 discard 后，被剔除 texel 免开销）
- labPBR 贴图法线 `*2-1`（不翻 Y）左乘 TBN 到观察空间、八面体编码输出；无 normals 纹理时贴图为 (0.5, 0.5, 1.0)、结果即导数几何法线——读取端拿到的始终是观察空间法线

### 绘制时机与引擎混合

- OptiFine/Iris 默认顺序：仅 `weather` / `water` / `hand_water` 在 deferred 之后。deferred 之前的不透明几何写 gbuffer 延迟光照；前向半透明保留引擎混合、按 alpha 混合写线性 `colortex0`（框架阶段直接输出 `srgbToLinear` 的 tex 色），分两档：
  - **完整处理** `gbuffers_translucent`（water）：扩展点共享 `shadeSurface`、雾 / 水面效果
  - **简单处理** `gbuffers_translucent_simple`（hand_water / weather / textured / textured_lit，particles 经回退）：扩展点为光照图轻量着色 / 雾，不接全量光照；textured 族在 deferred 之前绘制、写 colortex0 会被 deferred 全屏覆盖（见已知限制）
- 信标光柱 `beaconbeam`（`gbuffers_beacon`，参考春雷）：按 alpha 分支——不透明核心（a ≥ `ALPHA_BEACON_CORE`）整像素写 gbuffer（自发光 `BEACON_CORE_EMISSIVE` 写入 specular.a、lm = 0、导数几何法线）；半透明外壳手动合成进 colortex4.rg、背景 specular 与 colortex5 读回写回
- 春雷式手动合成备选 `gbuffers_color_textured`（关引擎混合、着色器内采样重打包进 colortex4.rg、不写 colortex5）备好未链接，textured 族需要回退打包路线时把入口指回即可
- shaders.properties 只对**已存在的入口**直接 `blend.* = off`：`terrain / block / hand / entities`（打包 gbuffer 整像素覆盖）、`basic`（手动合成）、`beaconbeam`（核心整像素写 + 外壳手动合成）；`water / hand_water / weather / textured / textured_lit` 保留引擎混合；lightning 入口已删除（落到 textured）；未创建的拆分入口不列（Iris 按阶段名匹配混合配置、不随回退链继承，OptiFine 忽略未知阶段名）

### 天空（sky-view LUT）

- `deferred_init` 天空分支（depth ≥ 1，取 depthtex1）采样 colortex7 sky-view LUT（`lib/atmosphere/sky.glsl` 的 `getSkyColor`）：太阳 / 月亮双光源各 200×100 半区、Hillaire 非线性参数化（纹素向地平线与光源侧集中）、采样端两半区和式
- LUT 由 composite12 每帧重算（Chapman 解析大气 + 各向同性环境场多次散射，`lib/atmosphere/`；月亮辐照度 = 太阳 × 1/2000；合计 ≈ 2% 屏幕成本）。多次散射 = 一阶天光球面 48 节点光源锚定环带求积 × 截获比几何级数 1/(1−ρ) 的最低档近似，vsh 每帧每光源一次经 varying 传入
- 非活动半区（光源低于 `SKY_LIGHT_MIN_HEIGHT`）生成端整区写 0、采样端以**同一常量**门控跳过 fetch——安全不变式「采样端跳过区域 ⊆ 生成端写黑区域」由两侧共用常量结构性保证，改动阈值须两端联动（阈值深居散射死区，隔帧光源移动的边界差不可见）
- 采样位置随当前帧 TAA jitter 亚像素偏移（与几何抖动同相位），composite_taa 时间累积平滑 LUT 双线性 facets 与地平线几何边界；LUT 内容滞后一帧无视觉差异；有效性由 vsh 探针判定（无效即首帧 / 缓冲重建，回退轻量天空）
- 日月星盘未画（skybasic / skytextured 指向 gbuffers_empty 禁用，天空由 deferred_init 按深度补画）；`gbuffers_sky` / `gbuffers_sky_tex` 原版直通版备好未链接，需要时把入口指回

### 颜色管线与收尾

- 线性域贯穿：`deferred_init` 反 gamma 初始化线性 colortex0 → 前向半透明线性混合 → `final` 单 pass 收尾（不占 composite 槽）：bloom 线性域合成（`getBloom × BLOOM_STRENGTH` 相加）→ 乘自适应曝光 → AgX tonemap（末段 pow 2.2 仍线性）→ gamma 矫正（`linearToSrgb`，**全管线唯一离开线性空间的位置**）输出屏幕、不写回
- 自动曝光（已接入）：亮度算法取春雷——bloom 图集最粗 tile4 对数平均 + 0.18 key 直除 + 基础亮度地板 `AUTO_EXPOSURE_BASE_LUMINANCE`（avgLum 先抬下限再直除，曝光上限 = KEY / 0.01 = 18，深夜 / 暗室不被拉成白天）+ 曝光域指数适应；pass 设计取春v2——寄生 composite12 测光、colortex7 曝光槽位单 texel、写入区域透传保值、final 内 tonemap 前乘一次；`AGX_ADDITIVE`（0.6）为 AgX 曲线预缩放、与曝光系数各司其职

### TAA（composite3 单 pass，无速度缓冲）

- 全部 gbuffer 类 vsh 注入 Halton(2,3) 32 相位亚像素抖动（`applyTAAJitter`，查表纯 GLSL、不依赖 properties 自定义 uniform；gbuffers_empty / 全屏类不注入）
- 解析（`lib/post/taa.glsl` 的 `resolveTAA`）：depthtex0 十字最近片元锚点、矩阵链重投影上一帧（手部 NDC 深度 < 0.56 视为相机附着、相机增量清零），历史 colortex3 经 `catmullRom5` 内嵌锐化采样，Reinhard 域 + YCoCg 的 μ±γσ 方差钳制（保方向 clipAABB、γ 随深度置信自适应放宽；钳制函数顺带输出 Karis「距盒边距离」），出屏 / 首帧弃历史；当前帧权重混合链（顺序参照 Photon：地板先立、门控后压）= ① 基础（原生 0.05 / TAAU 0.12）+ 速度项 + 解遮挡项，地板 0.02 / 手部 0.1（历史 a 通道存上帧最近片元线性深度做置信，不占新缓冲）→ ② TAAU 置信度门控（UE 最大核权重法 `catmullConfidence`，角点插值降权、Kappa 1 / Photon 5 取 2）→ ③ Karis 距离防闪（历史稳居钳制盒内 → 当前帧权重压向 0，静止细节零注入不闪；被截归零正常收敛，Kappa / Photon 同款）→ ④ 偏心拒绝（Zombye 0.25：重投影落点偏离历史纹素中心 = 有运动时抬当前帧权，削运动糊；静止恒等、原生档同受益）
- **钳制 / 统计 / 混合在「线性色 × 上一帧自适应曝光」工作域**进行、结果除回（本管线曝光在 final 才应用，colortex0 暗景原始值极小、σ 跌破 epsilon 地板会使钳制盒退化致拖影；composite3 读槽位恰为上帧适应值，vsh 取一次经 varying 传入）
- **天空与几何同路径、吃满时间过滤（无早退）**：天空锚点走无穷远方向仅旋转链（`viewDirectionToPreviousScreen`），线性深度取 `TAA_DEPTH_SENTINEL` 哨兵进同一置信公式（天空↔天空满置信、天空↔几何自然归零）；轮廓边缘像素因 jitter 在天空 / 几何间翻转，由最近片元锚点邻域膨胀落到几何路径防闪烁
- 性能：锚点位置单次重建、prevDepth 随 catmullRom5 a 通道一趟带回、采样全 textureLod 0；方差统计与深度扫描均十字 5-tap（统计盒略粗由 γ 抬一档 1.5 / 2.25 补偿；不含对角——仅对角有几何的角点不受保护，c13 / Photon 同款取舍）；最坏 16 fetch（TAAU 下 20）

### TAAU 时域上采样（默认开，S = 0.5）

- 机制 = c13 / Bliss 的「裁剪空间子区域缩放」+ Photon / Kappa 的「TAA pass 即上采样器」：gbuffers 与 deferred_init 渲染进全屏 buffer 左下 `[0,S]×[0,S]` 子区域（`applyTAAJitter` 内先 `xy·S + (S−1)·w` 缩放再叠 jitter，6 个 gbuffer 入口共用单函数、调用点零改动；**jitter 在子区域缩放之后的 NDC 域注入 → 有效位移恒为 ±0.5 渲染纹素**、与 S 无关，c13 / Kappa / Photon 三家同语义；terrain gsh 原样透传 gl_Position；shadow 阶段不走该函数、天然不缩放），几何 / 光照 / 前向半透明像素成本 ×S²（顶点不变）
- `composite_taa` quad 保持全屏、本 pass 即上采样器：深度 / 统计十字换算为渲染域纹素 `renderPixel`（目标像素 x 的锚点在渲染纹素 x·S 处，`closestDepthCross` / `clipHistoryToNeighborhood` 的 resolution 显式参数化；重投影链走 `closest.xy`、与 prevUv 数值域一致直接相减）；当前帧由单点采样换 `catmullRom5` 上采样，采样 uv = `uv·S + jitterUV` **全额去抖**（Kappa / Photon 同款；补偿必须在 buffer 纹素域等量施加——旧式 `(uv + jitterUV·0.5)·S` 把补偿一并乘 S，S=0.5 时只剩 1/4、每帧相位错位 ~0.375 渲染纹素，是 TAAU 糊 + 闪的主因；c13 取半抖偏软、AA 信息改由各相位重建差异经时间累积提供；**texSize 传纹理真实尺寸**——误传渲染分辨率会退化为全屏域恒等映射采到旧帧残留），与全屏目标分辨率历史（colortex3）混合后写回——colortex0 / 3 恢复全屏，**bloom 链 / composite12 / final 零适配**（buffer 坐标域的槽位与 LUT 不受缩放影响）；原生档（TAAU 关）保持半抖采样、逐位不变
- **子区域外片元剔除**：GPU 多边形裁剪按全屏 NDC、不知子区域边界，视锥外近带（NDC ∈ [1, 2/S−1]，缩放式 NDC' = NDC·S + S−1 在 NDC' = 1 处的反解上限；负侧贴齐 −1 无对应带）几何缩放后落进子区域外白跑 fsh；`noise.glsl` 的 `outsideRenderRegion()`（kappa / photon / FSR2 三家同款，ceil+1 texel 容差）在全部 6 个 gbuffer 程序 fsh 的**集中导数之后、一切纹理采样之前** discard（与 cutout discard 同一纪律）；纯性能剔除，正确性由读端钳边免疫
- deferred_init 的 quad 经 `FULLSCREEN_RENDER_REGION` 宏（world0/deferred 入口 vsh 定义）缩进同一子区域，fsh 去抖 uv 基底一步合成 `(像素 uv − vJitter) / S` 归一视场全域
- 常量集中在 constants.glsl TAAU 分区（`RENDER_SCALE` / `TAAU_UPSAMPLE_SHARPNESS` / `TAAU_BLEND_BASE` / `TAAU_CONFIDENCE_POWER`，锐度按 c13 公式 `2.0−S−S` 取值：S=0.75 → 0.5、S=0.5 → 1.0，改 RENDER_SCALE 时同步）；预处理 `#if` 不支持浮点比较，开关宏 `TAAU` 与数值常量分离；全额去抖 + 置信度门控 + Karis 防闪 + 32 相位修复后 S=0.5 可用（仍嫌软回 0.75），<0.5 不建议（目标像素网格更稀、上采样核欠采样）
- 性能：composite3 当前帧 1 → 5 fetch（全 pass 最坏 16 → 20），换整段像素成本 ×S²

### 阴影贴图

- 24 包调研定档：线性 distortion（`factor = |xy|·0.85 + 0.15`，中心纹素密度 ~6.7 倍）+ `z × 0.2` 压缩 + shadowtex0 硬件比较黄金螺旋 PCF + shadowtex1 裸深度彩色阴影（RTW 自适应扭曲 / 对数扭曲 + VPS 双 pass 不符低配定位，不采用）
- `shadow` 阶段（`program/shadow.glsl`）：vsh `ftransform` 后扭曲 xy + 压缩 z（**不注入 TAA jitter**——贴图按世界位置采样）；fsh 手动 alpha test（`ALPHA_CUTOUT`）实现 cutout 透贴、写 shadowcolor0 = albedo 透射色（`blend.shadow = off` 整像素写入）；引擎自动写 shadowtex0（全几何深度，`shadowHardwareFiltering0 = true` → sampler2DShadow）/ shadowtex1（仅不透明深度，**保持 sampler2D 裸深度**——彩色阴影遮挡分离与未来 PCSS blocker search 共用的后路）
- 扭曲 / 压缩换算在 `utils/space.glsl`（`shadowDistort` / `relativeWorldToShadowScreen`），写读两侧共用同一实现、对称性由共用结构性保证
- 采样端 `lib/lighting/shadow.glsl` 的 `sampleShadowVisibility`：normal offset（`SHADOW_BIAS_NORMAL`，随距离 / 坡度放大）+ 常数 z bias（`SHADOW_BIAS_DEPTH`）防痤疮；黄金螺旋分档 PCF（`radiusTexels` 超 `SHADOW_PCF_LOW_TIER_TEXELS` 2.5 取高档 12 tap、否则低档 6 tap——噪声密度 = tap 数 ÷ 盘面积，多数像素落低档；两档共用 `SHADOW_PCF_DIRS` 表、旋转角 sincos 每像素外提一对）；temporal bayer 时域旋转由 composite_taa 时间累积收敛为软阴影（零额外 pass）；半径 ÷ 扭曲因子补偿（世界半径恒定）；被 tex0 遮而 tex1 不遮处取 shadowcolor0 上彩色阴影
- 引擎参数集中在 constants.glsl 阴影分区（`shadowMapResolution` 2048 / `shadowDistance` 128 / `shadowDistanceRenderMul` 1.0 / `sunPathRotation` −30——正午太阳不过天顶、天空与光照方向自动一致）；超距 / 出屏返回 1（贴图覆盖外按全亮、无回退门控）；晨昏主光源切换的阴影跳变由 `vDirectIrradiance` 同窗淡黑吸收

### 通用全屏 vsh（`program/fullscreen_vsh.glsl`）

- deferred_init / composite_taa / final 共用的顶点着色器（参考春v2）：out 声明 + main 内直接计算（非库函数），凡「逐帧恒定、全屏一致」的量一次算好经 varying 传入（全屏 quad 仅 3~4 顶点、透视矫正插值精确）
- 输出：全屏 uv `vTexCoord`、TAA jitter `vJitter`、自适应曝光 `vExposure`（槽位无效值回退 1.0）、太阳 / 月亮 / 主光源世界方向、**统一时间系统**（`sunHeight` / `moonHeight` + `noon` / `night` 直射门 `clamp(高度 × TIME_NOON_RAMP / TIME_NIGHT_RAMP)`——日月恰好相对、两门永不同时为正，主光源切换瞬间双 0 黑过渡；`dayFactor` 为慢族环境权重、过渡窗更宽）、直射光颜色 `vDirectIrradiance`（门控加权和 + 雨天 ×0.25 衰减）、直射透射率 `vDirectTransmittance`（定义 `FULLSCREEN_DIRECT_TRANSMITTANCE` 时输出：相机高度近似——表面海拔近似为相机海拔，高差日落色差抹平为已知取舍）、天空环境基色 `vSkyAmbient`（= LUT 探针 rgb 天顶色 × `SKY_AMBIENT_BRIGHTNESS`，探针 fetch 双重职责、色调幅度随 LUT 自动跟进；无效回退 `DAY/NIGHT_SKY_AMBIENT`；雨天去饱和 vsh 预并入）、观察者地平线几何 `vHorizon`、LUT 有效性 `vSkyLutValid`（flat float 0/1——bool 型 varying 为补丁器 / 部分驱动所不容，读取端 `> 0.5` 判定）
- 接入方式：program 平铺 include（内容 `#ifdef STAGE_VERTEX` 自守卫、fsh 编译展开为空）；fsh 按需声明同名 in；deferred_init 的 in 块须位于 lighting.glsl 之前（shadeSurface 直接读同名全局）；带自定义 vsh 的 pass（bloom 链 quad 压缩）不适用，需要帧数据时在自身 vsh 输出同名 varying

## 缓冲布局

| 缓冲 | 格式 | 内容 | 写入者 |
|---|---|---|---|
| colortex0 | RGBA16F | 线性场景颜色：deferred_init 写入（天空 LUT 采样 / shadeSurface 光照）；前向类线性混合；composite_taa 抗锯齿（TAAU 上采样）后即为终态，final 读取后直接输出屏幕、不写回 | deferred_init → 前向类 → composite_taa → final（读） |
| colortex1 | R11F_G11F_B10F | bloom tile 图集：tile0 = 左上 1/4×1/4，tile1~4 右侧纵列边长 1/8~1/64，图集约 10% 面积、tile 间隔 4 texel；无 alpha 浮点格式、带宽减半（COD 核小负瓣写入钳 0 无损） | composite4~8 下采样、composite9~12 上采样回卷（tile0 终态 = 合并后完整泛光）→ final 消费 tile0、composite12 测光读 tile4 |
| colortex3 | RGBA16F，clear = false | TAA 历史：rgb = 上帧混合色（线性 HDR），a = 上帧最近片元线性深度（解遮挡置信；天空为 `TAA_DEPTH_SENTINEL` 哨兵） | composite_taa 独占读写（单程序 ping-pong，不依赖 flip.*） |
| colortex4 | RGBA16 | rg = 打包 albedo（tex × 顶点色；a 通道 = 物品标记），ba = 打包高光贴图 RGBA（labPBR） | gbuffer 类全量写入；手动合成类写 rg |
| colortex5 | RGBA16 | rg = 八面体观察空间法线（无 normal 贴图时即几何法线），ba = 原始 lmcoord | gbuffer 类 |
| colortex7 | RGBA16F，clear = false | 杂项数据（左下角杂项簇，见槽位协议）：预留天空盒 256×256 + 天空 view LUT 200×200（上半太阳 / 下半月亮半区）+ 曝光槽位 1 texel (258, 0) | composite12 唯一写入 → deferred_init（LUT 采样）、composite_taa（上帧曝光）与 final（本帧曝光）读取 |
| depthtex0 | - | 全部几何深度；deferred 时刻可能含 deferred 前绘制的 textured 族（粒子 / 闪电），天空判定不可用（用 depthtex1）；composite 时刻含半透明与手 | 引擎 |
| depthtex1 | - | 仅不透明几何深度（含手部） | 引擎 |

- 位打包值粒度 1/65535，colortex4/5 **必须是 16bit 无符号规范化格式（RGBA16）**，不可改为浮点格式
- **colortex7 槽位协议**：全部槽位集中左下角杂项簇（布局常量 `SKYBOX_LUT_SIZE` / `SKYVIEW_LUT_*`；曝光槽位固定 (258, 0)——在天空盒与 LUT 的间隔 gutter 内、任何分辨率下与两区域不相交）。**唯一写入者纪律**——composite12 独占写入，光栅 quad 取「图集包围盒 ∪ 全部槽位区域」的包围矩形，一 pass 兼管全部槽位（多写入者在 ping-pong 缓冲上会让彼此槽位读到隔帧旧面，不引入第二写入者即免疫、无需 flip.*）；写入者必须**透传光栅区域内不属于自己的槽位**（同位置 texelFetch 读回写回），写入区域整写、**不可 discard**（连座丢弃全部附件）；区域外光栅带无槽位无读者、写 0 免回读。`colortex7Clear = false` 恒定，禁止依赖 `flip.*`

## 管线路线（world0）

| 路线 | program | 入口 | 说明 |
|---|---|---|---|
| 阴影贴图 | `shadow` | shadow | 每帧最先渲染；引擎写 tex0/tex1 双深度；vsh 扭曲 + 压缩（共用 space.glsl、不注入 jitter），fsh cutout + 写 shadowcolor0 = albedo；无 waving、水不特判 |
| deferred gbuffer | `gbuffers_opaque` | terrain, block, hand | `applyTAAJitter` 缩放进 TAAU 子区域 + fsh `outsideRenderRegion` 剔除；MRT 写 colortex4/5 + cutout；terrain 入口挂 gsh 植被判定（vsh 先写 mc_Entity 显式标记，gsh 空标记时兜底），fsh 在 cutout 后写 a 通道标记；block / hand 标记恒空 |
| deferred gbuffer | `gbuffers_opaque_entities` | entities | 同上，叠加 `entityColor`（标记置空） |
| 手动合成 | `gbuffers_color` | basic | 关引擎混合，着色器内合成打包进 colortex4.rg（纯顶点色几何）；line 落 basic，lightning 落 textured |
| 信标光柱 | `gbuffers_beacon` | beaconbeam | 按 alpha 分支（见架构决策）；引擎混合关 |
| 前向完整 | `gbuffers_translucent` | water | deferred 之后，引擎混合写线性 colortex0；扩展点共享 `shadeSurface` |
| 前向简单 | `gbuffers_translucent_simple` | hand_water, weather, textured, textured_lit | 引擎混合写线性 colortex0；textured 族在 deferred 前被覆盖（已知限制） |
| 禁用 | `gbuffers_empty` | skybasic, skytextured, clouds, armor_glint, spidereyes, damagedblock | discard（天空由 deferred_init 按深度补画） |
| 全屏 | `deferred_init` | deferred | 初始化 pass（vsh = 通用全屏 vsh；TAAU 时 quad 经 `FULLSCREEN_RENDER_REGION` 缩进子区域）：位置重建统一去抖基底——`像素 uv − vJitter`（TAAU 再 `/S`）一次算出，天空视线（z = 1）与几何 viewPos（z = depthtex1 原始深度）共用同一组 xy，几何信息采样全 texelFetch(gl_FragCoord) 精确纹素；天空像素采样 colortex7 LUT（天空进 colortex0 是时序关键——之后半透明引擎混合才有正确背景）；几何像素经 `shadeSurface` 着色（直接光 = `vDirectIrradiance × vDirectTransmittance × wrap 余弦 × sampleShadowVisibility` + 环境 / 方块光辐照度，统一乘 albedo/π）写线性 colortex0 |
| 全屏 | `composite_taa` | composite3 | TAA 解析兼 TAAU 上采样器（机制见架构决策 TAA / TAAU 条与 lib/post/taa.glsl）；位于前向半透明全部完成后、bloom 链之前 |
| 全屏 | `composite_bloom` | composite4~8 | 下采样金字塔（`BLOOM_LEVEL` 0~4）：tile < 本级复制回写、tile = 本级 13-tap 高斯下采样写图集、其余 discard；vsh quad 压缩到 tiles 0~本级包围盒；无阈值，整幅 HDR 进金字塔 |
| 全屏 | `composite_bloom_upsample` | composite9~12 | 上采样回卷（`BLOOM_LEVEL` = 目标 tile 3~0，自粗向细）：tile k = 本级 × 级权重 + 已合并粗级 tent 放大 2 倍相加；包围盒内非 tile 像素复制回写（不 discard——composite12 兼写 colortex7）；tile4 恒为原始下采样内容供测光；链末级 composite12 为 colortex7 唯一写入者——重算天空 LUT、曝光测光与适应、其余透传（见槽位协议）；colortex7 槽位区域与 tile0 在 uv 上重叠但两缓冲互不相干，outMisc 分支不得干涉 outColor（否则 tile0 凿洞、final 放大后成屏幕黑矩形） |
| 全屏 | `final` | final | 收尾单 pass（vsh = 通用全屏 vsh）：colortex0 + bloom tile0 线性域合成 → 乘 `vExposure` → AgX → `linearToSrgb` 输出屏幕 |

- **composite 编号约定**：编号不超过 14；composite3 = TAA（bloom 链之前最后一级前置效果）、4~8 = bloom 下采样、9~12 = 上采样回卷（12 兼 colortex7 槽位写入）、13 / 14 空出（原 bloom 合并 / tonemap 已并入 final）；0~2 预留给 TAA 之前的效果（新效果从 2 往前排）；需要 TAA 与 bloom 链**之间**的槽位（DOF / 运动模糊）时把 TAA 挪到 composite2 即可（一处入口改名）

## lib 一览（分类对齐春雷：`common/{globals,pipeline,utils}` / `atmosphere` / `lighting` / `post`）

**lib/common/globals/**（全局声明，几乎每个 program 都引）

- `constants.glsl`：全部常量集中（各常量注释即调效依据与量纲说明）
- `uniforms.glsl`：全部 uniform 集中（各采样器的读取语义见注释）

**lib/common/pipeline/**

- `varying_io.glsl`：`VARYING` 宏
- `gbuffer_data.glsl`：读取端工具——`remapLightmap` 光照图重映射、`materialSSSStrength`（colortex4 albedo a 通道标记 → [0,1] SSS 强度，半 8bit 容差比较；植被取 `VEGETATION_SSS_STRENGTH`、`MATERIAL_SOLID` 与未标记取 0、253~255 预留时在此定档）；colortex4/5 解包读取按需在此扩展

**lib/common/utils/**（函数级复用）

- `color.glsl`：`srgbToLinear`（gamma 2.2 六阶多项式拟合替代 pow——光照路径最热 ALU 段，x² 形式匹配近零平切线免黑位翻负）、`linearToSrgb`（保持 pow，仅 final 一次非热点）、`rgbToLuma`、`rgbToYCoCg` / `yCoCgToRgb`（精确互逆，TAA 钳制已用、denoise / SSR 方差估计同用）
- `filters.glsl`：`textureNice`、`tentFilter4`、`downsample13Tap`（COD AW 核）、`catmullRom5`（5-tap 锐化 Catmull-Rom，返回 rgba——a = 深度随同组权重带回，tap 全 Lod0）；函数全部显式传参、无 uniforms / 常量依赖
- `space.glsl`：坐标换算 `screenToView`（NDC 转换在函数内统一完成——杜绝只转 xy 漏转 depth）、`viewToWorldDirection`、`viewToRelativeWorld`、`relativeWorldToPreviousScreen`（相机增量显式传参，手部传 `vec3(0)`）、`viewDirectionToPreviousScreen`（天空无穷远重投影，w = 0 平移自动失效）；阴影换算 `shadowDistort` / `relativeWorldToShadowScreen`（写读两侧共用）；cotangent frame `calculateTBN` / `geomNormalFromDerivatives` / `calculateGeomNormal`（仅片段阶段）。依赖 uniforms.glsl + constants.glsl（阴影部分）
- `packing.glsl`：位打包 + 八面体映射（不限法线用途）
- `noise.glsl`：`bayer2`~`bayer64`（纯 ALU）与 `temporalBayer64`（空间低频 + 帧间 golden ratio 相位——TAA 方差统计不被高频噪声抬高，故弃用 IGN）；TAA jitter 族 `taaJitterSample/UV` / `applyTAAJitter`（TAAU 子区域缩放内嵌） / `applyJitter` / `applyInverseJitter`、`outsideRenderRegion`（仅片段阶段，TAAU 子区域外剔除）；Halton 表在 constants.glsl。依赖 constants.glsl + uniforms.glsl

**lib/atmosphere/**

- `atmosphere.glsl`：Chapman 闭式光学深度 + 保能量单次散射（零 raymarch，移植自 Shadertoy WcdSW4，适配与数值防护见文件头）——`erfcx` / `airMass` / `energyIntegralRatio`（0/0 泰勒保形）/ `atmosphericRadianceSingle` / `ambientCapture` / `skyAmbientField`（多次散射环境场）/ `atmosphericRadiance` / `planetHitDistance` / `solarTransmittance`。密度模型为 r² 高斯（H 是参数化、有效尺度高度见 constants.glsl 注释）。已接入 sky.glsl LUT 生成端与通用全屏 vsh 的 `vDirectTransmittance`
- `sky.glsl`：`getSkyColor` 采样入口（光源方向 / 地平线 / 有效性由调用方从 vsh 帧数据传入）、Hillaire 参数化互逆组（`skyViewLutZenithParam` / `AzimuthParam` / `skyViewLutTexel`）、解析路径 `skyRadianceAnalytic`、槽位矩形 `skyViewLut*Rect`、`sun/moonDirectionWorld`。当前太阳 + 月亮双光源 / 晴天（星星 / 雨天为扩展点）。依赖 uniforms / constants / space / atmosphere

**lib/lighting/**

- `shadow.glsl`：`sampleShadowVisibility` 主入口（返回带色可见性 rgb；入参相对世界位置，内部加 normal offset）——biases / 分档 PCF / temporal 旋转 / 彩色阴影见架构决策「阴影贴图」；PCSS 后路：tex1 裸深度，加 blocker search 替换常数半径即升级、引擎配置零改动。依赖 constants / uniforms / color / space / noise
- `lighting.glsl`：`shadeSurface`（deferred 与前向共用，仅片段阶段）——直射 E = `vDirectIrradiance × directTransmittance × wrap 重映射余弦 × 阴影可见性`，天空环境 / 方块光辐照度，统一乘 Lambert `albedo/π`；SSS 为 wrap 漫反射近似（强度线性缩放 wrap 量与阴影软化半径，强度 0 退化为 `max(ndl, 0)`）；帧数据 `vLightDirection` / `vDirectIrradiance` / `vSkyAmbient` 直接读同名 in 全局（接入方 fsh 须在本文件 include 前声明，未来前向 program 由其 vsh 输出同名 varying）；viewPos 在函数内统一换算 relativeWorldPos。依赖 uniforms / constants / space / shadow

**lib/post/**

- `bloom.glsl`：图集布局 `bloomTileRect` / `bloomTileRectMax` / `bloomMiscRectMax`（colortex7 预留区域）、下采样 `bloomDownsampleTile`、回卷 `bloomUpsampleTile`、合并 `getBloom`；矩形 textureSize 运行时推导、不依赖 size.buffer（低版本 OptiFine 兼容）。依赖 constants / uniforms / filters
- `tonemap.glsl`：`agx`（春雷同款 minimal AgX，末段 pow 2.2 回线性）。依赖 constants
- `exposure.glsl`：`exposureTexel`（槽位位置，写读共用）、`sceneAverageLuminance`（tile4 上固定 16 点核对数平均）、`targetExposure`（key 直除 + 地板）、`adaptedExposure`（曝光域指数平滑、首帧守卫）、`readAdaptedExposure`。依赖 constants / uniforms / bloom / color
- `taa.glsl`：`closestDepthCross`、`reprojectViewToPreviousUV`、钳制域工具、`clipHistoryToNeighborhood`、`resolveTAA` 主入口——机制与 TAAU 域换算见架构决策 TAA / TAAU 条与函数内注释；依赖 constants / uniforms / color / filters / space，jitter 补偿与曝光由调用方传参

## 当前状态

效果骨架 + 天空 + 阴影直接光，每帧流程：`shadow`（tex0/tex1 双深度 + shadowcolor0 透射色）→ gbuffers 写 colortex4/5（打包，albedo 存原始 sRGB）→ 前向半透明线性混合 colortex0 → `deferred_init` 解包光照（天空 LUT 采样 / shadeSurface：阴影 PCF + 彩色阴影 + 植被 SSS、直接光与天空同源）写线性 colortex0 → `composite_taa`（TAA + TAAU 上采样，恢复全屏）→ `composite_bloom` 4~8 下采样 → `composite_bloom_upsample` 9~12 回卷（composite12 兼天空 LUT 重算 + 曝光测光）→ `final`（bloom 合成 / 曝光 / AgX / gamma）。天空入口禁用、日月星盘未画；water 等前向程序尚未接 `shadeSurface`（线性 tex 直通）；emissive（specular.a，含信标核心）暂未消费。

## 已知限制（均为扩展点）

- 几何法线不单独存储（已并入 colortex5 观察空间法线；有 normal 贴图的像素无法还原几何法线）——需分离时参考春雷 normalOV 单独存通道
- 植被判定：染色判据会带上其余生物群系染色几何（树叶等——春雷同款误报，对 SSS 无害，需要时沿 block.properties 显式标记扩展排除）；交叉面片判据依赖原版 45° 斜置模型，改模资源包会漏报；实体 / 手持 / 方块实体恒空标记。标记已由 SSS 消费；摇摆 / wind 为扩展点
- 手动合成类程序（color、beacon 外壳）texelFetch 正在写入的 colortex4/5——个别驱动上未定义行为；composite12 的 colortex7 透传同款
- 阴影：sunPathRotation −30 偏轴为预期视觉；彩影无水特判（无 caustics）；无 waving；痤疮 / 悬空影调 `SHADOW_BIAS_*`（`shadow.culling` 必要时 `reversed`）。扩展点——PCSS（后路已留）、`shadowEntities` 等开关、主光源切换期间双阴影贴图 / 方向插值
- SSS 为近似（春v2 同构）：背光侧受自身叶片阴影遮挡偏暗、wrap 不保能量（风格化取舍；嫌弱抬 `VEGETATION_SSS_STRENGTH`）；water 前向共享 `shadeSurface` 为扩展点（接入时 `sssStrength = 0`）；emissive 暂未消费（接入时在 shadeSurface 按 specular.a 加自发光项）
- 天空：LUT 滞后一帧（无视觉差异）；200×100 双线性在地平线极陡梯度处略糊（jitter 时间累积补足）；MS 为各向同性近似（无前向瓣角依赖、近日略欠；求积静态偏差 ±10%）；非活动半区门控与写黑共用 `SKY_LIGHT_MIN_HEIGHT`（改动须两端联动）。扩展点——雨天（mix 去饱和 + Mie 系数放大）、星星、日月解析圆盘（× `solarTransmittance` 自动红化）、夜晚亮度统调（抬 `MOON_IRRADIANCE`）、`SKY_BRIGHTNESS` 校准
- 自动曝光：测光含天空像素（与参考一致）；曝光上限由 BASE 地板收口 18；适应步长（RATE 2.0、60fps 每帧 ~3%）远大于半精度量化步长。未来杂项数据进 colortex7 沿槽位协议自分区
- TAA：动态实体无逐物体速度（纯相机重投影，实体运动靠方差钳制收敛）；水面波动重投影为近似；十字锚定不含对角（角点可能轻微闪烁）；手部仅「相机附着 + 权重下限抬高」近似；粒子（textured 族 deferred 前写入被覆盖）见下条
- TAAU：S=0.5 档高频细节仍可见轻度软化（全额去抖 + 置信度门控 + Karis 防闪 + 32 相位修复后可用；嫌软先抬 `TAAU_UPSAMPLE_SHARPNESS`（按 2.0−S−S 校准）或回 S=0.75，仍不足再评估 final 级 CAS——四家参考全配 final 锐化）；历史无帧龄通道（大面积解遮挡收敛慢时微抬 `TAAU_BLEND_MIN` / `TAAU_BLEND_BASE`）；上采样核采到子区域边缘外半像素由钳边 + 引擎 clamp-to-edge 兜底；统计盒仍在渲染域十字粒度（Photon 的 min/max 预处理 pass + 跨像素插值为后路）；与引擎级渲染缩放叠加 = 两级上采样，用户应二选一；FSR2 完整移植 / superresolution.json / size.buffer 缩缓冲等路线不符定位、已排除
- 无 PCSS（软半径为常数）；无雾 / 水下效果（可在 deferred_init 与前向程序基于视距混合 `getSkyColor`）
- bloom 无阈值（全部参考一致；需阈值在 `bloomDownsampleTile` k=0 分支加 soft knee）；bloom 链每 pass 重写自己需要的全部 tile——跨 pass 保值对 main/alt 翻转免疫、无需 flip.*
- 半透明实体 / 半透明方块实体（Iris `entities_translucent` / `block_translucent`）落回退链，透明部分暂按不透明写入
- textured / textured_lit / particles / lightning 在 deferred 之前绘制、写 colortex0 会被 deferred 全屏覆盖（暂不可见）；后续 Iris `particles.ordering` 调整时机，或 textured 族改回手动合成路线（`gbuffers_color_textured`）
