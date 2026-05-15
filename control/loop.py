"""闭环控制循环：PID 模式 + ADRC 模式 + 统一入口 run_control。"""
from __future__ import annotations

import logging
import time
from typing import Optional

import numpy as np

from config import Config
from data import PiezoLUT
from hardware import MokuController, UMD2Reader
from models import ModelParams, PIDResult
from utils import compute_stats

from control.pid import PIDController


def _lut_feedforward(
    lut: Optional[PiezoLUT],
    umd2: UMD2Reader,
    temperature_C: float,
    target_nm: float,
    v_min: float,
    v_max: float,
    tag: str,
    logger: logging.Logger,
) -> float:
    """
    查 LUT 得到前馈初始电压。

    处理三种退化情况：
    1. 无 LUT            → 返回 v_min
    2. 选定分支无数据    → 自动退用另一个分支
    3. 目标超出位移范围  → 使用端点电压并打印警告
    """
    if lut is None:
        print(f"无 LUT 前馈，从 {v_min:.2f}V 开始")
        return v_min

    try:
        raw_init = umd2.read_displacement(10, timeout=3.0)
        current_pos = float(np.mean(raw_init)) if raw_init else 0.0
        ff_dir = "up" if target_nm >= current_pos else "down"

        # 如果选定方向无数据，退用另一个方向
        avail = lut.available_directions()
        if ff_dir not in avail:
            alt = "down" if ff_dir == "up" else "up"
            if alt not in avail:
                raise ValueError("LUT 中没有任何方向数据")
            logger.warning(f"[{tag}] '{ff_dir}' 分支无数据，改用 '{alt}' 分支")
            ff_dir = alt

        # 检查目标是否在 LUT 的位移覆盖范围内
        nm_lo, nm_hi = lut.displacement_range(ff_dir)
        if not (nm_lo - 1 <= target_nm <= nm_hi + 1):
            logger.warning(
                f"[{tag}] 目标 {target_nm:.0f}nm 超出 LUT 位移范围 "
                f"[{nm_lo:.0f}~{nm_hi:.0f}nm]，使用端点电压"
            )
            print(
                f"  ⚠ 目标 {target_nm:.0f}nm 超出 LUT 范围 "
                f"[{nm_lo:.0f}~{nm_hi:.0f}nm]，前馈使用端点电压"
            )

        v_ff = float(np.clip(
            lut.inverse(temperature_C, target_nm, direction=ff_dir), v_min, v_max
        ))
        print(
            f"LUT 前馈电压: {v_ff:.4f} V  "
            f"[{ff_dir}，当前 {current_pos:.0f}nm → 目标 {target_nm:.0f}nm]"
        )
        logger.info(
            f"[{tag}] LUT 前馈: {v_ff:.4f}V  dir={ff_dir} cur={current_pos:.0f}nm"
        )
        return v_ff

    except Exception as e:
        logger.warning(f"[{tag}] LUT 前馈失败: {e}，从 {v_min}V 开始")
        print(f"LUT 前馈失败（{e}），从 {v_min:.2f}V 开始")
        return v_min


