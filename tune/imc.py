"""
IMC-PID / IMC-ADRC 自动整定公式。

移植自 MATLAB +sim/imcTune.m，公式完全等价。

关键原理
--------
IMC 公式需要闭环的**等效总纯滞后**（含所有环路延迟）：

    θ_eff = θ_plant + θ_sensor + DT_controller/2

其中 DT/2 是离散控制器的 ZOH 等效延迟（Åström & Hägglund 1995, Ch.8）。

PID 公式（Rivera et al. 1986，λ = 2·θ_eff 保守设定）：
    Kp = (τ + θ_eff/2) / [K·(λ + θ_eff/2)]
    Ki = Kp / (τ + θ_eff/2)
    Kd = Kp · τ·θ_plant / (2τ + θ_plant)   ← 仅用植物 θ，不是 θ_eff
    N  = round((2τ + θ_plant) / θ_plant)

ADRC：
    Smith Predictor 开启时 θ_eff_adrc = θ_sensor + DT/2（θ_plant 由 Smith 抵消）
    否则 θ_eff_adrc = θ_eff
    ωc = 1 / max(τ + θ_eff_adrc, 1e-6)
    ω0 = 5 · ωc
"""
from __future__ import annotations

from typing import Optional

from models import ModelParams


def imc_tune(
    model: ModelParams,
    dt_control_s: float,
    smith: bool = True,
) -> dict[str, dict[str, float]]:
    """
    根据 ModelParams 计算 IMC-PID 和 IMC-ADRC 增益。

    参数
    ----
    model         : 由 identify_model() 返回的 FOPDT 参数
    dt_control_s  : 控制器更新周期（s），对应 cfg.pid_loop_interval
    smith         : ADRC 是否启用 Smith Predictor（仅影响 ADRC 带宽计算）

    返回
    ----
    {
        'PID':  {'kp', 'ki', 'kd', 'd_filter_n'},
        'ADRC': {'adrc_wc', 'adrc_w0'},
    }
    """
    return imc_tune_from_model(
        K=model.K,
        tau_s=model.tau_s,
        theta_plant_s=model.theta_plant_s,
        theta_sensor_s=model.theta_sensor_s,
        dt_control_s=dt_control_s,
        smith=smith,
    )


def imc_tune_from_model(
    K: float,
    tau_s: float,
    theta_plant_s: float,
    theta_sensor_s: float,
    dt_control_s: float,
    smith: bool = True,
) -> dict[str, dict[str, float]]:
    """
    底层整定函数（接受原始数值，供 AutoTuner 等调用）。

    与 MATLAB imcTune.m 数值等价：
        theta_eff = theta_s + delay_s + dt_pid/2
        lam = 2 * theta_eff
        denom = tau_s + theta_eff/2
        kp = denom / (K * (lam + theta_eff/2))
        ki = kp / denom
        kd = kp * tau_s * theta_plant / (2*tau_s + max(theta_plant, 1e-9))
        n  = round((2*tau_s + theta_plant) / max(theta_plant, 1e-9))
    """
    theta_eff = theta_plant_s + theta_sensor_s + dt_control_s / 2.0

    # ── PID ─────────────────────────────────────────────────────────────
    lam   = 2.0 * theta_eff
    denom = tau_s + theta_eff / 2.0
    kp    = denom / (K * (lam + theta_eff / 2.0))
    ki    = kp / denom
    theta_p = max(theta_plant_s, 1e-9)
    kd    = kp * tau_s * theta_p / (2.0 * tau_s + theta_p)
    n     = round((2.0 * tau_s + theta_p) / theta_p)

    # ── ADRC ────────────────────────────────────────────────────────────
    if smith:
        theta_eff_adrc = theta_sensor_s + dt_control_s / 2.0
    else:
        theta_eff_adrc = theta_eff
    wc = 1.0 / max(tau_s + theta_eff_adrc, 1e-6)

    return {
        "PID":  {"kp": kp, "ki": ki, "kd": kd, "d_filter_n": float(n)},
        "ADRC": {"adrc_wc": wc, "adrc_w0": 5.0 * wc},
    }
