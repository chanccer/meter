"""
迟滞模型：Bouc-Wen (n=1) + 简单方向偏移。

移植自 MATLAB +sim/runSim.m（Bouc-Wen 部分，2026-05-14 新增）。

Bouc-Wen 增量方程 (n=1)：
    Δz = A·Δu - β|Δu|·z - γ·Δu·|z|
    y_hyst = -D · z

用于：
1. 仿真/测试：模拟压电迟滞特性
2. 前馈补偿：在给定目标位移时预估迟滞修正量（高级用法）

注意：实际硬件控制中，ADRC 的 ESO 会自动估计并补偿迟滞，
通常不需要显式调用 Bouc-Wen 前馈。
"""
from __future__ import annotations


class BoucWen:
    """
    Bouc-Wen 迟滞模型 (n=1)。

    参数
    ----
    A     : 前屈服斜率（通常 = 1.0）
    beta  : 耗散形状参数（β + γ > 0 保证稳定）
    gamma : 恢复形状参数
    D_nm  : 最大迟滞位移贡献 nm（β=γ=0.5 时最大 |z| ≈ A/(β+γ) = 1）

    用法
    ----
    model = BoucWen(A=1.0, beta=0.5, gamma=0.5, D_nm=30.0)
    for each control step:
        du = v_eff_now - v_eff_prev
        hyst_nm = model.step(du)   # 叠加到位移输出
    """

    def __init__(
        self,
        A: float = 1.0,
        beta: float = 0.5,
        gamma: float = 0.5,
        D_nm: float = 30.0,
    ) -> None:
        self.A     = A
        self.beta  = beta
        self.gamma = gamma
        self.D     = D_nm
        self.z     = 0.0   # 迟滞内部状态

    def step(self, du: float) -> float:
        """
        增量更新，返回迟滞位移修正量（nm）。

        参数
        ----
        du : 本步电压增量 Δu = v_eff[k] - v_eff[k-1]

        公式（与 MATLAB runSim.m 完全一致）：
            dz = A·du - β|du|·z - γ·du·|z|
            y_hyst = -D · z
        """
        dz = (
            self.A * du
            - self.beta * abs(du) * self.z
            - self.gamma * du * abs(self.z)
        )
        self.z += dz
        return -self.D * self.z

    def reset(self) -> None:
        self.z = 0.0


class SimpleHysteresis:
    """
    简单方向偏移迟滞（与旧版 main.py 行为一致）。

    电压下降时施加固定偏移 -hysteresis_nm，
    电压上升时偏移为 0。
    """

    def __init__(self, hysteresis_nm: float = 0.0) -> None:
        self.hysteresis_nm = hysteresis_nm
        self._prev_u = 0.0

    def step(self, u_eff: float) -> float:
        du = u_eff - self._prev_u
        self._prev_u = u_eff
        return -self.hysteresis_nm if du < 0 else 0.0

    def reset(self) -> None:
        self._prev_u = 0.0