def run_pid_control(
    target_nm: float,
    cfg: Config,
    umd2: UMD2Reader,
    moku: MokuController,
    logger: logging.Logger,
    lut: Optional[PiezoLUT] = None,
    temperature_C: float = 25.0,
) -> PIDResult:
    """
    PID 静态闭环定位：驱动 Piezo 到达目标位移并保持。

    策略：
    1. LUT 反向查询前馈（快速接近目标）
    2. PI 反馈修正残差（精确定位）
    3. 连续 pid_converge_count 次误差 < pid_tolerance_nm 则收敛
    """
    v_min, v_max = cfg.v_start, cfg.v_end
    channel = cfg.moku_channel

    print(f"\n{'=' * 40}")
    print("PID 闭环定位")
    print(f"{'=' * 40}")
    print(f"目标位移 : {target_nm:.1f} nm   温度: {temperature_C}°C")
    print(f"增益     : Kp={cfg.pid_kp}  Ki={cfg.pid_ki}  Kd={cfg.pid_kd}")
    print(f"收敛条件 : |误差| < {cfg.pid_tolerance_nm} nm  连续 {cfg.pid_converge_count} 次")
    print(f"超时     : {cfg.pid_timeout_s} s")

    v_current = _lut_feedforward(
        lut, umd2, temperature_C, target_nm, v_min, v_max, "PID", logger
    )

    moku.set_voltage(channel, v_current)
    time.sleep(cfg.settle_time * 2)
    umd2.flush_queue()

    pid = PIDController(
        kp=cfg.pid_kp,
        ki=cfg.pid_ki,
        kd=cfg.pid_kd,
        integral_limit=cfg.pid_integral_limit,
    )

    converge_count = 0
    iteration = 0
    t_start = time.monotonic()
    t_prev  = t_start
    last_pos = 0.0
    interrupted = False

    print(f"\n{'迭代':>6}  {'电压(V)':>8}  {'位移(nm)':>10}  {'误差(nm)':>10}  状态")
    print("-" * 56)

    try:
        while True:
            elapsed = time.monotonic() - t_start
            if elapsed > cfg.pid_timeout_s:
                logger.warning(f"[PID] 超时 ({cfg.pid_timeout_s}s)，未收敛")
                break

            raw = umd2.read_displacement(cfg.pid_sample_avg, timeout=5.0)
            if not raw:
                logger.warning("[PID] 采样为空，跳过本次迭代")
                continue

            stats = compute_stats(raw, cfg.outlier_sigma)
            pos_nm = stats["mean"]
            last_pos = pos_nm
            error_nm = target_nm - pos_nm
            iteration += 1

            t_now = time.monotonic()
            dt = max(t_now - t_prev, 1e-6)
            t_prev = t_now

            delta_v = pid.update(error_nm, dt)
            v_current = float(np.clip(v_current + delta_v, v_min, v_max))
            moku.set_voltage(channel, v_current)

            in_tol = abs(error_nm) <= cfg.pid_tolerance_nm
            converge_count = converge_count + 1 if in_tol else 0
            status = f"✓ ×{converge_count}" if in_tol else "调节中"

            print(
                f"{iteration:6d}  {v_current:8.4f}  {pos_nm:10.1f}  "
                f"{error_nm:+10.1f}  {status}"
            )
            logger.debug(
                f"[PID] iter={iteration} V={v_current:.4f}V pos={pos_nm:.1f}nm "
                f"err={error_nm:+.1f}nm dt={dt*1000:.1f}ms"
            )

            if converge_count >= cfg.pid_converge_count:
                total_t = time.monotonic() - t_start
                print(
                    f"\n✅ 收敛！  位移={pos_nm:.1f}nm  误差={error_nm:+.1f}nm  "
                    f"电压={v_current:.4f}V  用时={total_t:.1f}s"
                )
                logger.info(
                    f"[PID] 收敛: pos={pos_nm:.1f}nm err={error_nm:+.1f}nm "
                    f"V={v_current:.4f}V t={total_t:.1f}s iters={iteration}"
                )
                return PIDResult(
                    converged=True,
                    final_voltage_V=v_current,
                    final_position_nm=pos_nm,
                    final_error_nm=error_nm,
                    iterations=iteration,
                    elapsed_s=total_t,
                )

            sleep_remain = cfg.pid_loop_interval - (time.monotonic() - t_now)
            if sleep_remain > 0:
                time.sleep(sleep_remain)

    except KeyboardInterrupt:
        interrupted = True
        print("\n[PID] 用户中断")
        logger.info("[PID] 用户中断")

    total_t = time.monotonic() - t_start
    if not interrupted:
        print(
            f"\n⚠️  超时未收敛：位移={last_pos:.1f}nm  "
            f"电压={v_current:.4f}V  用时={total_t:.1f}s"
        )
    return PIDResult(
        converged=False,
        final_voltage_V=v_current,
        final_position_nm=last_pos,
        final_error_nm=target_nm - last_pos,
        iterations=iteration,
        elapsed_s=total_t,
    )


