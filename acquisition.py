"""LUT 采集流程：单次扫描 + 主采集编排。"""
from __future__ import annotations

import logging
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from config import Config
from data import CSVWriter, PiezoLUT
from hardware import DryRunMokuController, DryRunUMD2Reader, MokuController, UMD2Reader
from models import MeasurementPoint, ModelParams
from utils import DataStore, ProgressDisplay, compute_stats, setup_logging


def run_sweep(
    cfg: Config,
    temp_C: float,
    direction: str,
    umd2: UMD2Reader,
    moku: MokuController,
    store: DataStore,
    logger: logging.Logger,
) -> list[MeasurementPoint]:
    """执行单次电压扫描（升压或降压）。"""
    voltages = cfg.voltage_steps
    if direction == "down":
        voltages = list(reversed(voltages))

    total = len(voltages)
    display = ProgressDisplay(total)
    points: list[MeasurementPoint] = []
    header = "── 升压扫描 ──" if direction == "up" else "── 降压扫描 ──"
    print(f"\n{header}")

    for step, voltage in enumerate(voltages, start=1):
        try:
            moku.set_voltage(cfg.moku_channel, voltage)
        except Exception as e:
            logger.error(f"Moku 设置电压 {voltage:.2f}V 失败: {e}")
            if not moku.reconnect():
                logger.error("Moku 重连失败，中止扫描")
                raise
            moku.set_voltage(cfg.moku_channel, voltage)

        time.sleep(cfg.settle_time)
        umd2.flush_queue()

        timeout = max(cfg.n_samples * 0.005 + 5.0, 10.0)
        try:
            raw = umd2.read_displacement(cfg.n_samples, timeout=timeout)
        except Exception as e:
            logger.error(f"µMD2 读取失败: {e}")
            if not umd2.reconnect():
                raise
            raw = umd2.read_displacement(cfg.n_samples, timeout=timeout)

        if len(raw) < cfg.n_samples * 0.5:
            logger.warning(
                f"采样不足警告: 期望 {cfg.n_samples} 帧，实际 {len(raw)} 帧  "
                f"V={voltage:.2f}V T={temp_C}°C"
            )

        stats = compute_stats(raw, cfg.outlier_sigma)
        ts = datetime.now().isoformat(timespec="seconds")
        point = MeasurementPoint(
            temperature_C=temp_C,
            voltage_V=voltage,
            direction=direction,
            mean_nm=stats["mean"],
            std_nm=stats["std"],
            sem_nm=stats["sem"],
            ci_95_nm=stats["ci_95"],
            n_samples=stats["n_samples"],
            outliers_removed=stats["outliers_removed"],
            timestamp=ts,
        )
        store.add(point)
        points.append(point)
        display.update(point, step, total)

    return points


