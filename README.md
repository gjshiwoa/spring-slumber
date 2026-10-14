# 春眠

面向 OptiFine / Iris 的轻量 Minecraft 光影包，以低配和兼容性为优先。

## Voxy 远景接入

已接入 Voxy 的不透明远景和最近一层半透明远景，覆盖主世界、下界和末地。
不透明 LOD 复用本包 deferred 光照；远景水复用水面、折射、水雾和反射路径，
玻璃使用轻量光照与 alpha 合成。多层 LOD 半透明目前按最近层近似处理。

- Voxy 使用独立深度与投影矩阵；原版与 LOD 重建到同一观察空间后比较距离。
- 内置 TAA / TAAU 与 SR 超分路径共享对应的缩放和抖动参数。
- 未启用 Voxy 时，专用合成阶段和 LOD 资源引用移除；SSR 保持固定四次精修。
  SSR 步距统一按实际渲染区域计算，TAAU / SR 降低比例时仍保持追踪密度。
  屏幕空间阴影共用距离适配和纹素中心重建，远处的长度、偏移及命中窗口一起增长。
  SR 单独开启时直接读取原深度，不额外生成深度附件。
- 配置入口为根目录及三个 world 目录下的 voxy.json 和对应补丁，共享实现位于
  shaders/lib/compat/voxy/ 与 shaders/program/。

当前已做本地静态、数值回归及驱动编译验证；尚未完成本轮 Minecraft 实机视觉验收和
FPS 测量。实机重点检查近远景水接缝、玻璃遮挡、水下厚度、掠视与移动时的稳定性，
以及维度、TAAU 和 SR 质量档切换。

## SR mod 超分接入

当前支持 SR mod 的超分辨率接口；**不接入帧生成接口**。配置文件为
`shaders/superresolution.v3.json`，覆盖主世界、下界和末地。

- **普通 OptiFine / Iris，或 SR 未启用超分**：继续使用光影内置 TAA / TAAU。
- **Iris + SR mod 启用超分**：SR 接管渲染比例、抖动和画面重建，内置 TAA 透传，不重复累积。
- **仅帧生成模式**：本包不启用 SR 超分路径，内置 TAA / TAAU 照常工作；这不代表本包提供了帧生成支持。

### 使用注意

1. 启用 SR 超分后，在 **SR mod 中**调整质量档或渲染比例。光影设置中的
   `RENDER_SCALE` 此时被 SR 覆盖；关闭内置 `TAAU` 也不会关闭 SR 的低分辨率渲染。
2. 关闭 SR 超分后，光影恢复自身的 `TAAU` / `RENDER_SCALE` 设置，无需改动源码。
3. Iris 的 `at_velocity` 扩展开启时，普通实体在 deferred 前后两种绘制时机都输出实体运动矢量；
   扩展缺席或关闭时，回退到场景相机运动矢量。
4. 水面、前向半透明、手部和方块实体没有独立的逐物体运动矢量；
   快速运动、遮挡变化、动态植物等仍需由超分算法的历史拒绝处理。
5. 本包只提供统一输入，不保证所有 SR 算法、显卡和驱动组合表现相同。
   2026-10-11 用户反馈当前实机无可见问题；该反馈不等于所有组合均已测试。

### 接口维护约定

- 触发点：`BEFORE composite3`。输入为雾后的线性 HDR 场景，超分后再执行 bloom / final。
- 色彩输入与输出均使用 `autotex6`，运动矢量使用 `autotex31`；
  不要改成固定 `colortex6` / `alttex6`，两张缓冲的 ping-pong 状态并不总是相同。
- 深度输入由配置中的 `#ifdef VOXY` 选择：关闭时使用 `noTranslucentDepthtex`；
  开启时使用 `autotex20`，在原版不透明几何与 LOD 之间按真实观察深度选择，
  LOD 获胜时导出原版投影域深度。SR 的 JSON 预处理器使用 Iris 的环境宏。
- 运动矢量为无抖动的归一化 UV 位移，方向 `previous - current`；
  `colortex31.rg` 存矢量，`.b` 存实体标记，帧头默认清零。
- `composite3` 必须全屏读回并透传 SR 结果，不能用 `discard` 旁路，不能重复写 TAA 历史。
- 配置结构保留 Schema V3 的 `upscale` 嵌套对象、`upscaled_color` 输出键及数组形式的 `target`。

## 本地开发验证

以下工具在开发工作区的 `tools/` 中使用，需要 Node.js 和可执行的 Python；
OpenGL 编译校验仅用于 Windows 本地兼容驱动。工具不是运行光影包所必需的发布文件。

```powershell
node tools/validate_glsl_static.js
node tools/test_voxy.js
node tools/test_voxy_disabled_cost.js
python tools/test_sr_interface.py
node tools/test_material_mip.js
node tools/test_taau.js
node tools/test_taau_edges.js
node tools/test_taau_coordinates.js
node tools/test_taa_fixed_blend.js
node tools/test_taau_history_bounds.js
node tools/test_taau_depth_range.js
python tools/validate_glsl_compile.py --matrix --legacy-optifine --taa-diagnostics
```

TAAU 当前版本采用唯一历史深度 min/max 区间确认，中心接受后提前结束读取；
深度有效时放宽历史颜色，当前帧重建去振铃保持原值。默认诊断关闭，回退开关与
诊断 0～5 的说明见 `plans/TAAU优化记录.md`。相关工具保留完整九点对照，
检查提前退出等价性、历史深度读取次数、颜色约束及 SR 旁路。

静态检查覆盖编码、入口 ASCII、输出附件、三维度 SR 门控和回退；接口测试覆盖
配置、ping-pong、深度接口、实体写入时机及 clip 插值约束。编译矩阵覆盖 SR 启用、
velocity 扩展缺席/显式关闭、TAAU 关闭、无 jitter、SR 关闭、仅安装和 FG-only 回退，
并保留原生、缩放档与旧 OptiFine 上传路径检查。Voxy 回归覆盖独立投影深度排序、
远景水背景与厚度、材质编码、坐标变换、TAA 锚点及 SR 深度和运动矢量接口。

离线检查验证的是着色器编译与接口约定，**不是** SR 算法实际执行或视觉验收。
后续修改接入时，建议实机复测：三维度切换、SR 开关与质量档切换、TAAU 开关、
相机旋转/平移、实体运动、手部、玻璃/水面、窗口尺寸变化和资源包 mip 细节。

打包时保留完整 `shaders/`（包含 SR JSON、lang 和三个 world 目录）及 `LICENSE`；
不要只拷贝着色器入口，或漏掉 `superresolution.v3.json`。架构与已知取舍见 `AGENTS.md`。