def run_adrc_control(
    target_nm: float,
    cfg: Config,
    umd2: UMD2Reader,
    moku: MokuController,
    logger: logging.Logger,
    lut: Optional[PiezoLUT] = None,
    temperature_C: float = 25.0,
    model: Optional[ModelParams] = None,
) -> PIDResult:
    """
    ADRC 静态闭环定位（ESO + 可选 Smith Predictor）。

    参数
    ----
    model : 由 identify_model() 返回的 FOPDT 参数（可选）。
            若为 None，使用 cfg.adrc_K / cfg.adrc_tau_ms 作为植物模型默认值。
    """
    from control.adrc import ADRCController, SmithPredictor
    from tune.imc import imc_tune_from_model

    v_min, v_max = cfg.v_start, cfg.v_end
    channel = cfg.moku_channel
    dt      = cfg.pid_loop_interval

    # 植物参数（优先使用辨识结果）
    K     = model.K       if model else cfg.adrc_K
    tau_s = model.tau_s   if model else cfg.adrc_tau_ms * 1e-3
    theta_plant_s  = model.theta_plant_s  if model else 0.0
    theta_sensor_s = model.theta_sensor_s if model else 0.0
    v_dead = model.v_dead_V if model else 0.0

    use_smith = cfg.adrc_smith

    # 如果用户未指定 wc/w0，用 IMC 公式自动计算
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

    print(f"\n{'=' * 40}")
    print("ADRC 闭环定位")
    smith_tag = " [Smith]" if use_smith else ""
    print(f"{'=' * 40}")
    print(f"目标位移 : {target_nm:.1f} nm   温度: {temperature_C}°C")
    print(f"ADRC{smith_tag}  ωc={wc:.1f} rad/s  ω₀={w0:.1f} rad/s")
    print(f"植物模型 : K={K:.0f}nm/V  τ={tau_s*1000:.1f}ms  θ_p={theta_plant_s*1000:.1f}ms")
    print(f"收敛条件 : |误差| < {cfg.pid_tolerance_nm} nm  连续 {cfg.pid_converge_count} 次")
    print(f"超时     : {cfg.pid_timeout_s} s")

    ctrl = ADRCController(K=K, tau_s=tau_s, wc=wc, w0=w0, dt=dt, v_max=v_max)
    smith: Optional[SmithPredictor] = None
    if use_smith and theta_plant_s > 0:
        n_int = max(1, round(dt / 1e-3))   # 每控制周期的积分步数
        smith = SmithPredictor(
            K=K, tau_s=tau_s, theta_plant_s=theta_plant_s,
            v_dead=v_dead, dt_int=dt / n_int,
        )

    v_current = _lut_feedforward(
        lut, umd2, temperature_C, target_nm, v_min, v_max, "ADRC", logger
    )

    moku.set_voltage(channel, v_current)
    time.sleep(cfg.settle_time * 2)
    umd2.flush_queue()

    converge_count = 0
    iteration = 0
    t_start = time.monotonic()
    last_pos = 0.0
    interrupted = False

    print(f"\n{'迭代':>6}  {'电压(V)':>8}  {'位移(nm)':>10}  {'误差(nm)':>10}  状态")
    print("-" * 56)

    try:
        while True:
            elapsed = time.monotonic() - t_start
            if elapsed > cfg.pid_timeout_s:
                logger.warning(f"[ADRC] 超时 ({cfg.pid_timeout_s}s)，未收敛")
                break

            t_now = time.monotonic()
            raw = umd2.read_displacement(cfg.pid_sample_avg, timeout=5.0)
            if not raw:
                logger.warning("[ADRC] 采样为空，跳过本次迭代")
                continue

            stats_d = compute_stats(raw, cfg.outlier_sigma)
            y_meas  = stats_d["mean"]
            last_pos = y_meas
            iteration += 1

            # Smith 修正（若启用）
            if smith is not None:
                n_int = max(1, round(dt / smith.dt_int))
                correction = smith.update(v_current, n_int)
                y_for_eso = y_meas + correction
            else:
                y_for_eso = y_meas

            # ADRC 控制律
            v_current = ctrl.update(target_nm, y_for_eso)
            moku.set_voltage(channel, v_current)

            error_nm = target_nm - y_meas
            in_tol   = abs(error_nm) <= cfg.pid_tolerance_nm
            converge_count = converge_count + 1 if in_tol else 0
            status = f"✓ ×{converge_count}" if in_tol else "调节中"

            print(
                f"{iteration:6d}  {v_current:8.4f}  {y_meas:10.1f}  "
                f"{error_nm:+10.1f}  {status}"
            )
            logger.debug(
                f"[ADRC] iter={iteration} V={v_current:.4f}V pos={y_meas:.1f}nm "
                f"err={error_nm:+.1f}nm z1={ctrl.z[0]:.1f} z2={ctrl.z[1]:.3f}"
            )

            if converge_count >= cfg.pid_converge_count:
                total_t = time.monotonic() - t_start
                print(
                    f"\n✅ 收敛！  位移={y_meas:.1f}nm  误差={error_nm:+.1f}nm  "
                    f"电压={v_current:.4f}V  用时={total_t:.1f}s"
                )
                logger.info(
                    f"[ADRC] 收敛: pos={y_meas:.1f}nm err={error_nm:+.1f}nm "
                    f"V={v_current:.4f}V t={total_t:.1f}s iters={iteration}"
                )
                return PIDResult(
                    converged=True,
                    final_voltage_V=v_current,
                    final_position_nm=y_meas,
                    final_error_nm=error_nm,
                    iterations=iteration,
                    elapsed_s=total_t,
                )

            sleep_remain = cfg.pid_loop_interval - (time.monotonic() - t_now)
            if sleep_remain > 0:
                time.sleep(sleep_remain)

    except KeyboardInterrupt:
        interrupted = True
        print("\n[ADRC] 用户中断")
        logger.info("[ADRC] 用户中断")

    total_t = time.monotonic() - t_start
    if not interrupted:
        print(
            f"\n⚠️  超时未收敛：位移={last_pos:.1f}nm  "
            f"电压={v_current:.4f}V  用时={total_t:.1f}s"
        )
    return PIDResult(
        converged=False,
        final_voltage_V=v_current,
        final_position_nm=last_pos,
        final_error_nm=target_nm - last_pos,
        iterations=iteration,
        elapsed_s=total_t,
    )


def run_control(
    mode: str,
    target_nm: float,
    cfg: Config,
    umd2: UMD2Reader,
    moku: MokuController,
    logger: logging.Logger,
    lut: Optional[PiezoLUT] = None,
    temperature_C: float = 25.0,
    model: Optional[ModelParams] = None,
) -> PIDResult:
    """统一控制入口，按 mode 分发到 PID 或 ADRC。"""
    if mode.lower() == "adrc":
        return run_adrc_control(
            target_nm=target_nm, cfg=cfg, umd2=umd2, moku=moku,
            logger=logger, lut=lut, temperature_C=temperature_C, model=model,
        )
    return run_pid_control(
        target_nm=target_nm, cfg=cfg, umd2=umd2, moku=moku,
        logger=logger, lut=lut, temperature_C=temperature_C,
    )
