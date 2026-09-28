# -*- coding: utf-8 -*-
# 地平线折点精细分析：打印 -0.6 度 ~ +2.5 度 的 scene / fogged 剖面与斜率（%/度），
# 量化 (a) 切线地平线 -0.255 度的 LUT 钳制拐角、(b) 水平线 0 度的雾色 min(y,0) 钳制拐角。
import numpy as np
import sim_horizon_line as S

def profile(cam_y, sun_y, label):
    r = S.EARTH_RADIUS + max(cam_y, 1.0)
    hz = S.horizon_geometry(r)
    lut_sun, lut_moon = S.build_lut(r, sun_y)
    sun_dir = np.array([np.sqrt(max(1 - sun_y * sun_y, 0)), sun_y, 0.0])
    moon_dir = -sun_dir

    elevs = np.arange(-0.60, 2.51, 0.025)
    print(f"\n===== {label} (sunY={sun_y}) =====")
    print(f"{'elev':>7} {'scene':>9} {'fogged':>9} {'sl_scene':>9} {'sl_fog':>9}")
    prev = None
    for e in elevs:
        y = np.sin(np.radians(e))
        d = np.array([np.cos(np.radians(e)), y, 0.0])
        sky = S.get_sky_color(d, hz, lut_sun, lut_moon, sun_dir, moon_dir)
        scene = S.luma(sky) + S.luma(S.get_sun_disk(d, sun_dir, cam_y))
        fog_dir = d.copy(); fog_dir[1] = min(fog_dir[1], 0.0)
        fog_col = S.luma(S.get_sky_color(fog_dir, hz, lut_sun, lut_moon, sun_dir, moon_dir))
        f = S.fog_factor(y)
        fogged = (1 - f) * scene + f * fog_col
        if prev is not None:
            ds = (scene - prev[1]) / (e - prev[0])
            df = (fogged - prev[2]) / (e - prev[0])
            print(f"{e:7.3f} {scene:9.4f} {fogged:9.4f} {ds*100:8.2f}% {df*100:8.2f}%")
        else:
            print(f"{e:7.3f} {scene:9.4f} {fogged:9.4f}")
        prev = (e, scene, fogged)

    # 斜率突变量化：在切线(-0.255)与水平(0)各取上下 0.1 度窗口的平均斜率对比
    def slope(vals, es, lo, hi):
        idx = [i for i, v in enumerate(es) if lo <= v <= hi]
        a, b = idx[0], idx[-1]
        return (vals[b] - vals[a]) / (es[b] - es[a])
    es = elevs
    sc, fg = [], []
    for e in elevs:
        y = np.sin(np.radians(e))
        d = np.array([np.cos(np.radians(e)), y, 0.0])
        sky = S.get_sky_color(d, hz, lut_sun, lut_moon, sun_dir, moon_dir)
        scene = S.luma(sky) + S.luma(S.get_sun_disk(d, sun_dir, cam_y))
        fog_dir = d.copy(); fog_dir[1] = min(fog_dir[1], 0.0)
        fog_col = S.luma(S.get_sky_color(fog_dir, hz, lut_sun, lut_moon, sun_dir, moon_dir))
        f = S.fog_factor(y)
        sc.append(scene); fg.append((1 - f) * scene + f * fog_col)
    sc = np.array(sc); fg = np.array(fg)
    for name, vals in (("scene", sc), ("fogged", fg)):
        s_below_t = slope(vals, es, -0.40, -0.28)   # 切线下方
        s_above_t = slope(vals, es, -0.23, -0.10)   # 切线上方
        s_below_0 = slope(vals, es, -0.12, -0.02)   # 水平线下方
        s_above_0 = slope(vals, es, +0.02, +0.30)   # 水平线上方（雾平台）
        print(f"  [{name}] 切线拐角: {s_below_t*100:+.1f}%/度 -> {s_above_t*100:+.1f}%/度   "
              f"水平拐角: {s_below_0*100:+.1f}%/度 -> {s_above_0*100:+.1f}%/度")

profile(63.0, 0.0,  "日出瞬间（太阳在地平线）")
profile(63.0, -0.03, "晨昏带（太阳 -1.7 度，无日盘）")
profile(63.0, 0.7,  "正午对照")
