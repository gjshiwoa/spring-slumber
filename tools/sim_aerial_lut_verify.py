# aerial LUT（lib/atmosphere/aerial.glsl）静态数值验证：四组不变式，公式逐行照抄 GLSL 实现
#   1. 方向参数化互逆性：生成端 aerialLutTexel 的逆映射（zenithParam→vzc、azimuthParam→lvCos）
#      与采样端 sky.glsl skyViewLutZenithParam / skyViewLutAzimuthParam（分辨率无关、单真源复用）
#      在 AERIAL_LUT_W/H 分辨率下互逆——两端数值不一致 = 方位 / 天顶错位（雾色方向错乱）
#   2. 采样域包含：aerialLutFetch 的缓冲 uv（lutParamToTexelCenter 半纹素内缩 + 切片平移）
#      恒在切片矩形内半纹素——不越区域边界、不与相邻距离档 / 既有槽位串色
#   3. colortex7 槽位互斥：aerial 区域 [0,64)×[0,192) 与曝光 (258,0) / 标记 (259,0) /
#      sky-view [260,460)×[0,200) / bloomMiscRectMax 覆盖关系
#   4. 距离域全程连续性（含档 0 以下段）：档 0 以下向相机线性归零（t = 0 时 inscatter 0，无起始
#      阈值）、档间线性 lerp 在 S0/S1/S2 处连续、末段 w = 1 − S2/t 在 S2 处 0（与 slice2 段连续）、
#      t→∞ 收敛 1、inscatter 全程单调不减——跳档 / 段间不连续 = 距离环上的可见带

import numpy as np

EARTH_RADIUS = 6360e3
AERIAL_LUT_W, AERIAL_LUT_H, AERIAL_LUT_SLICES = 64, 48, 4
AERIAL_DIST_SLICES = [1024.0, 4096.0, 16384.0]
SKYVIEW_LUT_ORIGIN_X, SKYVIEW_LUT_W, SKYVIEW_LUT_H = 260, 200, 100
EXPOSURE_TEXEL, MARKER_TEXEL = (258, 0), (259, 0)


# ---- sky.glsl 采样端（单真源，分辨率无关）----

def lut_param_to_texel_center(p, resolution):
    return p * (resolution - 1.0) / resolution + 0.5 / resolution


def zenith_param(vzc, horizon):
    # skyViewLutZenithParam：vzc = dirWorld.y
    vzc = np.clip(vzc, -1.0, 1.0)
    cos_beta, beta, zenith_horizon = horizon
    vzc_angle = np.arccos(vzc)
    if vzc >= -cos_beta:
        t = 1.0 - vzc_angle / zenith_horizon
        return (1.0 - np.sqrt(np.clip(t, 0.0, 1.0))) * 0.5
    else:
        t = (vzc_angle - zenith_horizon) / beta
        return np.sqrt(np.clip(t, 0.0, 1.0)) * 0.5 + 0.5


def azimuth_param(view_horiz, light_horiz):
    # skyViewLutAzimuthParam：入参为归一化水平分量
    return np.sqrt(np.clip((1.0 - np.dot(view_horiz, light_horiz)) * 0.5, 0.0, 1.0))


# ---- aerial.glsl 生成端（逆映射，公式与 skyViewLutTexel 成对维护）----

def gen_dir_local(local_x, row, horizon):
    azimuth_param_v = local_x / (AERIAL_LUT_W - 1)
    zenith_param_v = row / (AERIAL_LUT_H - 1)
    _, beta, zenith_horizon = horizon
    if zenith_param_v < 0.5:
        q = 1.0 - 2.0 * zenith_param_v
        vzc = np.cos(zenith_horizon * (1.0 - q * q))
    else:
        q = 2.0 * zenith_param_v - 1.0
        vzc = np.cos(zenith_horizon + beta * (q * q))
    vz_sin = np.sqrt(max(1.0 - vzc * vzc, 0.0))
    lv_cos = 1.0 - 2.0 * azimuth_param_v * azimuth_param_v
    lv_sin = np.sqrt(max(1.0 - lv_cos * lv_cos, 0.0))
    return np.array([vz_sin * lv_cos, vzc, vz_sin * lv_sin])


