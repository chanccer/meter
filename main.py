#!/usr/bin/env python3
"""
Piezo 电压-位移查找表（LUT）自动采集系统 / PID·ADRC 闭环定位系统

µMD2 (USB 串口位移测量) + Moku:Go (DC 电压输出)

使用示例
--------
  python main.py                                          # 正常 LUT 采集
  python main.py --dry-run                                # 模拟运行（无需硬件）
  python main.py --load lut_xxx.csv                       # 查询模式
  python main.py --pid 1000                               # PID 定位到 1000 nm
  python main.py --pid 1000 --load lut_xxx.csv            # PID + LUT 前馈
  python main.py --pid 1000 --autotune                    # 先自动整定再 PID 定位
  python main.py --pid 1000 --controller adrc             # ADRC 定位（需先辨识模型）
  python main.py --pid 1000 --controller adrc --no-smith  # ADRC 不含 Smith Predictor
  python main.py --acquire --pid 1000                     # 采集 LUT 后立即 PID 定位（前馈自动启用）
  python main.py --acquire --pid 1000 --controller adrc   # 采集 LUT 后立即 ADRC 定位
  python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 --traj-freq 0.5 --traj-cycles 3  # 正弦轨迹
  python main.py --trajectory triangle --traj-amp 800 --traj-offset 1000 --traj-freq 0.2 --traj-duration 20
"""
from __future__ import annotations

import argparse
import io
import sys
import time
from datetime import datetime
from typing import Optional

# Windows: 强制 stdout/stderr 使用 UTF-8
if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

from acquisition import run_acquisition
from config import Config, V_START, V_END, V_STEP, TEMPERATURES, TRAJ_FREQ_HZ, TRAJ_AMP_NM, TRAJ_OFFSET_NM, TRAJ_DURATION_S
from control.loop import run_control
from control.trajectory import run_trajectory_control
from data import PiezoLUT
from hardware import DryRunMokuController, DryRunUMD2Reader, MokuController, UMD2Reader
from tune.system_id import AutoTuner, identify_model
from utils import setup_logging


def _query_mode(csv_path: str) -> None:
    """从 CSV 加载 LUT 并演示正向/反向查询。"""
    print(f"加载 LUT: {csv_path}")
    try:
        lut = PiezoLUT.from_csv(csv_path)
    except Exception as e:
        print(f"加载失败: {e}")
        sys.exit(1)

    temps = lut.temperatures()
    print(f"LUT 已加载。温度点: {temps}°C")

    for direction in ("up", "down"):
        v_min, v_max = lut.voltage_range(direction)
        if v_min == v_max == 0.0:
            continue
        mid_v = (v_min + v_max) / 2.0
        for temp in temps[:2]:
            try:
                nm = lut.forward(temp, mid_v, direction=direction)
                v  = lut.inverse(temp, nm,    direction=direction)
                print(
                    f"  [{direction}] forward({temp}°C, {mid_v:.2f}V)"
                    f" = {nm:.1f} nm  |  "
                    f"inverse({temp}°C, {nm:.1f}nm) = {v:.4f} V"
                )
            except Exception as e:
                print(f"  [{direction}] 查询失败: {e}")


