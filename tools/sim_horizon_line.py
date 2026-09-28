# -*- coding: utf-8 -*-
# 日出地平线硬边界排查：逐位复刻 春眠 的 sky-view LUT 生成(200x100 双半区) -> 采样(双线性+RGBA16F)
# -> 边界雾(composite2) 数学链，检查地平线附近亮度剖面的连续性(C0/C1 折点)。
# 只复刻 sky.glsl + atmosphere.glsl + fog.glsl 的解析部分；TAA/bloom 等对平滑场的处理不改变折点结论。

import numpy as np

# ---- constants.glsl ----
EARTH_RADIUS = 6360e3
SKY_NO_HIT = 1e30
RAYLEIGH_H = 320000.0
RAYLEIGH_BETA = np.array([6.384e-6, 12.00e-6, 28.74e-6])
MIE_H = 140000.0
MIE_SCATTER = np.array([1.252e-6, 1.689e-6, 2.530e-6])
MIE_EXTINCT = MIE_SCATTER * 1.11
OZONE_H = 455000.0
OZONE_EXTINCT = np.array([1.021e-6, 2.474e-6, 1.015e-7])
SOLAR = np.array([236.8, 206.4, 204.9])
MOON = SOLAR * 5e-4
SKY_BRIGHTNESS = 1.0
SKY_LIGHT_MIN_HEIGHT = -0.15
SKY_ERFCX_EXP_MAX = 80.0
SKY_AIRMASS_MAX = 1e15
MIE_G1 = 0.862
MIE_G2 = 0.5069161813017329
MIE_A = 250.0
MIE_W = 0.24075857115188248
# sun disk
SUN_DISK_RADIUS = 0.0188
SUN_DISK_SOFTEN = 0.0015
SUN_DISK_BRIGHTNESS = 450.0
# fog
BOUNDARY_FOG_ZENITH = 0.50
# LUT
SKYVIEW_W = 200
SKYVIEW_H = 100

PI = np.pi


def erfcx(x):
    x = np.asarray(x, dtype=np.float64)
    t = np.abs(x); t2 = t * t
    num = (0.56418958354775629
           * (t2 + 2.71078540045147805 * t + 5.80755613130301624)
           * (t2 + 3.47469513777439592 * t + 12.07402036406381411)
           * (t2 + 4.00561509202259545 * t + 9.30596659485887898)
           * (t2 + 5.16722705817812584 * t + 9.1266163077673262)
           * (t2 + 5.95908795446633271 * t + 9.19435612886969243))
    den = ((t + 2.06955023132914151)
           * (t2 + 3.47954057099518960 * t + 12.06166887286239555)
           * (t2 + 3.72068443960225092 * t + 8.44319731003968454)
           * (t2 + 3.90225704029924078 * t + 6.36161630953840464)
           * (t2 + 4.03296893109262491 * t + 5.13535430585651539)
           * (t2 + 4.11240942927450885 * t + 4.48640329523408675))
    y = num / den
    return np.where(x < 0.0, 2.0 * np.exp(np.minimum(t2, SKY_ERFCX_EXP_MAX)) - y, y)


def air_mass(r, z, t, H):
    a = 0.5 * np.sqrt(PI) * H * np.exp(-(r - EARTH_RADIUS) * (r + EARTH_RADIUS) / (H * H))
    b = r * z / H
    if t > 1e29:
        return np.clip(a * erfcx(b), 0.0, SKY_AIRMASS_MAX)
    c = t / H + b
    d = np.exp(np.minimum(b * b - c * c, SKY_ERFCX_EXP_MAX))
    if z >= 0.0 or t + r * z >= 0.0:
        return np.clip(a * (erfcx(b) - d * erfcx(c)), 0.0, SKY_AIRMASS_MAX)
    else:
        return np.clip(a * (d * erfcx(-c) - erfcx(-b)), 0.0, SKY_AIRMASS_MAX)


def optical_depth_to_space(r, z):
    return (RAYLEIGH_BETA * air_mass(r, z, SKY_NO_HIT, RAYLEIGH_H)
            + MIE_EXTINCT * air_mass(r, z, SKY_NO_HIT, MIE_H)
            + OZONE_EXTINCT * air_mass(r, z, SKY_NO_HIT, OZONE_H))


def planet_hit_distance(r, z):
    altitude_term = (r - EARTH_RADIUS) * (r + EARTH_RADIUS)
    d = r * r * z * z - altitude_term
    if d < 0.0:
        return SKY_NO_HIT
    root = np.sqrt(d)
    t1 = root - r * z
    t2 = -root - r * z
    t1 = SKY_NO_HIT if t1 < 0.0 else t1
    t2 = SKY_NO_HIT if t2 < 0.0 else t2
    return min(t1, t2)


