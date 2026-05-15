"""
ADRC（自抗扰控制）控制器 + Smith Predictor。

移植自 MATLAB +sim/runSim.m (lines 53–65, 119–141)。

理论
----
一阶 ADRC 由扩展状态观测器（ESO）+ 控制律组成：

ESO（连续时间）：
    ż₁ = -2ω₀z₁ + z₂ + b₀u + 2ω₀y
    ż₂ = -ω₀²z₁ + ω₀²y

精确 ZOH 离散化（scipy.linalg.expm），与 MATLAB expm(Maug·DT) 数值等价：
    Aᵤ = [-2ω₀,  1]   Bᵤ = [b₀,   2ω₀ ]
         [-ω₀², 0]         [0,    ω₀² ]
    Maug = [[Aᵤ, Bᵤ], [0, 0]]
    Φ = expm(Maug·DT)
    Aᵈ = Φ[:2,:2]  Bᵈ = Φ[:2,2:4]   # Bᵈ 列：[输入u, 输出y]

控制律（含设定值微分前馈）：
    u₀ = ωc·(r - z₁) + ṙ
    u  = (u₀ - z₂) / b₀
    v  = clip(u, 0, v_max)

Smith Predictor（可选）：
    并联运行无时延的 FOPDT 模型：
        ẏ_model = (K·u_eff - y_model) / τ     (Euler, 1ms 步长)
    y_eso = y_meas + (y_model_now - y_model_θ_ago)
    消除植物纯滞后对 ESO 的影响，允许更高带宽。
"""
from __future__ import annotations

from typing import Optional

import numpy as np
from scipy.linalg import expm


def build_eso_matrices(
    K: float, tau_s: float, w0: float, dt: float
) -> tuple[np.ndarray, np.ndarray, float]:
    """
    精确 ZOH 离散化 ESO 矩阵，与 MATLAB expm(Maug*DT_PID) 数值等价。

    参数
    ----
    K     : 植物静态增益 nm/V
    tau_s : 植物时间常数 s
    w0    : ESO 带宽 rad/s
    dt    : 控制器更新周期 s

    返回
    ----
    (Ad, Bd, b0)
        Ad  : 2×2 状态转移矩阵
        Bd  : 2×2 输入矩阵（列：[u, y]）
        b0  : 系统增益 = K/τ
    """
    b0  = K / tau_s
    A_c = np.array([[-2.0 * w0,  1.0      ],
                    [-w0 ** 2,   0.0      ]])
    B_c = np.array([[b0,         2.0 * w0 ],
                    [0.0,        w0 ** 2  ]])
    Maug = np.block([[A_c,             B_c             ],
                     [np.zeros((2, 2)), np.zeros((2, 2))]])
    Phi = expm(Maug * dt)
    return Phi[:2, :2], Phi[:2, 2:4], b0


class ADRCController:
    """
    一阶 ADRC 控制器（精确 ZOH ESO + 带宽参数化控制律）。

    用法
    ----
    ctrl = ADRCController(K=410, tau_s=0.08, wc=20, w0=100, dt=0.05, v_max=5)
    while running:
        v = ctrl.update(setpoint_nm, y_meas_nm)
        moku.set_voltage(channel, v)
    """

    def __init__(
        self,
        K: float,
        tau_s: float,
        wc: float,
        w0: float,
        dt: float,
        v_max: float,
    ) -> None:
        """
        参数
        ----
        K     : 植物增益 nm/V
        tau_s : 时间常数 s
        wc    : 控制器带宽 rad/s
        w0    : ESO 带宽 rad/s（通常 5·ωc）
        dt    : 控制器更新周期 s
        v_max : 电压上限 V
        """
        self.Ad, self.Bd, self.b0 = build_eso_matrices(K, tau_s, w0, dt)
        self.wc    = wc
        self.v_max = v_max
        self.dt    = dt
        self.z     = np.zeros(2)   # [z₁≈输出, z₂≈总扰动]
        self.sp_prev  = 0.0
        self._last_v  = 0.0        # 上一步输出（供 ESO 使用）

    def reset(self) -> None:
        self.z[:] = 0.0
        self.sp_prev = 0.0
        self._last_v = 0.0

    def update(self, setpoint: float, y_meas: float) -> float:
        """
        单步更新 ESO + 控制律，返回控制电压（V）。

        参数
        ----
        setpoint : 目标位移 nm
        y_meas   : 实测（或 Smith 修正后）位移 nm
        """
        # ESO 状态更新
        self.z = self.Ad @ self.z + self.Bd @ np.array([self._last_v, y_meas])

        # 设定值微分前馈（与 MATLAB sp_dot 一致）
        sp_dot = (setpoint - self.sp_prev) / self.dt
        self.sp_prev = setpoint

        # 控制律
        u0 = self.wc * (setpoint - self.z[0]) + sp_dot
        v  = (u0 - self.z[1]) / self.b0
        self._last_v = float(np.clip(v, 0.0, self.v_max))
        return self._last_v


class SmithPredictor:
    """
    Smith Predictor：并联 FOPDT 模型，消除植物纯滞后对 ESO 的影响。

    在每次控制器更新（dt_control）时，用 Euler 法积分
    dead-time-free 模型若干步（dt_int=1ms），并维护循环延迟缓冲区。

    修正量 = y_model_now - y_model_θ_ago
    """

    def __init__(
        self,
        K: float,
        tau_s: float,
        theta_plant_s: float,
        v_dead: float = 0.0,
        dt_int: float = 1e-3,
    ) -> None:
        self.K       = K
        self.tau     = tau_s
        self.v_dead  = v_dead
        self.dt_int  = dt_int

        buf_len = max(1, round(theta_plant_s / dt_int))
        self._buf     = np.zeros(buf_len)
        self._buf_idx = 0
        self._y_model = 0.0

    def update(self, v_ctrl: float, n_steps: int) -> float:
        """
        积分模型 n_steps × dt_int 秒并更新延迟缓冲区。

        参数
        ----
        v_ctrl  : 当前控制电压 V
        n_steps : Euler 积分步数（通常 = dt_control / dt_int）

        返回
        ----
        Smith 修正量 = y_model_now - y_model_θ_plant_ago（nm）
        """
        u_eff = max(0.0, v_ctrl - self.v_dead)
        y_delayed = 0.0
        for _ in range(n_steps):
            self._y_model += (
                (self.K * u_eff - self._y_model) / self.tau * self.dt_int
            )
            y_delayed = self._buf[self._buf_idx]
            self._buf[self._buf_idx] = self._y_model
            self._buf_idx = (self._buf_idx + 1) % len(self._buf)
        return self._y_model - y_delayed

    def reset(self) -> None:
        self._y_model = 0.0
        self._buf[:] = 0.0
        self._buf_idx = 0