def _pid_mode(
    target_nm: float,
    temperature_C: float,
    lut_path: Optional[str],
    cfg: Config,
    controller: str = "pid",
    do_autotune: bool = False,
) -> None:
    """
    闭环定位模式：连接设备，可选自动整定，驱动 Piezo 到达目标位移后保持。

    controller : 'pid' 或 'adrc'
    """
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    logger = setup_logging(cfg.output_dir, ts)

    lut: Optional[PiezoLUT] = None
    if lut_path:
        try:
            lut = PiezoLUT.from_csv(lut_path)
            print(f"[LUT] 已加载: {lut_path}")
        except Exception as e:
            print(f"[LUT] 加载失败: {e}（将不使用前馈，从 {cfg.v_start}V 开始）")

    if cfg.dry_run:
        dry_umd2 = DryRunUMD2Reader(cfg, logger)
        umd2: UMD2Reader = dry_umd2
        moku: MokuController = DryRunMokuController(cfg, logger, dry_umd2)
    else:
        umd2 = UMD2Reader(cfg, logger)
        moku = MokuController(cfg, logger)

    model = None
    try:
        port = umd2.connect()
        info = umd2.read_firmware_info(timeout=5.0)
        print(f"[设备] µMD2: {port}  固件: {info.firmware_version or '未知'}")
        moku.connect()
        print(f"[设备] Moku:Go: {cfg.moku_ip}")

        # 自动整定（可选）
        if do_autotune:
            tuner = AutoTuner(cfg, umd2, moku, logger)
            tune_result = tuner.run()
            if tune_result.success:
                cfg.pid_kp = tune_result.kp
                cfg.pid_ki = tune_result.ki
                logger.info(
                    f"[AutoTune] 应用增益 Kp={tune_result.kp:.6f} Ki={tune_result.ki:.6f}"
                )
                print(f"[自动整定] 已应用 Kp={tune_result.kp:.6f}  Ki={tune_result.ki:.6f}")
            else:
                print(f"[自动整定] 失败：{tune_result.message}，使用配置默认增益")

        # ADRC 模式需要模型辨识
        if controller.lower() == "adrc":
            print("\n[ADRC] 执行模型辨识（为 ESO 提供植物参数）…")
            model = identify_model(cfg, temperature_C, umd2, moku, logger)
            if model is None:
                print("[ADRC] 模型辨识失败，回退到 PID 模式")
                controller = "pid"

        # 统一控制入口
        result = run_control(
            mode=controller,
            target_nm=target_nm,
            cfg=cfg,
            umd2=umd2,
            moku=moku,
            logger=logger,
            lut=lut,
            temperature_C=temperature_C,
            model=model,
        )

        if result.converged:
            print(f"\n[{controller.upper()}] 已锁定在 {result.final_position_nm:.1f} nm，"
                  f"按 Ctrl+C 归零退出...")
            try:
                while True:
                    time.sleep(0.5)
            except KeyboardInterrupt:
                pass

    except KeyboardInterrupt:
        print("\n[中断]")
    finally:
        moku.zero_output(cfg.moku_channel)
        umd2.close()
        moku.close()
        print(f"[{controller.upper()}] 电压已归零，退出")


