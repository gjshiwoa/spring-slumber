# 春眠

面向 OptiFine / Iris 的轻量 Minecraft 光影包，以低配和兼容性为优先。

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
- 深度输入 `noTranslucentDepthtex` 与着色器 `depthtex1` 同源。
- 运动矢量为无抖动的归一化 UV 位移，方向 `previous - current`；
  `colortex31.rg` 存矢量，`.b` 存实体标记，帧头默认清零。
- `composite3` 必须全屏读回并透传 SR 结果，不能用 `discard` 旁路，不能重复写 TAA 历史。
- 配置结构保留 Schema V3 的 `upscale` 嵌套对象、`upscaled_color` 输出键及数组形式的 `target`。

## 本地开发验证

以下工具在开发工作区的 `tools/` 中使用，需要 Node.js 和可执行的 Python；
OpenGL 编译校验仅用于 Windows 本地兼容驱动。工具不是运行光影包所必需的发布文件。

```powershell
node tools/validate_glsl_static.js
python tools/test_sr_interface.py
node tools/test_material_mip.js
node tools/test_taau.js
node tools/test_taau_edges.js
python tools/validate_glsl_compile.py --matrix --legacy-optifine
```

静态检查覆盖编码、入口 ASCII、输出附件、三维度 SR 门控和回退；接口测试覆盖
配置、ping-pong、深度同源、实体写入时机及 clip 插值约束。编译矩阵覆盖 SR 启用、
velocity 扩展缺席/显式关闭、TAAU 关闭、无 jitter、SR 关闭、仅安装和 FG-only 回退，
并保留原生、缩放档与旧 OptiFine 上传路径检查。

离线检查验证的是着色器编译与接口约定，**不是** SR 算法实际执行或视觉验收。
后续修改接入时，建议实机复测：三维度切换、SR 开关与质量档切换、TAAU 开关、
相机旋转/平移、实体运动、手部、玻璃/水面、窗口尺寸变化和资源包 mip 细节。

打包时保留完整 `shaders/`（包含 SR JSON、lang 和三个 world 目录）及 `LICENSE`；
不要只拷贝着色器入口，或漏掉 `superresolution.v3.json`。架构与已知取舍见 `AGENTS.md`。