# ---- aerial.glsl 采样端 ----

def aerial_fetch_texel(param, slice_idx):
    local_uv = np.array([
        lut_param_to_texel_center(param[0], AERIAL_LUT_W),
        lut_param_to_texel_center(param[1], AERIAL_LUT_H),
    ])
    rect_origin = np.array([0.0, slice_idx * AERIAL_LUT_H])
    rect_size = np.array([float(AERIAL_LUT_W), float(AERIAL_LUT_H)])
    return rect_origin + local_uv * rect_size  # texel 域


def sample_blend_weight(t_eff):
    # sampleAerialLut 的档位 / 权重选择（含档 0 以下线性归零段——雾自相机起、无起始阈值）
    if t_eff < AERIAL_DIST_SLICES[0]:
        return (("ramp0", 0), t_eff / AERIAL_DIST_SLICES[0])     # LUT[S0] × w、透射率 mix(1, T, w)
    if t_eff >= AERIAL_DIST_SLICES[2]:
        return ("tail", np.clip(1.0 - AERIAL_DIST_SLICES[2] / t_eff, 0.0, 1.0))
    if t_eff < AERIAL_DIST_SLICES[1]:
        lo, hi = AERIAL_DIST_SLICES[0], AERIAL_DIST_SLICES[1]
        return ((0, 1), (t_eff - lo) / (hi - lo))
    lo, hi = AERIAL_DIST_SLICES[1], AERIAL_DIST_SLICES[2]
    return ((1, 2), (t_eff - lo) / (hi - lo))


def effective_inscatter(t_eff, slice_values):
    # 以抽象档值（inscatter 单调增）复合出的有效 inscatter——检查连续 / 单调的真实对象
    if t_eff < AERIAL_DIST_SLICES[0]:
        return slice_values[0] * (t_eff / AERIAL_DIST_SLICES[0])
    seg, w = sample_blend_weight(t_eff)
    if seg == "tail":
        return slice_values[2] + (slice_values[3] - slice_values[2]) * w
    a, b = seg
    return slice_values[a] + (slice_values[b] - slice_values[a]) * w