def clamp_direction_to_horizon(r, d):
    horizon_cos = (-np.sqrt(max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0)) / r
                   if r > EARTH_RADIUS else 0.0)
    if d[1] >= horizon_cos:
        return np.array(d, dtype=np.float64), False
    h = np.array([d[0], d[2]], dtype=np.float64)
    hlen = np.linalg.norm(h)
    h = np.array([1.0, 0.0]) if hlen < 1e-4 else h / hlen
    hs = np.sqrt(max(1.0 - horizon_cos * horizon_cos, 0.0))
    return np.array([h[0] * hs, horizon_cos, h[1] * hs]), True


def rayleigh_phase(mu):
    return 3.0 / (16.0 * PI) * (1.0 + mu * mu)


def henyey_greenstein(mu):
    d = 1.0 + MIE_G1 * MIE_G1 - 2.0 * MIE_G1 * mu
    return 1.0 / (4.0 * PI) * (1.0 - MIE_G1 * MIE_G1) / (d * np.sqrt(d))


def draine(mu):
    d = 1.0 + MIE_G2 * MIE_G2 - 2.0 * MIE_G2 * mu
    return ((1.0 - MIE_G2 * MIE_G2) * (1.0 + MIE_A * mu * mu)
            / (4.0 * (1.0 + (MIE_A * (1.0 + 2.0 * MIE_G2 * MIE_G2)) / 3.0) * PI * d * np.sqrt(d)))


def mie_phase(mu):
    return (1.0 - MIE_W) * henyey_greenstein(mu) + MIE_W * draine(mu)


def energy_integral_ratio(a, b):
    x = b - a
    if np.abs(x) < 1e-4:
        return np.exp(-a) * (1.0 - x * 0.5)
    return (np.exp(-a) - np.exp(-b)) / x


def atmospheric_radiance_single(origin, direction, phase_direction, light_dir, tau_s, t, irradiance):
    zenith = origin / np.linalg.norm(origin)
    r = np.linalg.norm(origin)
    z = np.dot(direction, zenith)
    z_s = np.dot(light_dir, zenith)
    mu = np.dot(light_dir, phase_direction)
    mu_ray = np.dot(light_dir, direction)

    rayleigh_view = RAYLEIGH_BETA * air_mass(r, z, t, RAYLEIGH_H)
    mie_view = MIE_SCATTER * air_mass(r, z, t, MIE_H)
    ozone_view = OZONE_EXTINCT * air_mass(r, z, t, OZONE_H)
    tau_v = rayleigh_view + mie_view * 1.11 + ozone_view

    tau_sp = np.zeros(3)
    if t < 1e29:
        r_p = np.sqrt(t * t + 2.0 * z * r * t + r * r)
        z_sp = (z_s * r + mu_ray * t) / r_p
        tau_sp = optical_depth_to_space(r_p, z_sp)

    scatter = np.array([energy_integral_ratio(tau_s[i], tau_sp[i] + tau_v[i]) for i in range(3)])
    return irradiance * (rayleigh_view * rayleigh_phase(mu) + mie_view * mie_phase(mu)) * scatter


def sky_radiance_analytic(r, dir_world, light_world, tau_s, irradiance):
    origin = np.array([0.0, r, 0.0])
    ray_dir, clamped = clamp_direction_to_horizon(r, dir_world)
    t = SKY_NO_HIT if clamped else planet_hit_distance(r, ray_dir[1])
    return atmospheric_radiance_single(origin, ray_dir, dir_world, light_world, tau_s, t, irradiance) * SKY_BRIGHTNESS


def horizon_geometry(r):
    altitude_term = max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0)
    cos_beta = np.sqrt(altitude_term) / r
    beta = np.arccos(cos_beta)
    return np.array([cos_beta, beta, PI - beta])  # (cosBeta, beta, zenithHorizon)