def _trajectory_mode(
    waveform: str,
    freq_hz: float,
    amp_nm: float,
    offset_nm: float,
    duration_s: float,
    temperature_C: float,
    lut_path: Optional[str],
    cfg: Config,
    controller: str = "adrc",
    do_autotune: bool = False,
) -> None:
    """轨迹跟踪模式：连接设备，辨识模型，执行 ADRC 轨迹跟踪，保存结果。"""
    import csv
    from pathlib import Path

    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    logger = setup_logging(cfg.output_dir, ts)

    lut: Optional[PiezoLUT] = None
    if lut_path:
        try:
            lut = PiezoLUT.from_csv(lut_path)
            print(f"[LUT] 已加载: {lut_path}")
        except Exception as e:
            print(f"[LUT] 加载失败: {e}（将不使用前馈）")

    if cfg.dry_run:
        dry_umd2 = DryRunUMD2Reader(cfg, logger)
        umd2: UMD2Reader = dry_umd2
        moku: MokuController = DryRunMokuController(cfg, logger, dry_umd2)
    else:
        umd2 = UMD2Reader(cfg, logger)
        moku = MokuController(cfg, logger)

    model = None
    try:
        port = umd2.connect()
        info = umd2.read_firmware_info(timeout=5.0)
        print(f"[设备] µMD2: {port}  固件: {info.firmware_version or '未知'}")
        moku.connect()
        print(f"[设备] Moku:Go: {cfg.moku_ip}")

        if do_autotune:
            tuner = AutoTuner(cfg, umd2, moku, logger)
            tune_result = tuner.run()
            if tune_result.success:
                cfg.pid_kp = tune_result.kp
                cfg.pid_ki = tune_result.ki
                print(f"[自动整定] 已应用 Kp={tune_result.kp:.6f}  Ki={tune_result.ki:.6f}")
            else:
                print(f"[自动整定] 失败：{tune_result.message}")

        if controller.lower() == "adrc":
            print("\n[ADRC] 执行模型辨识（为 ESO 提供植物参数）…")
            model = identify_model(cfg, temperature_C, umd2, moku, logger)
            if model is None:
                print("[ADRC] 模型辨识失败，将使用 cfg 默认参数继续")

        result = run_trajectory_control(
            waveform=waveform,
            freq_hz=freq_hz,
            amp_nm=amp_nm,
            offset_nm=offset_nm,
            duration_s=duration_s,
            cfg=cfg,
            umd2=umd2,
            moku=moku,
            logger=logger,
            lut=lut,
            temperature_C=temperature_C,
            model=model,
        )

        # 保存结果 CSV
        Path(cfg.output_dir).mkdir(parents=True, exist_ok=True)
        csv_path = Path(cfg.output_dir) / f"trajectory_{ts}.csv"
        with open(csv_path, "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["time_s", "setpoint_nm", "measured_nm", "voltage_V"])
            for row in zip(result.times_s, result.setpoints_nm,
                           result.measured_nm, result.voltages_V):
                writer.writerow([f"{v:.6f}" for v in row])

        print(f"\n[保存] 轨迹数据: {csv_path}")
        print(f"[摘要] RMSE={result.rmse_nm:.1f}nm  最大误差={result.max_error_nm:.1f}nm"
              f"{'  ⚠带宽超限' if result.bandwidth_warning else ''}")

    except KeyboardInterrupt:
        print("\n[中断]")
    finally:
        moku.zero_output(cfg.moku_channel)
        umd2.close()
        moku.close()
        print("[轨迹] 电压已归零，退出")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Piezo 电压-位移 LUT 自动采集系统 / PID·ADRC 闭环定位系统",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument("--dry-run", action="store_true",
                        help="不连接硬件，用随机数模拟")
    parser.add_argument("--load", metavar="CSV",
                        help="加载已有 LUT CSV；单独使用时进入查询模式，与 --pid 合用时作为前馈")
    parser.add_argument("--pid", metavar="NM", type=float,
                        help="闭环定位：驱动 Piezo 到达目标位移（nm）")
    parser.add_argument("--pid-temp", metavar="TEMP", type=float, default=25.0,
                        help="PID/ADRC 模式的温度 °C（默认 25）")
    parser.add_argument("--autotune", action="store_true",
                        help="在定位前执行阶跃响应自动整定（需配合 --pid 使用）")
    parser.add_argument("--controller", choices=["pid", "adrc"], default="pid",
                        help="控制器类型：pid（默认）或 adrc（含 ESO + Smith Predictor）")
    parser.add_argument("--smith", dest="smith", action="store_true", default=True,
                        help="ADRC 启用 Smith Predictor（默认开启）")
    parser.add_argument("--no-smith", dest="smith", action="store_false",
                        help="ADRC 禁用 Smith Predictor")
    parser.add_argument("--acquire", action="store_true",
                        help="先采集 LUT，再立即执行闭环定位（需配合 --pid 使用）")
    parser.add_argument("--temperatures", metavar="C", type=float, nargs="+", default=None,
                        help=f"采集温度点列表 °C（默认 {TEMPERATURES}）；多个值空格分隔")
    parser.add_argument("--v-start", metavar="V", type=float, default=None,
                        help=f"扫描/控制起始电压 V（默认 {V_START}V）")
    parser.add_argument("--v-end", metavar="V", type=float, default=None,
                        help=f"扫描/控制终止电压 V（默认 {V_END}V）")
    parser.add_argument("--v-step", metavar="V", type=float, default=None,
                        help=f"LUT 采集步长 V（默认 {V_STEP}V）")
    # 轨迹跟踪参数
    parser.add_argument("--trajectory", choices=["sine", "triangle", "sawtooth", "square"],
                        metavar="WAVE", default=None,
                        help="轨迹跟踪波形：sine / triangle / sawtooth / square")
    parser.add_argument("--traj-freq", metavar="HZ", type=float, default=None,
                        help=f"轨迹频率 Hz（默认 {TRAJ_FREQ_HZ}Hz）")
    parser.add_argument("--traj-amp", metavar="NM", type=float, default=None,
                        help=f"轨迹半幅值 nm（默认 {TRAJ_AMP_NM:.0f}nm）")
    parser.add_argument("--traj-offset", metavar="NM", type=float, default=None,
                        help=f"轨迹中心位移 nm（默认 {TRAJ_OFFSET_NM:.0f}nm）")
    parser.add_argument("--traj-duration", metavar="S", type=float, default=None,
                        help=f"轨迹时长 s（默认 {TRAJ_DURATION_S:.0f}s；与 --traj-cycles 互斥）")
    parser.add_argument("--traj-cycles", metavar="N", type=float, default=None,
                        help="轨迹周期数（与 --traj-duration 互斥，自动换算为时长）")
    args = parser.parse_args()

    cfg = Config(
        dry_run=args.dry_run,
        adrc_smith=args.smith,
        **({} if args.temperatures is None else {"temperatures": args.temperatures}),
        **({} if args.v_start      is None else {"v_start":      args.v_start}),
        **({} if args.v_end        is None else {"v_end":        args.v_end}),
        **({} if args.v_step       is None else {"v_step":       args.v_step}),
    )
    if len(cfg.temperatures) == 0:
        parser.error("--temperatures 至少需要一个温度值")
    if len(cfg.temperatures) != len(set(cfg.temperatures)):
        parser.error("--temperatures 中存在重复的温度值")
    if cfg.v_start >= cfg.v_end:
        parser.error(f"--v-start ({cfg.v_start}V) 必须小于 --v-end ({cfg.v_end}V)")
    if cfg.v_step <= 0 or cfg.v_step > (cfg.v_end - cfg.v_start):
        parser.error(f"--v-step ({cfg.v_step}V) 必须在 (0, {cfg.v_end - cfg.v_start}] 范围内")

    if args.trajectory:
        if args.traj_cycles is not None and args.traj_duration is not None:
            parser.error("--traj-cycles 和 --traj-duration 不能同时指定")
        freq_hz  = args.traj_freq     if args.traj_freq     is not None else cfg.traj_freq_hz
        amp_nm   = args.traj_amp      if args.traj_amp      is not None else cfg.traj_amp_nm
        offset   = args.traj_offset   if args.traj_offset   is not None else cfg.traj_offset_nm
        if args.traj_cycles is not None:
            if freq_hz <= 0:
                parser.error("--traj-freq 必须 > 0 才能使用 --traj-cycles")
            duration_s = args.traj_cycles / freq_hz
        else:
            duration_s = args.traj_duration if args.traj_duration is not None else cfg.traj_duration_s
        if freq_hz <= 0:
            parser.error("--traj-freq 必须大于 0")
        if amp_nm <= 0:
            parser.error("--traj-amp 必须大于 0")
        if duration_s <= 0:
            parser.error("--traj-duration / --traj-cycles 换算后时长必须大于 0")
        _trajectory_mode(
            waveform=args.trajectory,
            freq_hz=freq_hz,
            amp_nm=amp_nm,
            offset_nm=offset,
            duration_s=duration_s,
            temperature_C=args.pid_temp,
            lut_path=args.load,
            cfg=cfg,
            controller=args.controller,
            do_autotune=args.autotune,
        )
        return

    if args.acquire:
        if args.pid is None:
            parser.error("--acquire 需要同时指定 --pid <目标位移 nm>")
        print("[采集] 开始 LUT 采集，完成后自动切换到闭环定位...")
        lut_path = run_acquisition(cfg)
        if lut_path is None:
            print("[采集] 采集失败或被中断，无法继续定位")
            sys.exit(1)
        print(f"\n[采集完成] LUT 已保存: {lut_path}")
        print("[定位] 切换到闭环定位模式...\n")
        _pid_mode(
            target_nm=args.pid,
            temperature_C=args.pid_temp,
            lut_path=lut_path,
            cfg=cfg,
            controller=args.controller,
            do_autotune=args.autotune,
        )
        return

    if args.pid is not None:
        _pid_mode(
            target_nm=args.pid,
            temperature_C=args.pid_temp,
            lut_path=args.load,
            cfg=cfg,
            controller=args.controller,
            do_autotune=args.autotune,
        )
        return

    if args.load:
        _query_mode(args.load)
        return

    run_acquisition(cfg)


if __name__ == "__main__":
    main()
