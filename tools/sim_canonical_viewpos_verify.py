# screenToViewCanonical（space.glsl 新增的典则透视闭式重建）与 screenToView（通用 mat4 逆）数值等价验证
# 方法：构造 MC 典型典则对称透视矩阵（ftransform / gbufferProjection 同构，clip.w = -view.z），
#       在 (uv, depth) 网格上对比两条重建路径的 viewPos，误差应为机器精度级（float64 下 < 1e-9 相对误差）
# GLSL 索引对照（mat[col][row]，列主序）：gbufferProjection[2].z = P[2][2]、[3].z = P[2][3]（numpy [row][col]）

import numpy as np

def make_proj(fov_deg, aspect, near, far):
    f = 1.0 / np.tan(np.radians(fov_deg) / 2.0)
    A = (far + near) / (near - far)
    B = 2.0 * far * near / (near - far)
    # 行主序书写 == 列主序 GLSL 矩阵的转置；下面两种路径用同一份矩阵、元素取法与 GLSL 一致即可
    return np.array([
        [f / aspect, 0.0, 0.0, 0.0],
        [0.0, f, 0.0, 0.0],
        [0.0, 0.0, A, B],
        [0.0, 0.0, -1.0, 0.0],
    ])

def screen_to_view(P_inv, uv, depth):
    # screenToView：ndc = screenPos*2-1，view = P_inv * (ndc, 1)，再 /w
    ndc = np.array([uv[0] * 2.0 - 1.0, uv[1] * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0])
    v = P_inv @ ndc
    return v[:3] / v[3]

def screen_to_view_canonical(P, uv, depth):
    projC = P[2][2]  # GLSL gbufferProjection[2].z
    projD = P[2][3]  # GLSL gbufferProjection[3].z
    projXY = 1.0 / np.array([P[0][0], P[1][1]])
    ndc = np.array(uv) * 2.0 - 1.0
    viewZ = -projD / (depth * 2.0 - 1.0 + projC)
    return np.array([ndc[0] * projXY[0] * (-viewZ), ndc[1] * projXY[1] * (-viewZ), viewZ])

def main():
    worst = 0.0
    for fov, aspect, near, far in [
        (70.0, 16 / 9, 0.05, 1706.0),   # MC 默认 FOV、渲染距离 ~1706（far 平面）
        (110.0, 16 / 9, 0.05, 1706.0),  # 高 FOV 变体（速度效果等）
        (70.0, 21 / 9, 0.05, 512.0),    # 超宽 + 近 far（低渲染距离）
    ]:
        P = make_proj(fov, aspect, near, far)
        P_inv = np.linalg.inv(P)

        # 近/远平面端点自检
        assert abs(screen_to_view_canonical(P, (0.5, 0.5), 0.0)[2] + near) < 1e-6 * near
        assert abs(screen_to_view_canonical(P, (0.5, 0.5), 1.0)[2] + far) < 1e-6 * far

        for i in range(21):
            for j in range(21):
                uv = (i / 20.0, j / 20.0)
                for depth in (0.0, 0.25, 0.5, 0.75, 0.999, 1.0):
                    a = screen_to_view(P_inv, uv, depth)
                    b = screen_to_view_canonical(P, uv, depth)
                    rel = np.max(np.abs(a - b) / np.maximum(np.abs(a), 1e-6))
                    worst = max(worst, rel)
        print(f"fov={fov:5.1f} aspect={aspect:.2f} near={near} far={far}: worst rel err = {worst:.3e}")
    print("PASS" if worst < 1e-9 else "FAIL")

if __name__ == "__main__":
    main()
