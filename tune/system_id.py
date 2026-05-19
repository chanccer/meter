"""阶跃响应辨识：AutoTuner (FOPDT 拟合 + PID 整定) + identify_model + 协议延迟测量。"""
from __future__ import annotations

import logging
import time
from datetime import datetime
from typing import Optional

import numpy as np
from scipy.optimize import curve_fit

from config import Config
from hardware import MokuController, UMD2Reader
from models import AutoTuneResult, ModelParams
from utils import DataStore


class AutoTuner:
    """
    基于阶跃响应辨识的 PID 自动整定器。

    流程：
    1. 施加电压阶跃，采集带时间戳的位移响应
    2. 拟合一阶加纯滞后（FOPDT）模型：G(s) = K·e^(-θs)/(τs+1)
    3. 按 IMC 或 Ziegler-Nichols 规则计算 Kp、Ki
    """

    def __init__(
        self,
        cfg: Config,
        umd2: UMD2Reader,
        moku: MokuController,
        logger: logging.Logger,
    ) -> None:
        self._cfg = cfg
        self._umd2 = umd2
        self._moku = moku
        self._log = logger

    def run(self) -> AutoTuneResult:
        from tune.imc import imc_tune_from_model

        cfg = self._cfg
        ch = cfg.moku_channel
        v_low, v_high = cfg.autotune_v_low, cfg.autotune_v_high
        delta_v = v_high - v_low

        if abs(delta_v) < 0.1:
            return AutoTuneResult(False, "阶跃幅度过小（< 0.1V），请检查 AUTOTUNE_V_LOW/HIGH")

        print(f"\n{'=' * 40}")
        print("PID 自动整定（阶跃响应法）")
        print(f"{'=' * 40}")
        print(f"阶跃：{v_low:.2f}V → {v_high:.2f}V  (ΔV={delta_v:+.2f}V)")
        print(f"采集：{cfg.autotune_collect_s:.1f}s  方法：{cfg.autotune_method}")

        print("\n[1/4] 稳定至初始电压…")
        self._moku.set_voltage(ch, v_low)
        time.sleep(max(cfg.settle_time * 6, 2.0))
        self._umd2.flush_queue()
        pre = self._umd2.read_displacement(50)
        y0 = float(np.mean(pre)) if pre else 0.0
        self._log.info(f"[AutoTune] 初始位移 y0={y0:.1f}nm")

        print(f"[2/4] 施加阶跃，采集 {cfg.autotune_collect_s:.1f}s 响应…")
        self._moku.set_voltage(ch, v_high)
        t_arr, d_arr = self._umd2.read_displacement_timed(cfg.autotune_collect_s)

        if len(t_arr) < 30:
            self._moku.set_voltage(ch, v_low)
            return AutoTuneResult(False, f"采集数据不足（{len(t_arr)} 帧），请检查 µMD2 连接")

        t_np = np.array(t_arr)
        d_np = np.array(d_arr)
        self._log.info(f"[AutoTune] 采集 {len(t_arr)} 帧，末段均值={np.mean(d_np[-20:]):.1f}nm")

        print("[3/4] 拟合 FOPDT 模型…")
        try:
            K, tau, theta = self._fit_fopdt(t_np, d_np, y0, delta_v)
        except Exception as e:
            self._moku.set_voltage(ch, v_low)
            return AutoTuneResult(False, f"模型拟合失败: {e}")

        if K <= 0 or tau <= 0:
            self._moku.set_voltage(ch, v_low)
            return AutoTuneResult(False, f"拟合结果异常 K={K:.1f} τ={tau:.4f}")

        print("[4/4] 计算 PID 增益…")
        if cfg.autotune_method.upper() == "ZN":
            kp, ki = self._gains_zn(K, tau, theta)
        else:
            # 使用统一的 IMC 公式（含全部环路延迟）
            gains = imc_tune_from_model(
                K=K, tau_s=tau, theta_plant_s=theta,
                theta_sensor_s=0.0,
                dt_control_s=cfg.pid_loop_interval,
            )
            kp = gains["PID"]["kp"]
            ki = gains["PID"]["ki"]

        self._moku.set_voltage(ch, v_low)
        time.sleep(cfg.settle_time)

        result = AutoTuneResult(
            success=True, message="整定成功",
            K_nm_per_V=K, tau_s=tau, theta_s=theta,
            kp=kp, ki=ki, method=cfg.autotune_method.upper(),
        )
        self._print_result(result)
        return result

    @staticmethod
    def _fopdt_model(
        t: np.ndarray, K: float, tau: float, theta: float, y0: float, delta_v: float
    ) -> np.ndarray:
        tau = max(tau, 1e-6)
        return np.where(
            t > theta,
            y0 + K * delta_v * (1.0 - np.exp(-(t - theta) / tau)),
            y0,
        )

    def _fit_fopdt(
        self, t: np.ndarray, d: np.ndarray, y0: float, delta_v: float
    ) -> tuple[float, float, float]:
        y_inf_est = float(np.mean(d[max(len(d) - max(len(d) // 5, 10), 0):]))
        K0 = (y_inf_est - y0) / delta_v if abs(delta_v) > 0.01 else 410.0
        tau0 = float(t[-1]) / 4.0
        theta0 = min(0.02, float(t[-1]) / 10.0)

        def model(t_arr: np.ndarray, K: float, tau: float, theta: float) -> np.ndarray:
            return self._fopdt_model(t_arr, K, tau, theta, y0, delta_v)

        popt, _ = curve_fit(
            model, t, d,
            p0=[K0, tau0, theta0],
            bounds=([1.0, 1e-4, 0.0], [5000.0, 60.0, 10.0]),
            maxfev=8000,
        )
        return float(popt[0]), float(popt[1]), float(popt[2])

    @staticmethod
    def _gains_zn(K: float, tau: float, theta: float) -> tuple[float, float]:
        theta = max(theta, 1e-4)
        kp = 0.9 * tau / (K * theta)
        ki = kp / (3.33 * theta)
        return kp, ki

    @staticmethod
    def _print_result(r: AutoTuneResult) -> None:
        print(f"\n{'─' * 40}")
        print("模型识别结果（FOPDT）：")
        print(f"  增益     K  = {r.K_nm_per_V:.1f} nm/V")
        print(f"  时间常数 τ  = {r.tau_s * 1e6:.1f} µs")
        print(f"  纯滞后   θ  = {r.theta_s * 1e6:.1f} µs")
        print(f"\n整定结果（{r.method}）：")
        print(f"  Kp = {r.kp:.6f} V/nm")
        print(f"  Ki = {r.ki:.6f} V/(nm·s)")
        print(f"  Kd = 0.0  （保持关闭）")
        print(f"\n如需永久保存，请将以上值写入 config.py 顶部配置。")
        print(f"{'─' * 40}")


def measure_protocol_delay(
    cfg: Config,
    umd2: UMD2Reader,
    moku: MokuController,
    logger: logging.Logger,
) -> tuple[float, float]:
    """
    测量通信协议延迟，分解为两部分：

    1. t_moku_us  — Moku set_voltage() 调用耗时
    2. t_frame_us — µMD2 帧到达延迟

    返回：(t_moku_us, t_frame_us)
    """
    reps  = cfg.proto_delay_reps
    ch    = cfg.moku_channel
    v_ref = cfg.step_ident_v_low

    print(f"\n  [协议延迟测量] 重复 {reps} 次…", end=" ", flush=True)

    moku.set_voltage(ch, v_ref)
    time.sleep(0.3)
    cmd_times: list[float] = []
    for _ in range(reps):
        t0 = time.monotonic()
        moku.set_voltage(ch, v_ref)
        cmd_times.append((time.monotonic() - t0) * 1e6)
    t_moku_us = float(np.mean(cmd_times))

    umd2.flush_queue()
    frame_times: list[float] = []
    for _ in range(reps):
        ft = umd2.measure_frame_interval(timeout=0.5)
        if ft is not None:
            frame_times.append(ft * 1e6)
    t_frame_us = float(np.mean(frame_times)) if frame_times else 0.0

    t_protocol_us = t_moku_us + t_frame_us
    print(f"Moku={t_moku_us:.2f}µs  帧={t_frame_us:.2f}µs  合计={t_protocol_us:.2f}µs")
    logger.info(
        f"[协议延迟] Moku命令={t_moku_us:.2f}µs  "
        f"串口/USB帧={t_frame_us:.2f}µs  "
        f"总协议延迟={t_protocol_us:.2f}µs"
    )
    return t_moku_us, t_frame_us


def identify_model(
    cfg: Config,
    temp_C: float,
    umd2: UMD2Reader,
    moku: MokuController,
    logger: logging.Logger,
    lut_store: Optional[DataStore] = None,
) -> Optional[ModelParams]:
    """
    在当前温度下执行阶跃响应辨识，提取 FOPDT 模型参数 K、τ、θ。

    重复 cfg.step_ident_reps 次后取均值，降低噪声影响。
    """
    ch      = cfg.moku_channel
    v_low   = cfg.step_ident_v_low
    v_high  = cfg.step_ident_v_high
    reps    = cfg.step_ident_reps
    delta_v = v_high - v_low

    if abs(delta_v) < 0.1:
        logger.warning("[模型辨识] 阶跃幅度不足，跳过")
        return None

    print(f"\n{'─' * 40}")
    print(f"[模型辨识] {temp_C}°C  阶跃 {v_low:.1f}→{v_high:.1f}V  重复 {reps} 次")

    t_moku_us, t_frame_us = measure_protocol_delay(cfg, umd2, moku, logger)
    t_protocol_us = t_moku_us + t_frame_us

    tuner = AutoTuner(cfg, umd2, moku, logger)
    Ks: list[float] = []
    taus: list[float] = []
    thetas: list[float] = []
    r2s: list[float] = []

    for rep in range(1, reps + 1):
        print(f"  [{rep}/{reps}] 稳定初始电压…", end=" ", flush=True)
        moku.set_voltage(ch, v_low)
        time.sleep(max(cfg.settle_time * 6, 2.0))
        umd2.flush_queue()
        pre = umd2.read_displacement(50)
        y0 = float(np.mean(pre)) if pre else 0.0

        moku.set_voltage(ch, v_high)
        t_arr, d_arr = umd2.read_displacement_timed(cfg.step_ident_collect_s)

        if len(t_arr) < 30:
            logger.warning(f"[模型辨识] 第 {rep} 次采集不足 ({len(t_arr)} 帧)，跳过")
            continue

        t_np = np.array(t_arr)
        d_np = np.array(d_arr)
        try:
            K, tau, theta = tuner._fit_fopdt(t_np, d_np, y0, delta_v)
            if K <= 0 or tau <= 0:
                logger.warning(f"[模型辨识] 第 {rep} 次拟合结果异常 K={K:.1f}")
                continue
            fitted = AutoTuner._fopdt_model(t_np, K, tau, theta, y0, delta_v)
            ss_res = float(np.sum((d_np - fitted) ** 2))
            ss_tot = float(np.sum((d_np - float(np.mean(d_np))) ** 2))
            r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 0.0
            Ks.append(K); taus.append(tau); thetas.append(theta); r2s.append(r2)
            print(f"K={K:.0f}nm/V  τ={tau*1e6:.0f}µs  θ={theta*1e6:.1f}µs  R²={r2:.3f}")
        except Exception as e:
            logger.warning(f"[模型辨识] 第 {rep} 次拟合异常: {e}")

    moku.set_voltage(ch, v_low)
    time.sleep(cfg.settle_time)

    if not Ks:
        logger.error("[模型辨识] 所有辨识均失败")
        return None

    K_mean     = float(np.mean(Ks))
    tau_mean   = float(np.mean(taus))
    theta_mean = float(np.mean(thetas))
    r2_mean    = float(np.mean(r2s))

    noise_rms = 0.0
    v_dead    = 0.0
    if lut_store is not None:
        df = lut_store.to_dataframe()
        if not df.empty and "std_nm" in df.columns:
            up_df = df[
                (df["temperature_C"] == temp_C) & (df["direction"] == "up")
            ].sort_values("voltage_V")
            if not up_df.empty:
                noise_rms = float(up_df["std_nm"].mean())
                baseline  = float(up_df.iloc[0]["mean_nm"])
                threshold = baseline + max(3.0 * noise_rms, 10.0)
                for _, row in up_df.iterrows():
                    if float(row["mean_nm"]) > threshold:
                        v_dead = float(row["voltage_V"])
                        break

    theta_total_us = theta_mean * 1e6
    theta_piezo_us = max(0.0, theta_total_us - t_protocol_us)

    params = ModelParams(
        temperature_C=temp_C,
        K_nm_per_V=K_mean,
        tau_us=tau_mean * 1e6,
        theta_us=theta_total_us,
        v_dead_V=v_dead,
        r2_fit=r2_mean,
        noise_rms_nm=noise_rms,
        theta_piezo_us=theta_piezo_us,
        theta_protocol_us=t_protocol_us,
        timestamp=datetime.now().isoformat(timespec="seconds"),
    )

    print(f"\n  结果（{len(Ks)}/{reps} 次有效）：")
    print(f"  K           = {K_mean:.1f} nm/V")
    print(f"  τ           = {tau_mean*1e6:.1f} µs")
    print(f"  θ 总        = {theta_total_us:.1f} µs")
    print(f"    θ_piezo   = {theta_piezo_us:.1f} µs  (机械延迟)")
    print(f"    θ_protocol= {t_protocol_us:.1f} µs  "
          f"(Moku{t_moku_us:.1f}µs + 串口/USB{t_frame_us:.1f}µs)")
    print(f"  V_dead      = {v_dead:.2f} V")
    print(f"  R²          = {r2_mean:.4f}")
    print(f"  噪声        ≈ {noise_rms:.1f} nm RMS")
    print(f"{'─' * 40}")
    return params