def run_acquisition(cfg: Config) -> Optional[str]:
    """
    主编排函数：连接设备 → 温度循环 → 升/降压扫描 → 保存 LUT。

    返回保存的完整 LUT CSV 路径（采集成功时），或 None（中断/失败时）。
    KeyboardInterrupt 时归零电压并保存已有数据后退出。
    """
    from tune.system_id import identify_model

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    logger = setup_logging(cfg.output_dir, ts)
    store = DataStore()
    csv_writer = CSVWriter(cfg, ts)

    print("=" * 40)
    print("µMD2 LUT 自动采集系统")
    print("=" * 40)

    if cfg.dry_run:
        dry_umd2 = DryRunUMD2Reader(cfg, logger)
        umd2: UMD2Reader = dry_umd2
        moku: MokuController = DryRunMokuController(cfg, logger, dry_umd2)
    else:
        umd2 = UMD2Reader(cfg, logger)
        moku = MokuController(cfg, logger)

    try:
        port = umd2.connect()
        info = umd2.read_firmware_info(timeout=5.0)
        fw = info.firmware_version or "未知"
        sr = info.sample_rate_hz   or "未知"
        print(f"[设备] µMD2 已连接: {port}  固件版本: {fw}  采样率: {sr}Hz")
        moku.connect()
        print(f"[设备] Moku:Go 已连接: {cfg.moku_ip}")
        print(
            f"[配置] 分辨率: {cfg.nm_per_count}nm/count  "
            f"电压范围: {cfg.v_start}~{cfg.v_end}V  步长: {cfg.v_step}V"
        )
        print(
            f"[配置] 温度点: {cfg.temperatures}°C  每点采样: {cfg.n_samples}次"
        )

        multi_temp = len(cfg.temperatures) > 1
        total_sweeps = len(cfg.temperatures) * 2
        sweep_idx = 0
        model_params_list: list[ModelParams] = []

        for temp_idx, temp_C in enumerate(cfg.temperatures, start=1):
            print(f"\n{'-' * 40}")
            print(f"温度点 {temp_idx}/{len(cfg.temperatures)}: {temp_C}°C")
            print(f"{'-' * 40}")

            if multi_temp:
                input(f"请将温度调整至 {temp_C}°C，按 Enter 继续...")
                ProgressDisplay.countdown(cfg.temp_stabilize_time, "等待稳定")

            actual_temp = umd2.read_temperature(timeout=2.0)
            if actual_temp is not None:
                logger.info(f"实测温度: {actual_temp:.1f}°C (设定: {temp_C}°C)")

            sweep_idx += 1
            pct = int(sweep_idx / total_sweeps * 100)
            logger.info(f"总进度: {pct}%  开始 {temp_C}°C 升压扫描")
            up_points = run_sweep(cfg, temp_C, "up", umd2, moku, store, logger)
            up_max = max(p.mean_nm for p in up_points) if up_points else 0.0
            print(f"\n[进度] {temp_C}°C 升压完成，最大位移={up_max:.1f}nm")

            sweep_idx += 1
            pct = int(sweep_idx / total_sweeps * 100)
            logger.info(f"总进度: {pct}%  开始 {temp_C}°C 降压扫描")
            run_sweep(cfg, temp_C, "down", umd2, moku, store, logger)

            if cfg.step_ident_enabled:
                mp = identify_model(cfg, temp_C, umd2, moku, logger, store)
                if mp is not None:
                    model_params_list.append(mp)

            partial_path = csv_writer.save_partial(store, temp_C)
            logger.info(f"中间结果已保存: {partial_path}")
            print(f"[保存] 中间结果已保存: {partial_path}")

        moku.zero_output(cfg.moku_channel)
        full_path    = csv_writer.save_full(store)
        summary_path = csv_writer.save_summary(store)

        print("\n" + "=" * 40)
        print("全部完成！")
        print(f"[保存] 完整LUT: {full_path}")
        print(f"[保存] 摘要:    {summary_path}")
        if model_params_list:
            model_path = csv_writer.save_model_params(model_params_list)
            print(f"[保存] 模型参数: {model_path}")
        print("=" * 40)

        _demo_piezo_lut(str(full_path), cfg, logger)
        return str(full_path)

    except KeyboardInterrupt:
        print("\n[中断] 用户中断，归零电压并保存已有数据...")
        moku.zero_output(cfg.moku_channel)
        if len(store) > 0:
            path = csv_writer.save_full(store)
            print(f"[保存] 已保存: {path}")
        sys.exit(0)
    finally:
        umd2.close()
        moku.close()
    return None


def _demo_piezo_lut(
    csv_path: str, cfg: Config, logger: logging.Logger
) -> None:
    try:
        lut = PiezoLUT.from_csv(csv_path)
        temp   = cfg.temperatures[0]
        mid_v  = (cfg.v_start + cfg.v_end) / 2.0
        disp   = lut.forward(temp, mid_v, direction="up")
        voltage = lut.inverse(temp, disp, direction="up")
        print(f"\n[LUT示例] forward({temp}°C, {mid_v}V, 'up') = {disp:.1f} nm")
        print(f"[LUT示例] inverse({temp}°C, {disp:.1f}nm, 'up') = {voltage:.4f} V")
    except Exception as e:
        logger.warning(f"PiezoLUT 演示失败: {e}")
