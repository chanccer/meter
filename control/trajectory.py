"""轨迹跟踪控制：TrajectoryGenerator + run_trajectory_control()。"""
from __future__ import annotations

import logging
import time
from pathlib import Path
from typing import TYPE_CHECKING, Optional

import numpy as np

from config import Config
from models import ModelParams, TrajectoryResult

if TYPE_CHECKING:
    from data import PiezoLUT
    from hardware import MokuController, UMD2Reader

_SUPPORTED_WAVEFORMS = ("sine", "triangle", "sawtooth", "square")


class TrajectoryGenerator:
    """生成离散化轨迹设定值序列。

    step(k) 返回第 k 步的 (setpoint_nm, velocity_nm_per_s)。
    velocity 仅供调试/记录，控制器内部不直接使用（ADRC 通过 sp_dot 自动处理）。
    """

    def __init__(
        self,
        waveform: str,
        freq_hz: float,
        amp_nm: float,
        offset_nm: float,
        dt: float,
        tau_s: float,
        logger: logging.Logger,
    ) -> None:
        if waveform not in _SUPPORTED_WAVEFORMS:
            raise ValueError(f"不支持的波形: {waveform!r}，可选: {_SUPPORTED_WAVEFORMS}")
        self.waveform  = waveform
        self.freq_hz   = freq_hz
        self.amp_nm    = amp_nm
        self.offset_nm = offset_nm
        self.dt        = dt
        self._w        = 2.0 * np.pi * freq_hz   # 角频率

        bw_hz = 1.0 / (2.0 * np.pi * tau_s)
        self.bandwidth_warning = freq_hz > bw_hz
        if self.bandwidth_warning:
            logger.warning(
                f"[轨迹] {freq_hz:.2f} Hz 超出系统 -3dB 带宽 {bw_hz:.2f} Hz，"
                f"跟踪幅度将衰减约 {1/np.sqrt(1+(freq_hz/bw_hz)**2):.1%}"
            )

    def step(self, k: int) -> tuple[float, float]:
        """返回 (setpoint_nm, velocity_nm_per_s) 第 k 步。"""
        t = k * self.dt
        w, A, o = self._w, self.amp_nm, self.offset_nm

        if self.waveform == "sine":
            sp  = o + A * np.sin(w * t)
            vel = A * w * np.cos(w * t)

        elif self.waveform == "triangle":
            # 周期内相位 [0,1)，折叠成三角
            phase = (t * self.freq_hz) % 1.0
            if phase < 0.5:
                sp = o - A + 4 * A * phase
            else:
                sp = o + A - 4 * A * (phase - 0.5)
            vel = 4 * A * self.freq_hz * (1 if phase < 0.5 else -1)

        elif self.waveform == "sawtooth":
            phase = (t * self.freq_hz) % 1.0
            sp  = o - A + 2 * A * phase
            vel = 2 * A * self.freq_hz

        else:  # square
            sp  = o + A * float(np.sign(np.sin(w * t)) or 1.0)
            vel = 0.0

        return float(sp), float(vel)

    def initial_position(self) -> float:
        return self.step(0)[0]