# ---- LUT 生成（sky.glsl skyViewLutTexel 逐位） ----
def build_lut(r, sun_y):
    """返回 sun_half[100,200], moon_half[100,200]（行 j=0 天顶 ... j=99；列 a=0 光源侧）。"""
    hz = horizon_geometry(r)
    beta, zenith_horizon = hz[1], hz[2]

    sun_dir = np.array([np.sqrt(max(1 - sun_y * sun_y, 0)), sun_y, 0.0])
    moon_dir = -sun_dir
    tau_sun = optical_depth_to_space(r, sun_dir[1])
    tau_moon = optical_depth_to_space(r, moon_dir[1])

    lut_sun = np.zeros((SKYVIEW_H, SKYVIEW_W, 3))
    lut_moon = np.zeros((SKYVIEW_H, SKYVIEW_W, 3))
    for j in range(SKYVIEW_H):
        zenith_param = j / (SKYVIEW_H - 1)
        if zenith_param < 0.5:
            q = 1.0 - 2.0 * zenith_param
            vzc = np.cos(zenith_horizon * (1.0 - q * q))
        else:
            q = 2.0 * zenith_param - 1.0
            vzc = np.cos(zenith_horizon + beta * (q * q))
        vz_sin = np.sqrt(max(1.0 - vzc * vzc, 0.0))
        for i in range(SKYVIEW_W):
            azimuth_param = i / (SKYVIEW_W - 1)
            lv_cos = 1.0 - 2.0 * azimuth_param * azimuth_param
            lv_sin = np.sqrt(max(1.0 - lv_cos * lv_cos, 0.0))
            d = np.array([vz_sin * lv_cos, vzc, vz_sin * lv_sin])
            if sun_dir[1] > SKY_LIGHT_MIN_HEIGHT:
                lut_sun[j, i] = sky_radiance_analytic(r, d, sun_dir, tau_sun, SOLAR)
            if moon_dir[1] > SKY_LIGHT_MIN_HEIGHT:
                lut_moon[j, i] = sky_radiance_analytic(r, d, moon_dir, tau_moon, MOON)
    # RGBA16F 存储
    lut_sun = lut_sun.astype(np.float16).astype(np.float64)
    lut_moon = lut_moon.astype(np.float16).astype(np.float64)
    return lut_sun, lut_moon


# ---- 采样端（sky.glsl skyViewLutZenithParam / lutParamToTexelCenter 逐位） ----
def zenith_param(y, hz):
    vzc = np.clip(y, -1.0, 1.0)
    vzc_angle = np.arccos(vzc)
    if vzc >= -hz[0]:
        t = 1.0 - vzc_angle / hz[2]
        return (1.0 - np.sqrt(np.clip(t, 0.0, 1.0))) * 0.5
    else:
        t = (vzc_angle - hz[2]) / hz[1]
        return np.sqrt(np.clip(t, 0.0, 1.0)) * 0.5 + 0.5


def azimuth_param(dir_world, light_world):
    vzc = np.clip(dir_world[1], -1.0, 1.0)
    vz_sin = np.sqrt(max(1.0 - vzc * vzc, 0.0))
    sz_cos = np.clip(light_world[1], -1.0, 1.0)
    sz_sin = np.sqrt(max(1.0 - sz_cos * sz_cos, 0.0))
    view_h = np.array([1.0, 0.0]) if vz_sin <= 1e-4 else dir_world[[0, 2]] / vz_sin
    light_h = np.array([1.0, 0.0]) if sz_sin <= 1e-4 else light_world[[0, 2]] / sz_sin
    return np.sqrt(np.clip((1.0 - np.dot(view_h, light_h)) * 0.5, 0.0, 1.0))


def sample_half(lut, v, a):
    # localUv = lutParamToTexelCenter(p, res)；texel 域双线性
    texel_y = v * (SKYVIEW_H - 1) + 0.5
    texel_x = a * (SKYVIEW_W - 1) + 0.5
    fy = texel_y - 0.5; fx = texel_x - 0.5
    j0 = int(np.floor(fy)); i0 = int(np.floor(fx))
    ty = fy - j0; tx = fx - i0
    j0 = min(max(j0, 0), SKYVIEW_H - 1); j1 = min(j0 + 1, SKYVIEW_H - 1)
    i0 = min(max(i0, 0), SKYVIEW_W - 1); i1 = min(i0 + 1, SKYVIEW_W - 1)
    c00 = lut[j0, i0] * (1 - tx) * (1 - ty) + lut[j0, i1] * tx * (1 - ty)
    c10 = lut[j1, i0] * (1 - tx) * ty + lut[j1, i1] * tx * ty
    return c00 + c10


def get_sky_color(dir_world, hz, lut_sun, lut_moon, sun_dir, moon_dir):
    # 与真实 shader 一致：先 normalize（雾色方向经 y 钳制 / 释放后非单位，方位须精确保持）
    dir_world = dir_world / np.linalg.norm(dir_world)
    v = zenith_param(dir_world[1], hz)
    color = np.zeros(3)
    if sun_dir[1] > SKY_LIGHT_MIN_HEIGHT:
        color += sample_half(lut_sun, v, azimuth_param(dir_world, sun_dir))
    if moon_dir[1] > SKY_LIGHT_MIN_HEIGHT:
        color += sample_half(lut_moon, v, azimuth_param(dir_world, moon_dir))
    return color


