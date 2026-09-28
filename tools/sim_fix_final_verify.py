# -*- coding: utf-8 -*-
# 最终验证：双侧平滑钳制 y' = y * smoothstep(0, B, y)（y<=0 钳到 0、y>0 平滑释放）
# 对比旧硬钳制 min(y, 0)：
#   1) y=0 斜率突变（折角）是否消除；下半球是否恒平（切线膝点随之下线）
#   2) B=0.5 时全带（0~35 度）与旧版的亮度差（观感是否保持）
#   3) 全带二阶差分扫描：不得引入新折点（如 y≈B 处）
import numpy as np
import sim_horizon_line as S

def fogged_profile(cam_y, sun_y, mode, band):
    """mode: 'hard' = min(y,0)；'smooth' = y*smoothstep(0,band,y)。返回 (elevs, fogged luma)。"""
    r = S.EARTH_RADIUS + max(cam_y, 1.0)
    hz = S.horizon_geometry(r)
    lut_sun, lut_moon = S.build_lut(r, sun_y)
    sun_dir = np.array([np.sqrt(max(1 - sun_y * sun_y, 0)), sun_y, 0.0])
    moon_dir = -sun_dir

    elevs = np.arange(-1.5, 35.01, 0.05)
    out = []
    for e in elevs:
        y = np.sin(np.radians(e))
        d = np.array([np.cos(np.radians(e)), y, 0.0])
        sky = S.get_sky_color(d, hz, lut_sun, lut_moon, sun_dir, moon_dir)
        scene = S.luma(sky) + S.luma(S.get_sun_disk(d, sun_dir, cam_y))
        fd = d.copy()
        if mode == 'hard':
            fd[1] = min(fd[1], 0.0)
        else:
            fd[1] = fd[1] * S.smoothstep(0.0, band, fd[1])
        fog_col = S.luma(S.get_sky_color(fd, hz, lut_sun, lut_moon, sun_dir, moon_dir))
        f = S.fog_factor(y)
        out.append((1 - f) * scene + f * fog_col)
    return elevs, np.array(out)

def slope_at(elevs, vals, lo, hi):
    idx = [i for i, v in enumerate(elevs) if lo <= v <= hi]
    return (vals[idx[-1]] - vals[idx[0]]) / (elevs[idx[-1]] - elevs[idx[0]])

for sun_y, name in ((-0.03, "晨昏带（太阳 -1.7 度）"), (0.0, "日出瞬间"), (0.7, "正午")):
    e_hard, v_hard = fogged_profile(63.0, sun_y, 'hard', None)
    print(f"\n===== {name} =====")
    s_b = slope_at(e_hard, v_hard, -0.30, -0.05)
    s_a = slope_at(e_hard, v_hard, +0.05, +0.40)
    print(f"  旧硬钳制   y=0 斜率: {s_b*100:+.1f}%/度 -> {s_a*100:+.1f}%/度")
    for band in (0.1, 0.5):
        e_s, v_s = fogged_profile(63.0, sun_y, 'smooth', band)
        s_b = slope_at(e_s, v_s, -0.30, -0.05)
        s_a = slope_at(e_s, v_s, +0.05, +0.40)
        # 下半球平直度（-1.5~-0.05 度全窗斜率，应 ~0 = 切线膝点消失）
        s_flat = slope_at(e_s, v_s, -1.50, -0.05)
        # 与旧版全带最大偏差（除地平线 ±1 度折角区外）
        mask = np.abs(e_hard) > 1.0
        delta = np.abs(v_s[mask] - v_hard[mask]) / np.maximum(v_hard[mask], 1e-6)
        # 全带二阶差分最大值（含新折点检查）
        d2 = np.abs(np.diff(v_s, 2))
        d2_hard = np.abs(np.diff(v_hard, 2))
        i2 = int(np.argmax(d2))
        print(f"  平滑 B={band:.1f}  y=0 斜率: {s_b*100:+.1f}%/度 -> {s_a*100:+.1f}%/度   "
              f"下半球平直度: {s_flat*100:+.2f}%/度   "
              f"全带(>1度)最大偏差: {delta.max()*100:.1f}%   "
              f"全带最大二阶差分: {d2.max():.2e} @ {e_s[i2+1]:+.1f}度 (旧版 {d2_hard.max():.2e})")
