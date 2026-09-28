# -*- coding: utf-8 -*-
# 验证：雾色方向钳制 min(y,0) 是 y=0 折角的唯一来源；平滑过渡带（y' = y*smoothstep(0,B,y)）可消折角
# 且不破坏地平线处的地形/天空雾色融合。
import numpy as np
import sim_horizon_line as S

def profile_variant(cam_y, sun_y, label, band=None):
    r = S.EARTH_RADIUS + max(cam_y, 1.0)
    hz = S.horizon_geometry(r)
    lut_sun, lut_moon = S.build_lut(r, sun_y)
    sun_dir = np.array([np.sqrt(max(1 - sun_y * sun_y, 0)), sun_y, 0.0])
    moon_dir = -sun_dir

    def fogged_at(e_deg):
        y = np.sin(np.radians(e_deg))
        d = np.array([np.cos(np.radians(e_deg)), y, 0.0])
        sky = S.get_sky_color(d, hz, lut_sun, lut_moon, sun_dir, moon_dir)
        scene = S.luma(sky) + S.luma(S.get_sun_disk(d, sun_dir, cam_y))
        fd = d.copy()
        if band is None:
            fd[1] = min(fd[1], 0.0)            # 现状：硬钳制
        else:
            s = S.smoothstep(0.0, band, fd[1])  # 修复方向：平滑过渡带
            fd[1] = fd[1] * s
        fog_col = S.luma(S.get_sky_color(fd, hz, lut_sun, lut_moon, sun_dir, moon_dir))
        f = S.fog_factor(y)
        return (1 - f) * scene + f * fog_col

    elevs = np.arange(-0.4, 1.21, 0.025)
    vals = [fogged_at(e) for e in elevs]
    # y=0 拐角强度：水平线下 / 上 0.1 度窗口平均斜率之差
    def slope(lo, hi):
        idx = [i for i, v in enumerate(elevs) if lo <= v <= hi]
        return (vals[idx[-1]] - vals[idx[0]]) / (elevs[idx[-1]] - elevs[idx[0]])
    s_below, s_above = slope(-0.10, -0.01), slope(0.01, 0.30)
    print(f"{label}: y=0 斜率 {s_below*100:+.1f}%/度 -> {s_above*100:+.1f}%/度  (突变 {abs(s_above-s_below)*100:.1f}%/度)")

profile_variant(63.0, -0.03, "晨昏带 · 现状硬钳制 min(y,0)      ")
profile_variant(63.0, -0.03, "晨昏带 · 平滑过渡带 B=0.08(4.6度)", band=0.08)
profile_variant(63.0, -0.03, "晨昏带 · 平滑过渡带 B=0.03(1.7度)", band=0.03)
profile_variant(63.0, 0.7,  "正午   · 现状硬钳制 min(y,0)      ")
profile_variant(63.0, 0.7,  "正午   · 平滑过渡带 B=0.08        ", band=0.08)