def main():
    ok = True

    # 观察者地平线几何（composite12 vsh / fullscreen_vsh 同式）：64 m 海拔
    r = EARTH_RADIUS + 64.0
    altitude_term = max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0)
    cos_beta = np.sqrt(altitude_term) / r
    beta = np.arccos(cos_beta)
    horizon = (cos_beta, beta, np.pi - beta)

    # 1. 方向参数化互逆性
    worst_zenith = 0.0
    for row in range(AERIAL_LUT_H):
        zenith_param_gen = row / (AERIAL_LUT_H - 1)
        d = gen_dir_local(0, row, horizon)  # 方位不影响天顶维
        back = zenith_param(d[1], horizon)
        worst_zenith = max(worst_zenith, abs(back - zenith_param_gen))
    worst_azimuth = 0.0
    for x in range(AERIAL_LUT_W):
        ap_gen = x / (AERIAL_LUT_W - 1)
        d = gen_dir_local(x, AERIAL_LUT_H // 2, horizon)  # 任取水平行（vzSin > 0）
        horiz = d[[0, 2]] / np.linalg.norm(d[[0, 2]])
        back = azimuth_param(horiz, np.array([1.0, 0.0]))  # 局部系锚光源水平投影 = +X
        worst_azimuth = max(worst_azimuth, abs(back - ap_gen))
    print(f"[1] 参数化互逆: zenith 最大误差 {worst_zenith:.3e}、azimuth 最大误差 {worst_azimuth:.3e}"
          f"（texel 单位 {max(worst_zenith, worst_azimuth) * AERIAL_LUT_H:.4f} / {max(worst_zenith, worst_azimuth) * AERIAL_LUT_W:.4f}）")
    ok &= worst_zenith < 1e-6 and worst_azimuth < 1e-6

    # 2. 采样域包含：param 全域 → fetch uv 恒在各切片矩形半纹素内
    worst_out = 0.0
    for slice_idx in range(AERIAL_LUT_SLICES):
        for px in np.linspace(0.0, 1.0, 33):
            for py in np.linspace(0.0, 1.0, 33):
                uv = aerial_fetch_texel((px, py), slice_idx)
                lo = np.array([0.5, slice_idx * AERIAL_LUT_H + 0.5])
                hi = np.array([AERIAL_LUT_W - 0.5, (slice_idx + 1) * AERIAL_LUT_H - 0.5])
                worst_out = max(worst_out, np.max(np.maximum(lo - uv, uv - hi)))
    print(f"[2] 采样域包含: 半纹素内缩最大越界 {worst_out:.3e} texel（<=0 即恒在内）")
    ok &= worst_out <= 1e-9

    # 3. colortex7 槽位互斥
    aerial_rect = (0, 0, AERIAL_LUT_W, AERIAL_LUT_H * AERIAL_LUT_SLICES)
    def overlaps(a, b):
        return not (a[0] + a[2] <= b[0] or b[0] + b[2] <= a[0] or a[1] + a[3] <= b[1] or b[1] + b[3] <= a[1])
    slot_rects = {
        "曝光槽": (EXPOSURE_TEXEL[0], EXPOSURE_TEXEL[1], 1, 1),
        "标记槽": (MARKER_TEXEL[0], MARKER_TEXEL[1], 1, 1),
        "sky-view": (SKYVIEW_LUT_ORIGIN_X, 0, SKYVIEW_LUT_W, 2 * SKYVIEW_LUT_H),
    }
    disjoint = all(not overlaps(aerial_rect, s) for s in slot_rects.values())
    print(f"[3] 槽位互斥: aerial {aerial_rect} vs {slot_rects} -> {'互斥' if disjoint else '重叠!'}")
    ok &= disjoint

    # 4. 距离域全程连续性：抽象单调档值复合出的有效 inscatter 在 0 / S0 / S1 / S2 处连续、
    #    全程单调不减、t→∞ 收敛渐近档
    slice_values = [1.0, 4.0, 14.0, 40.0]  # 单调增（量级近似 1024/4096/16384/∞ m 融合度）
    ts = np.sort(np.concatenate([np.linspace(0.0, AERIAL_DIST_SLICES[0] * 2, 2000),
                                 np.linspace(AERIAL_DIST_SLICES[0], 1e9, 4000)]))
    fs = np.array([effective_inscatter(t, slice_values) for t in ts])
    mono = np.all(np.diff(fs) >= -1e-12)
    cont_edges = []
    for edge in AERIAL_DIST_SLICES:
        below = effective_inscatter(edge - 1e-9, slice_values)
        above = effective_inscatter(edge + 1e-9, slice_values)
        cont_edges.append(abs(above - below) < 1e-6)
    cam_zero = abs(effective_inscatter(0.0, slice_values)) < 1e-12   # 相机处 inscatter = 0（无起始阈值）
    # 渐近收敛按解析残差校验：f(t) = V∞ − (V∞−V2)·S2/t，容差 = 残差 + 数值余量
    t_far = 1e9
    tail_resid = (slice_values[3] - slice_values[2]) * AERIAL_DIST_SLICES[2] / t_far
    tail_conv = abs(effective_inscatter(t_far, slice_values) - slice_values[3]) < tail_resid * 1.01 + 1e-9
    print(f"[4] 距离域连续: 相机起点归零 {'是' if cam_zero else '否!'}、S0/S1/S2 段间 "
          f"{['连续' if c else '跳变!' for c in cont_edges]}、单调 {'是' if mono else '否!'}、"
          f"t→∞ 收敛渐近档 {'是' if tail_conv else '否!'}")
    ok &= mono and all(cont_edges) and cam_zero and tail_conv

    print("结果:", "全部通过" if ok else "存在失败项")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