def run_trajectory_control(
    waveform: str,
    freq_hz: float,
    amp_nm: float,
    offset_nm: float,
    duration_s: float,
    cfg: Config,
    umd2: "UMD2Reader",
    moku: "MokuController",
    logger: logging.Logger,
    lut: Optional["PiezoLUT"] = None,
    temperature_C: float = 25.0,
    model: Optional[ModelParams] = None,
) -> TrajectoryResult:
    """
    ADRC 轨迹跟踪控制循环。

    流程
    ----
    1. 初始化 ADRC 控制器（使用辨识模型或 cfg 默认值）
    2. 可选：用 LUT 前馈将 Piezo 移动到轨迹起始点附近
    3. 以 cfg.pid_loop_interval 为步长循环跟踪轨迹
    4. 计算 RMSE / 最大误差后返回 TrajectoryResult
    """
    from control.adrc import ADRCController, SmithPredictor
    from control.loop import _lut_feedforward
    from tune.imc import imc_tune_from_model

    dt      = cfg.pid_loop_interval
    v_min   = cfg.v_start
    v_max   = cfg.v_end
    channel = cfg.moku_channel

    # ── 植物参数 ─────────────────────────────────────────────────────────────
    K              = model.K              if model else cfg.adrc_K
    tau_s          = model.tau_s          if model else cfg.adrc_tau_us * 1e-6
    theta_plant_s  = model.theta_plant_s  if model else 0.0
    theta_sensor_s = model.theta_sensor_s if model else 0.0
    v_dead         = model.v_dead_V       if model else 0.0

    use_smith = cfg.adrc_smith

    # ── IMC 自动计算带宽 ──────────────────────────────────────────────────────
    if cfg.adrc_wc == 20.0 and cfg.adrc_w0 == 100.0 and model is not None:
        gains = imc_tune_from_model(
            K=K, tau_s=tau_s,
            theta_plant_s=theta_plant_s,
            theta_sensor_s=theta_sensor_s,
            dt_control_s=dt,
            smith=use_smith,
        )
        wc = gains["ADRC"]["adrc_wc"]
        w0 = gains["ADRC"]["adrc_w0"]
    else:
        wc = cfg.adrc_wc
        w0 = cfg.adrc_w0

    # ── 轨迹生成器 ───────────────────────────────────────────────────────────
    generator = TrajectoryGenerator(
        waveform=waveform, freq_hz=freq_hz, amp_nm=amp_nm,
        offset_nm=offset_nm, dt=dt, tau_s=tau_s, logger=logger,
    )

    # ── 打印头部 ──────────────────────────────────────────────────────────────
    smith_tag = " [Smith]" if use_smith else ""
    N = max(1, round(duration_s / dt))
    print(f"\n{'=' * 40}")
    print("ADRC 轨迹跟踪")
    print(f"{'=' * 40}")
    print(f"波形     : {waveform}  f={freq_hz:.3f}Hz  A=±{amp_nm:.0f}nm  中心={offset_nm:.0f}nm")
    print(f"时长     : {duration_s:.1f}s  ({N} 步 × {dt*1e6:.1f}µs)")
    print(f"ADRC{smith_tag}  ωc={wc:.1f} rad/s  ω₀={w0:.1f} rad/s")
    print(f"植物模型 : K={K:.0f}nm/V  τ={tau_s*1e6:.1f}µs  θ_p={theta_plant_s*1e6:.1f}µs")
    if generator.bandwidth_warning:
        print(f"  ⚠ 频率 {freq_hz:.2f} Hz 超出系统带宽，跟踪幅度将衰减")

    # ── 控制器初始化 ──────────────────────────────────────────────────────────
    ctrl = ADRCController(K=K, tau_s=tau_s, wc=wc, w0=w0, dt=dt, v_max=v_max)
    smith_pred: Optional[SmithPredictor] = None
    if use_smith and theta_plant_s > 0:
        n_int = max(1, round(dt / 1e-3))
        smith_pred = SmithPredictor(
            K=K, tau_s=tau_s, theta_plant_s=theta_plant_s,
            v_dead=v_dead, dt_int=dt / n_int,
        )

    # ── 起始位置初始化（可选 LUT 前馈）───────────────────────────────────────
    d0 = generator.initial_position()
    v_init = _lut_feedforward(
        lut, umd2, temperature_C, d0, v_min, v_max, "TRAJ", logger
    )
    moku.set_voltage(channel, v_init)
    time.sleep(cfg.settle_time * 2)
    umd2.flush_queue()

    raw_init = umd2.read_displacement(cfg.pid_sample_avg, timeout=5.0)
    y_init = float(np.mean(raw_init)) if raw_init else d0
    ctrl.z = np.array([y_init, 0.0])   # 用实测位置初始化 ESO

    print(f"初始位置 : {y_init:.0f}nm  (目标起始={d0:.0f}nm)\n")
    print(f"    步骤     设定值(nm)   实测(nm)    误差(nm)   电压(V)")
    print(f"{'─'*60}")

    # ── 主轨迹循环 ────────────────────────────────────────────────────────────
    times_s:      list[float] = []
    setpoints_nm: list[float] = []
    measured_nm:  list[float] = []
    voltages_V:   list[float] = []
    t_loop_start = time.monotonic()

    for k in range(N):
        t_now = time.monotonic()
        sp, _ = generator.step(k)

        raw = umd2.read_displacement(cfg.pid_sample_avg, timeout=5.0)
        y = float(np.mean(raw)) if raw else (measured_nm[-1] if measured_nm else y_init)

        y_eso = y
        if smith_pred is not None:
            n_int = max(1, round(dt / smith_pred.dt_int))
            y_eso = y + smith_pred.update(ctrl._last_v, n_int)

        v = ctrl.update(sp, y_eso)
        moku.set_voltage(channel, v)

        t_elapsed = time.monotonic() - t_loop_start
        times_s.append(t_elapsed)
        setpoints_nm.append(sp)
        measured_nm.append(y)
        voltages_V.append(v)

        err = sp - y
        if k % max(1, N // 20) == 0 or k == N - 1:
            print(f"  {k+1:5d}  {sp:10.1f}  {y:10.1f}  {err:+10.1f}  {v:8.4f}")

        sleep_remain = dt - (time.monotonic() - t_now)
        if sleep_remain > 0:
            time.sleep(sleep_remain)

    # ── 计算指标 ──────────────────────────────────────────────────────────────
    sp_arr  = np.array(setpoints_nm)
    meas_arr = np.array(measured_nm)
    errors   = sp_arr - meas_arr
    rmse     = float(np.sqrt(np.mean(errors ** 2)))
    max_err  = float(np.max(np.abs(errors)))

    print(f"\n[轨迹完成] RMSE={rmse:.1f}nm  最大误差={max_err:.1f}nm  步数={N}")

    return TrajectoryResult(
        waveform=waveform,
        frequency_hz=freq_hz,
        amplitude_nm=amp_nm,
        offset_nm=offset_nm,
        duration_s=duration_s,
        times_s=times_s,
        setpoints_nm=setpoints_nm,
        measured_nm=measured_nm,
        voltages_V=voltages_V,
        rmse_nm=rmse,
        max_error_nm=max_err,
        bandwidth_warning=generator.bandwidth_warning,
    )