def smoothstep(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def fog_factor(y_sin):
    zf = 1.0 - smoothstep(0.0, BOUNDARY_FOG_ZENITH, y_sin)
    f = zf * zf
    return f


def get_sun_disk(dir_world, sun_dir, cam_y):
    mu = np.dot(dir_world, sun_dir)
    edge_inner = 1.0 - np.cos(SUN_DISK_RADIUS)
    edge_outer = 1.0 - np.cos(SUN_DISK_RADIUS + SUN_DISK_SOFTEN)
    d = 1.0 - mu
    if d > edge_outer:
        return np.zeros(3)
    r = EARTH_RADIUS + max(cam_y, 1.0)
    if planet_hit_distance(r, dir_world[1]) < 1e29:
        return np.zeros(3)
    disk = 1.0 - smoothstep(edge_inner, edge_outer, d)
    trans = np.exp(-optical_depth_to_space(r, dir_world[1]))
    return SOLAR * trans * (SUN_DISK_BRIGHTNESS * disk)


def luma(c):
    return np.dot(c, np.array([0.2126, 0.7152, 0.0722]))


def analyze(cam_y, sun_y, label, elev_deg):
    r = EARTH_RADIUS + max(cam_y, 1.0)
    hz = horizon_geometry(r)
    lut_sun, lut_moon = build_lut(r, sun_y)
    sun_dir = np.array([np.sqrt(max(1 - sun_y * sun_y, 0)), sun_y, 0.0])
    moon_dir = -sun_dir

    horizon_tangent_deg = -np.degrees(np.arcsin(np.sqrt(max((r - EARTH_RADIUS) * (r + EARTH_RADIUS), 0.0)) / r))

    rows = []
    for e in elev_deg:
        e_rad = np.radians(e)
        y = np.sin(e_rad)
        d = np.array([np.cos(e_rad), y, 0.0])  # 太阳方位（a=0 侧）
        sky = get_sky_color(d, hz, lut_sun, lut_moon, sun_dir, moon_dir)
        disk = get_sun_disk(d, sun_dir, cam_y)
        scene = sky + disk
        # 边界雾（天空像素：distanceFactor=1）
        fog_dir = d.copy(); fog_dir[1] = min(fog_dir[1], 0.0)
        fog_col = get_sky_color(fog_dir, hz, lut_sun, lut_moon, sun_dir, moon_dir)
        f = fog_factor(y)
        fogged = (1 - f) * scene + f * fog_col
        rows.append((e, y, luma(sky), luma(scene), luma(fogged), luma(fog_col), f))
    rows = np.array(rows)

    print(f"\n===== {label}  (camera y={cam_y}, sunY={sun_y}, tangent horizon={horizon_tangent_deg:.3f} deg) =====")
    print(f"{'elev(deg)':>9} {'sinY':>9} {'sky':>10} {'scene':>10} {'fogged':>10} {'fogCol':>10} {'f':>7}")
    for row in rows:
        print(f"{row[0]:9.3f} {row[1]:9.5f} {row[2]:10.5f} {row[3]:10.5f} {row[4]:10.5f} {row[5]:10.5f} {row[6]:7.4f}")

    # 一阶差分（每 0.02 度）找折点：fogged 剖面的二阶差分
    for name, col in (("scene", 3), ("fogged", 4)):
        v = rows[:, col]
        d1 = np.diff(v)
        d2 = np.diff(d1)
        idx = np.argsort(np.abs(d2))[::-1][:5]
        print(f"  [{name}] 最大二阶差分处 (elev deg): " +
              ", ".join(f"{rows[i+1,0]:+.3f}({d2[i]:+.2e})" for i in sorted(idx)))
    return rows


if __name__ == "__main__":
    # 细扫地平线带（-1.5 度 ~ +8 度，步长 0.02 度）
    fine = np.arange(-1.5, 8.0, 0.02)
    analyze(63.0, 0.010, "日出：太阳中心 +0.57 度", fine)
    analyze(63.0, 0.0, "日出瞬间：太阳中心在地平线", fine)
    analyze(63.0, -0.030, "晨光：太阳 -1.7 度（晨昏带）", fine)
    # 对照：正午
    noon = np.arange(-1.5, 40.0, 0.05)
    analyze(63.0, 0.70, "对照：正午太阳仰角 44 度", noon)
