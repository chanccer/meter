#!/usr/bin/env python3
"""
Piezo 电压-位移查找表（LUT）自动采集系统
µMD2 (USB 串口位移测量) + Moku:Go (DC 电压输出)
"""

from __future__ import annotations

import argparse
import io
import logging
import math
import queue
import sys
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Optional

# Windows: 强制 stdout/stderr 使用 UTF-8，确保中文和 Unicode 符号正常显示。
# 在 Windows Terminal / PowerShell 7+ 中通常不需要；在旧版 cmd.exe 中必须设置。
if sys.platform == "win32":
    sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding="utf-8", errors="replace")
    sys.stderr = io.TextIOWrapper(sys.stderr.buffer, encoding="utf-8", errors="replace")

import numpy as np
import pandas as pd
from scipy.interpolate import RegularGridInterpolator
from scipy.optimize import brentq

import serial
import serial.tools.list_ports

# ============================================================
# CONFIGURATION — 在此处修改所有参数
# ============================================================

UMD2_PORT           = "AUTO"     # 'AUTO' 自动检测，或指定 'COM7' / '/dev/ttyUSB0'
UMD2_BAUD           = 9600
UMD2_RESOLUTION     = "PMI"      # 'PMI'=40nm/count, 'LI'=79nm/count

MOKU_IP             = "192.168.73.1"
MOKU_CHANNEL        = 1

V_START             = 0.0        # 起始电压 V
V_END               = 5.0        # 终止电压 V
V_STEP              = 0.1        # 步长 V
SETTLE_TIME         = 0.5        # 每步稳定等待 s

TEMPERATURES        = [25.0]     # 温度列表 °C；单元素时跳过等待提示
TEMP_STABILIZE_TIME = 300        # 换温度后等待稳定 s

N_SAMPLES           = 100        # 每个电压点采集帧数
OUTLIER_SIGMA       = 3.0        # 异常值剔除阈值 (σ)

OUTPUT_DIR          = "./lut_output"  # 输出目录

# PID 闭环控制参数
PID_KP              = 0.001        # 比例增益 V/nm
PID_KI              = 0.0002       # 积分增益 V/(nm·s)
PID_KD              = 0.0          # 微分增益 V·s/nm（默认关闭，µMD2 噪声较大时不建议开启）
PID_TOLERANCE_NM    = 5.0          # 收敛容差 nm
PID_CONVERGE_COUNT  = 5            # 连续满足容差的迭代次数，才判定收敛
PID_TIMEOUT_S       = 30.0         # 最长等待时间 s
PID_SAMPLE_AVG      = 20           # 每次 PID 迭代平均采样帧数
PID_LOOP_INTERVAL   = 0.05         # 目标循环间隔 s
PID_INTEGRAL_LIMIT  = 0.5          # 积分项最大贡献 V（抗积分饱和）

# ============================================================
# 内部常量
# ============================================================

_RESOLUTION_NM: dict[str, int] = {"PMI": 40, "LI": 79}

# ============================================================
# 数据结构
# ============================================================


@dataclass
class Config:
    """所有采集参数的集中配置，通过 dataclass 传递，避免全局变量。"""

    umd2_port: str = UMD2_PORT
    umd2_baud: int = UMD2_BAUD
    umd2_resolution: str = UMD2_RESOLUTION
    moku_ip: str = MOKU_IP
    moku_channel: int = MOKU_CHANNEL
    v_start: float = V_START
    v_end: float = V_END
    v_step: float = V_STEP
    settle_time: float = SETTLE_TIME
    temperatures: list[float] = field(default_factory=lambda: list(TEMPERATURES))
    temp_stabilize_time: int = TEMP_STABILIZE_TIME
    n_samples: int = N_SAMPLES
    outlier_sigma: float = OUTLIER_SIGMA
    output_dir: str = OUTPUT_DIR
    dry_run: bool = False
    pid_kp: float = PID_KP
    pid_ki: float = PID_KI
    pid_kd: float = PID_KD
    pid_tolerance_nm: float = PID_TOLERANCE_NM
    pid_converge_count: int = PID_CONVERGE_COUNT
    pid_timeout_s: float = PID_TIMEOUT_S
    pid_sample_avg: int = PID_SAMPLE_AVG
    pid_loop_interval: float = PID_LOOP_INTERVAL
    pid_integral_limit: float = PID_INTEGRAL_LIMIT

    @property
    def nm_per_count(self) -> int:
        """分辨率：纳米/计数。"""
        return _RESOLUTION_NM.get(self.umd2_resolution, 40)

    @property
    def voltage_steps(self) -> list[float]:
        """生成升压方向的电压列表，避免浮点累积误差。"""
        n = round((self.v_end - self.v_start) / self.v_step) + 1
        return [round(self.v_start + i * self.v_step, 9) for i in range(n)]


@dataclass
class MeasurementPoint:
    """单个电压点的统计测量结果。"""

    temperature_C: float
    voltage_V: float
    direction: str          # 'up' 或 'down'
    mean_nm: float
    std_nm: float
    sem_nm: float
    ci_95_nm: float
    n_samples: int
    outliers_removed: int
    timestamp: str


@dataclass
class DeviceInfo:
    """从 µMD2 低速帧读取的设备信息。"""

    firmware_version: Optional[str] = None
    sample_rate_hz: Optional[int] = None
    temperature_C: Optional[float] = None
    port: Optional[str] = None


# ============================================================
# 日志配置
# ============================================================


def setup_logging(output_dir: str, timestamp: str) -> logging.Logger:
    """配置双输出日志：控制台 INFO + 文件 DEBUG。"""
    Path(output_dir).mkdir(parents=True, exist_ok=True)
    log_path = Path(output_dir) / f"lut_{timestamp}.log"

    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(message)s", datefmt="%H:%M:%S"
    )
    logger = logging.getLogger("piezo_lut")
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()

    ch = logging.StreamHandler(sys.stdout)
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)

    fh = logging.FileHandler(log_path, encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)

    logger.addHandler(ch)
    logger.addHandler(fh)
    return logger


# ============================================================
# 统计分析
# ============================================================


def filter_outliers(
    data: np.ndarray, sigma: float
) -> tuple[np.ndarray, int]:
    """3-sigma 剔除离群值，返回 (过滤后数组, 剔除数量)。"""
    if len(data) < 3:
        return data, 0
    mean = np.mean(data)
    std = np.std(data, ddof=1)
    if std == 0.0:
        return data, 0
    mask = np.abs(data - mean) <= sigma * std
    removed = int(np.sum(~mask))
    return data[mask], removed


def compute_stats(raw: list[float], sigma: float) -> dict:
    """计算统计量：均值、标准差、标准误差、95% 置信区间。"""
    arr = np.array(raw, dtype=float)
    filtered, n_removed = filter_outliers(arr, sigma)
    n = len(filtered)
    if n == 0:
        return {
            "mean": 0.0, "std": 0.0, "sem": 0.0, "ci_95": 0.0,
            "n_samples": 0, "outliers_removed": n_removed,
        }
    mean = float(np.mean(filtered))
    std = float(np.std(filtered, ddof=1)) if n > 1 else 0.0
    sem = std / math.sqrt(n) if n > 1 else 0.0
    ci_95 = 1.96 * sem   # 大样本近似
    return {
        "mean": mean, "std": std, "sem": sem, "ci_95": ci_95,
        "n_samples": n, "outliers_removed": n_removed,
    }


# ============================================================
# µMD2 串口读取器
# ============================================================


class UMD2Reader:
    """线程安全的 µMD2 串口读取器。"""

    _TEENSY_KEYWORDS = ("teensy", "usb serial", "usbserial")
    _LOW_SPEED_FIRMWARE    = 10
    _LOW_SPEED_SAMPLE_RATE = 8
    _LOW_SPEED_TEMPERATURE = 3

    def __init__(self, cfg: Config, logger: logging.Logger) -> None:
        self._cfg = cfg
        self._log = logger
        self._port: Optional[serial.Serial] = None
        self._queue: queue.Queue[str] = queue.Queue(maxsize=20000)
        self._thread: Optional[threading.Thread] = None
        self._running = False
        self.device_info = DeviceInfo()

    @staticmethod
    def find_port() -> Optional[str]:
        """扫描串口，优先找描述含 Teensy/USB Serial 的端口。"""
        ports = list(serial.tools.list_ports.comports())
        for p in ports:
            desc = (p.description or "").lower()
            if any(k in desc for k in UMD2Reader._TEENSY_KEYWORDS):
                return p.device
        return ports[0].device if ports else None

    def connect(self) -> str:
        """打开串口并启动后台读取线程，返回实际端口名。"""
        port_name = self._cfg.umd2_port
        if port_name == "AUTO":
            port_name = self.find_port()
            if port_name is None:
                available = [p.device for p in serial.tools.list_ports.comports()]
                raise RuntimeError(
                    f"µMD2 未找到串口。可用端口: {available or '无'}\n"
                    "请检查 USB 连接或在 UMD2_PORT 中手动指定端口。"
                )
        self._port = serial.Serial(port_name, self._cfg.umd2_baud, timeout=1.0)
        self.device_info.port = port_name
        self._running = True
        self._thread = threading.Thread(
            target=self._read_loop, daemon=True, name="umd2-reader"
        )
        self._thread.start()
        self._log.info(f"µMD2 串口已打开: {port_name}")
        return port_name

    def _read_loop(self) -> None:
        """后台线程：持续读取串口行并推入队列。"""
        while self._running:
            try:
                raw = self._port.readline()
                if not raw:
                    continue
                line = raw.decode("ascii", errors="ignore").strip()
                if line and not self._queue.full():
                    self._queue.put(line)
            except serial.SerialException as e:
                self._log.warning(f"µMD2 串口读取中断: {e}")
                self._running = False
                break
            except Exception:
                pass

    def reconnect(self, retries: int = 3) -> bool:
        """尝试重新打开串口，最多重试 retries 次。"""
        self._running = False
        if self._port and self._port.is_open:
            try:
                self._port.close()
            except Exception:
                pass
        for attempt in range(1, retries + 1):
            self._log.info(f"µMD2 重连尝试 {attempt}/{retries}...")
            time.sleep(2.0)
            try:
                self._port.open()
                self._running = True
                self._thread = threading.Thread(
                    target=self._read_loop, daemon=True, name="umd2-reader"
                )
                self._thread.start()
                self._log.info("µMD2 重连成功")
                return True
            except serial.SerialException as e:
                self._log.warning(f"重连失败: {e}")
        return False

    def _parse_line(self, line: str) -> Optional[tuple[int, int, str]]:
        """解析空格分隔的 µMD2 数据行，返回 (位移计数, 低速代码, 低速数据) 或 None。"""
        parts = line.split()
        if len(parts) < 7:
            return None
        try:
            disp_count = int(parts[2])
            low_code   = int(parts[6])
            low_data   = parts[7] if len(parts) > 7 else ""
            return disp_count, low_code, low_data
        except (ValueError, IndexError):
            return None

    def read_firmware_info(self, timeout: float = 5.0) -> DeviceInfo:
        """从低速帧收集固件版本、采样率、温度。"""
        deadline = time.monotonic() + timeout
        collected: dict[int, str] = {}
        target = {
            self._LOW_SPEED_FIRMWARE,
            self._LOW_SPEED_SAMPLE_RATE,
            self._LOW_SPEED_TEMPERATURE,
        }

        while time.monotonic() < deadline and not target.issubset(collected.keys()):
            try:
                line = self._queue.get(timeout=0.2)
            except queue.Empty:
                continue
            parsed = self._parse_line(line)
            if parsed:
                _, code, data = parsed
                if code in target:
                    collected[code] = data

        if self._LOW_SPEED_FIRMWARE in collected:
            self.device_info.firmware_version = collected[self._LOW_SPEED_FIRMWARE]
        if self._LOW_SPEED_SAMPLE_RATE in collected:
            try:
                self.device_info.sample_rate_hz = int(
                    collected[self._LOW_SPEED_SAMPLE_RATE]
                )
            except ValueError:
                pass
        if self._LOW_SPEED_TEMPERATURE in collected:
            try:
                self.device_info.temperature_C = (
                    float(collected[self._LOW_SPEED_TEMPERATURE]) / 100.0
                )
            except ValueError:
                pass
        return self.device_info

    def flush_queue(self) -> None:
        """清空队列中的积压数据（换电压挡后使用，避免读到旧帧）。"""
        while not self._queue.empty():
            try:
                self._queue.get_nowait()
            except queue.Empty:
                break

    def read_displacement(self, n: int, timeout: float = 15.0) -> list[float]:
        """采集 n 帧位移数据，转换为纳米后返回。"""
        nm_per_count = self._cfg.nm_per_count
        samples: list[float] = []
        deadline = time.monotonic() + timeout

        while len(samples) < n and time.monotonic() < deadline:
            try:
                line = self._queue.get(timeout=0.1)
            except queue.Empty:
                continue
            parsed = self._parse_line(line)
            if parsed:
                disp_count, _, _ = parsed
                samples.append(float(disp_count) * nm_per_count)

        return samples

    def read_temperature(self, timeout: float = 2.0) -> Optional[float]:
        """从低速帧（code 3）读取当前温度（°C）。"""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                line = self._queue.get(timeout=0.1)
            except queue.Empty:
                continue
            parsed = self._parse_line(line)
            if parsed:
                _, code, data = parsed
                if code == self._LOW_SPEED_TEMPERATURE:
                    try:
                        return float(data) / 100.0
                    except ValueError:
                        pass
        return None

    def close(self) -> None:
        """停止后台线程并关闭串口。"""
        self._running = False
        if self._thread:
            self._thread.join(timeout=2.0)
        if self._port and self._port.is_open:
            try:
                self._port.close()
            except Exception:
                pass


class DryRunUMD2Reader(UMD2Reader):
    """--dry-run 模式下的模拟 µMD2，用随机数代替真实采样。"""

    def __init__(self, cfg: Config, logger: logging.Logger) -> None:
        self._cfg = cfg
        self._log = logger
        self._current_voltage: float = 0.0
        self.device_info = DeviceInfo(
            firmware_version="1.26",
            sample_rate_hz=1000,
            temperature_C=25.0,
            port="DRY_RUN",
        )

    def connect(self) -> str:
        self._log.info("[DRY-RUN] µMD2 模拟连接")
        return "DRY_RUN"

    def reconnect(self, retries: int = 3) -> bool:
        return True

    def read_firmware_info(self, timeout: float = 5.0) -> DeviceInfo:
        return self.device_info

    def flush_queue(self) -> None:
        pass

    def read_displacement(self, n: int, timeout: float = 15.0) -> list[float]:
        """模拟约 410 nm/V 的线性响应，加 5 nm RMS 噪声。"""
        base_nm = self._current_voltage * 410.0
        return list(np.random.normal(base_nm, 5.0, n))

    def read_temperature(self, timeout: float = 2.0) -> Optional[float]:
        return self.device_info.temperature_C

    def set_voltage_hint(self, v: float) -> None:
        """供 DryRunMokuController 调用，同步当前电压状态到模拟位移。"""
        self._current_voltage = v

    def close(self) -> None:
        pass


# ============================================================
# Moku:Go 电压控制器
# ============================================================


class MokuController:
    """通过 Moku:Go WaveformGenerator 输出 DC 电压。"""

    def __init__(self, cfg: Config, logger: logging.Logger) -> None:
        self._cfg = cfg
        self._log = logger
        self._wg = None

    def connect(self, retries: int = 3) -> None:
        """连接 Moku:Go，失败时重试。"""
        from moku.instruments import WaveformGenerator  # type: ignore

        last_err: Exception = RuntimeError("未知错误")
        for attempt in range(1, retries + 1):
            try:
                self._log.info(
                    f"连接 Moku:Go {self._cfg.moku_ip} (尝试 {attempt}/{retries})"
                )
                self._wg = WaveformGenerator(self._cfg.moku_ip, force_connect=True)
                self._log.info(f"Moku:Go 已连接: {self._cfg.moku_ip}")
                return
            except Exception as e:
                last_err = e
                self._log.warning(f"Moku 连接失败: {e}")
                if attempt < retries:
                    time.sleep(2.0)
        raise RuntimeError(
            f"无法连接 Moku:Go ({self._cfg.moku_ip})，已重试 {retries} 次: {last_err}"
        )

    def set_voltage(self, channel: int, voltage: float) -> None:
        """在指定通道输出 DC 电压。"""
        if self._wg is None:
            raise RuntimeError("Moku 未连接，请先调用 connect()")
        self._wg.set_output(channel, "DC", dc_level=voltage)

    def zero_output(self, channel: int) -> None:
        """安全归零：将通道电压置为 0V。"""
        try:
            self.set_voltage(channel, 0.0)
        except Exception as e:
            self._log.warning(f"归零失败: {e}")

    def reconnect(self, retries: int = 3) -> bool:
        """重新连接 Moku:Go。"""
        try:
            self.connect(retries=retries)
            return True
        except RuntimeError:
            return False

    def close(self) -> None:
        """释放 Moku 控制权。"""
        if self._wg is not None:
            try:
                self._wg.relinquish_ownership()
                self._log.info("Moku 已释放")
            except Exception as e:
                self._log.warning(f"relinquish_ownership 失败: {e}")
            self._wg = None


class DryRunMokuController(MokuController):
    """--dry-run 模式下的空操作 Moku 控制器。"""

    def __init__(
        self, cfg: Config, logger: logging.Logger, umd2: DryRunUMD2Reader
    ) -> None:
        super().__init__(cfg, logger)
        self._umd2 = umd2

    def connect(self, retries: int = 3) -> None:
        self._log.info("[DRY-RUN] Moku:Go 模拟连接")

    def set_voltage(self, channel: int, voltage: float) -> None:
        self._umd2.set_voltage_hint(voltage)

    def zero_output(self, channel: int) -> None:
        self._umd2.set_voltage_hint(0.0)

    def reconnect(self, retries: int = 3) -> bool:
        return True

    def close(self) -> None:
        self._log.info("[DRY-RUN] Moku 已释放")


# ============================================================
# 数据存储
# ============================================================


class DataStore:
    """线程安全的测量点累积器。"""

    def __init__(self) -> None:
        self._points: list[MeasurementPoint] = []
        self._lock = threading.Lock()

    def add(self, point: MeasurementPoint) -> None:
        with self._lock:
            self._points.append(point)

    def points(self) -> list[MeasurementPoint]:
        with self._lock:
            return list(self._points)

    def to_dataframe(self) -> pd.DataFrame:
        pts = self.points()
        if not pts:
            return pd.DataFrame()
        return pd.DataFrame([p.__dict__ for p in pts])

    def __len__(self) -> int:
        with self._lock:
            return len(self._points)


# ============================================================
# 进度显示
# ============================================================


class ProgressDisplay:
    """实时进度打印，含 ETA 估算。"""

    def __init__(self, total_steps: int) -> None:
        self._total = total_steps
        self._done = 0
        self._start = time.monotonic()

    def update(self, point: MeasurementPoint, step: int, total: int) -> None:
        """打印单个测量点结果行。"""
        self._done += 1
        elapsed = time.monotonic() - self._start
        eta = self._eta_str(elapsed)
        print(
            f"[{step:3d}/{total:3d}] V={point.voltage_V:5.2f}V  "
            f"位移={point.mean_nm:8.1f} ±{point.std_nm:5.1f} nm  "
            f"CI95=±{point.ci_95_nm:.1f}nm  "
            f"n={point.n_samples}  ETA:{eta}"
        )

    def _eta_str(self, elapsed: float) -> str:
        if self._done == 0:
            return "--:--"
        remaining = (self._total - self._done) / self._done * elapsed
        m, s = divmod(int(remaining), 60)
        return f"{m:02d}:{s:02d}"

    @staticmethod
    def countdown(seconds: int, label: str = "等待稳定") -> None:
        """原地刷新倒计时进度条。"""
        bar_width = 20
        for remaining in range(seconds, -1, -1):
            frac = (seconds - remaining) / max(seconds, 1)
            filled = int(frac * bar_width)
            bar = "█" * filled + "░" * (bar_width - filled)
            pct = int(frac * 100)
            print(f"\r{label}: {remaining:3d}s [{bar}] {pct:3d}%", end="", flush=True)
            if remaining > 0:
                time.sleep(1)
        print()


# ============================================================
# CSV 写入
# ============================================================


_LUT_COLUMNS = [
    "temperature_C", "voltage_V", "direction", "mean_nm", "std_nm",
    "sem_nm", "ci_95_nm", "n_samples", "outliers_removed", "timestamp",
]


class CSVWriter:
    """将测量数据和统计摘要保存为 CSV 文件。"""

    def __init__(self, cfg: Config, timestamp: str) -> None:
        self._cfg = cfg
        self._ts = timestamp
        Path(cfg.output_dir).mkdir(parents=True, exist_ok=True)

    def save_partial(self, store: DataStore, temp_C: float) -> Path:
        """保存单个温度点的中间结果（防数据丢失）。"""
        path = Path(self._cfg.output_dir) / f"lut_partial_{int(temp_C)}C.csv"
        df = store.to_dataframe()
        if not df.empty:
            df[df["temperature_C"] == temp_C][_LUT_COLUMNS].to_csv(path, index=False)
        return path

    def save_full(self, store: DataStore) -> Path:
        """保存完整 LUT CSV，文件名含时间戳。"""
        path = Path(self._cfg.output_dir) / f"lut_{self._ts}.csv"
        df = store.to_dataframe()
        if not df.empty:
            df[_LUT_COLUMNS].to_csv(path, index=False)
        return path

    def save_summary(self, store: DataStore) -> Path:
        """计算并保存每个温度点的统计摘要。"""
        path = Path(self._cfg.output_dir) / f"summary_{self._ts}.csv"
        df = store.to_dataframe()
        rows = []

        for temp, grp in df.groupby("temperature_C"):
            up = grp[grp["direction"] == "up"].sort_values("voltage_V")
            dn = grp[grp["direction"] == "down"].sort_values("voltage_V")

            max_disp = float(grp["mean_nm"].max())

            # 最大迟滞：升压与降压在同一电压处的最大差值
            merged = up.merge(dn, on="voltage_V", suffixes=("_up", "_dn"))
            hyst = 0.0
            if not merged.empty:
                hyst = float(
                    (merged["mean_nm_up"] - merged["mean_nm_dn"]).abs().max()
                )

            # 线性度 R²（仅升压曲线）
            r2 = float("nan")
            sensitivity = float("nan")
            if len(up) >= 2:
                v = up["voltage_V"].values
                d = up["mean_nm"].values
                coeffs = np.polyfit(v, d, 1)
                fitted = np.polyval(coeffs, v)
                ss_res = float(np.sum((d - fitted) ** 2))
                ss_tot = float(np.sum((d - d.mean()) ** 2))
                r2 = 1.0 - ss_res / ss_tot if ss_tot > 0 else 1.0
                sensitivity = float(coeffs[0])

            rows.append({
                "temperature_C": temp,
                "max_displacement_nm": max_disp,
                "hysteresis_max_nm": hyst,
                "linearity_r2": r2,
                "sensitivity_nm_per_V": sensitivity,
            })

        pd.DataFrame(rows).to_csv(path, index=False)
        return path


# ============================================================
# 扫描执行器
# ============================================================


def run_sweep(
    cfg: Config,
    temp_C: float,
    direction: str,
    umd2: UMD2Reader,
    moku: MokuController,
    store: DataStore,
    logger: logging.Logger,
) -> list[MeasurementPoint]:
    """
    执行单次电压扫描（升压或降压）。

    每步：设置电压 → 等待稳定 → 清空积压数据 → 采集 N 帧 → 统计 → 记录。
    """
    voltages = cfg.voltage_steps
    if direction == "down":
        voltages = list(reversed(voltages))

    total = len(voltages)
    display = ProgressDisplay(total)
    points: list[MeasurementPoint] = []

    header = "── 升压扫描 ──" if direction == "up" else "── 降压扫描 ──"
    print(f"\n{header}")

    for step, voltage in enumerate(voltages, start=1):
        # 设置电压
        try:
            moku.set_voltage(cfg.moku_channel, voltage)
        except Exception as e:
            logger.error(f"Moku 设置电压 {voltage:.2f}V 失败: {e}")
            if not moku.reconnect():
                logger.error("Moku 重连失败，中止扫描")
                raise
            moku.set_voltage(cfg.moku_channel, voltage)

        # 等待稳定，然后清空积压帧（避免读到旧数据）
        time.sleep(cfg.settle_time)
        umd2.flush_queue()

        # 采集位移数据
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


# ============================================================
# 主采集流程
# ============================================================


def run_acquisition(cfg: Config) -> None:
    """
    主编排函数：连接设备 → 温度循环 → 升/降压扫描 → 保存 LUT。

    KeyboardInterrupt 时归零电压并保存已有数据后退出。
    """
    ts = datetime.now().strftime("%Y%m%d_%H%M%S")
    logger = setup_logging(cfg.output_dir, ts)
    store = DataStore()
    csv_writer = CSVWriter(cfg, ts)

    print("=" * 40)
    print("µMD2 LUT 自动采集系统")
    print("=" * 40)

    # 初始化设备对象
    if cfg.dry_run:
        dry_umd2 = DryRunUMD2Reader(cfg, logger)
        umd2: UMD2Reader = dry_umd2
        moku: MokuController = DryRunMokuController(cfg, logger, dry_umd2)
    else:
        umd2 = UMD2Reader(cfg, logger)
        moku = MokuController(cfg, logger)

    try:
        # 连接设备并打印信息
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

        for temp_idx, temp_C in enumerate(cfg.temperatures, start=1):
            print(f"\n{'-' * 40}")
            print(f"温度点 {temp_idx}/{len(cfg.temperatures)}: {temp_C}°C")
            print(f"{'-' * 40}")

            if multi_temp:
                input(f"请将温度调整至 {temp_C}°C，按 Enter 继续...")
                ProgressDisplay.countdown(cfg.temp_stabilize_time, "等待稳定")

            # 记录实测温度（如传感器可用）
            actual_temp = umd2.read_temperature(timeout=2.0)
            if actual_temp is not None:
                logger.info(f"实测温度: {actual_temp:.1f}°C (设定: {temp_C}°C)")

            # 升压扫描
            sweep_idx += 1
            pct = int(sweep_idx / total_sweeps * 100)
            logger.info(f"总进度: {pct}%  开始 {temp_C}°C 升压扫描")
            up_points = run_sweep(cfg, temp_C, "up", umd2, moku, store, logger)
            up_max = max(p.mean_nm for p in up_points) if up_points else 0.0
            print(f"\n[进度] {temp_C}°C 升压完成，最大位移={up_max:.1f}nm")

            # 降压扫描
            sweep_idx += 1
            pct = int(sweep_idx / total_sweeps * 100)
            logger.info(f"总进度: {pct}%  开始 {temp_C}°C 降压扫描")
            run_sweep(cfg, temp_C, "down", umd2, moku, store, logger)

            # 每温度完成后立即保存中间结果
            partial_path = csv_writer.save_partial(store, temp_C)
            logger.info(f"中间结果已保存: {partial_path}")
            print(f"[保存] 中间结果已保存: {partial_path}")

        # 归零并保存完整结果
        moku.zero_output(cfg.moku_channel)
        full_path    = csv_writer.save_full(store)
        summary_path = csv_writer.save_summary(store)

        print("\n" + "=" * 40)
        print("全部完成！")
        print(f"[保存] 完整LUT: {full_path}")
        print(f"[保存] 摘要:    {summary_path}")
        print("=" * 40)

        _demo_piezo_lut(str(full_path), cfg, logger)

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


def _demo_piezo_lut(
    csv_path: str, cfg: Config, logger: logging.Logger
) -> None:
    """演示 PiezoLUT 正向和反向查询。"""
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


# ============================================================
# PiezoLUT 查询接口
# ============================================================


class PiezoLUT:
    """
    Piezo 电压-位移查找表，支持正向和反向插值查询。

    正向查询：(温度, 电压) → 位移 nm  （双线性插值，温度轴 × 电压轴）
    反向查询：(温度, 目标位移 nm) → 电压 V  （Brent 二分法）

    使用示例：
        lut = PiezoLUT.from_csv('lut_20250506_143022.csv')
        nm  = lut.forward(25.0, 3.0, direction='up')
        v   = lut.inverse(25.0, 1000.0, direction='up')
    """

    def __init__(self, df: pd.DataFrame) -> None:
        """从 DataFrame 构建插值器，每个方向独立建表。"""
        self._df = df.copy()
        self._interpolators: dict[str, RegularGridInterpolator] = {}
        self._v_bounds: dict[str, tuple[float, float]] = {}
        self._build_interpolators()

    def _build_interpolators(self) -> None:
        """为每个扫描方向（up/down）构建 RegularGridInterpolator。"""
        for direction in ("up", "down"):
            sub = self._df[self._df["direction"] == direction]
            if sub.empty:
                continue
            temps    = sorted(sub["temperature_C"].unique())
            voltages = sorted(sub["voltage_V"].unique())

            grid = np.zeros((len(temps), len(voltages)), dtype=float)
            for ti, temp in enumerate(temps):
                for vi, volt in enumerate(voltages):
                    row = sub[
                        (sub["temperature_C"] == temp) & (sub["voltage_V"] == volt)
                    ]
                    grid[ti, vi] = float(row["mean_nm"].iloc[0]) if not row.empty else 0.0

            self._interpolators[direction] = RegularGridInterpolator(
                (np.array(temps, dtype=float), np.array(voltages, dtype=float)),
                grid,
                method="linear",
                bounds_error=False,
                fill_value=None,   # 越界时线性外推
            )
            self._v_bounds[direction] = (min(voltages), max(voltages))

    @classmethod
    def from_csv(cls, path: str) -> "PiezoLUT":
        """从 CSV 文件加载 LUT，返回 PiezoLUT 实例。"""
        df = pd.read_csv(path)
        required = {"temperature_C", "voltage_V", "direction", "mean_nm"}
        missing = required - set(df.columns)
        if missing:
            raise ValueError(f"CSV 缺少必要列: {missing}")
        return cls(df)

    def forward(
        self, temp_C: float, voltage_V: float, direction: str = "up"
    ) -> float:
        """
        正向查询：给定温度和电压，返回位移（nm）。

        使用双线性插值（温度轴 × 电压轴）。
        """
        interp = self._interpolators.get(direction)
        if interp is None:
            raise ValueError(f'方向 "{direction}" 无数据，请检查 CSV')
        result = interp([[float(temp_C), float(voltage_V)]])
        return float(result[0])

    def inverse(
        self, temp_C: float, target_nm: float, direction: str = "up"
    ) -> float:
        """
        反向查询：给定温度和目标位移（nm），返回所需电压（V）。

        使用 Brent 二分法在 [v_min, v_max] 内求解。
        若目标超出量程，返回最近边界对应的电压。
        """
        if direction not in self._v_bounds:
            raise ValueError(f'方向 "{direction}" 无数据')
        v_min, v_max = self._v_bounds[direction]

        def residual(v: float) -> float:
            return self.forward(temp_C, v, direction) - target_nm

        fa, fb = residual(v_min), residual(v_max)
        if fa * fb > 0:
            # 目标不在可解范围，返回最近端点
            return v_min if abs(fa) < abs(fb) else v_max
        return float(brentq(residual, v_min, v_max, xtol=1e-6, maxiter=100))

    def temperatures(self) -> list[float]:
        """返回 LUT 中所有温度点。"""
        return sorted(self._df["temperature_C"].unique().tolist())

    def voltage_range(self, direction: str = "up") -> tuple[float, float]:
        """返回指定方向的电压范围 (v_min, v_max)。"""
        return self._v_bounds.get(direction, (0.0, 0.0))


# ============================================================
# PID 闭环控制
# ============================================================


@dataclass
class PIDResult:
    """PID 闭环控制的最终结果。"""

    converged: bool
    final_voltage_V: float
    final_position_nm: float
    final_error_nm: float
    iterations: int
    elapsed_s: float


class PIDController:
    """
    离散时间 PI/PID 控制器，含积分抗饱和。

    输入：位移误差（nm）
    输出：电压修正量（V）
    """

    def __init__(
        self,
        kp: float,
        ki: float,
        kd: float,
        integral_limit: float,
    ) -> None:
        self.kp = kp
        self.ki = ki
        self.kd = kd
        self.integral_limit = integral_limit
        self._integral = 0.0
        self._prev_error = 0.0

    def reset(self) -> None:
        """复位积分器和微分历史值。"""
        self._integral = 0.0
        self._prev_error = 0.0

    def update(self, error_nm: float, dt: float) -> float:
        """
        计算本次迭代的电压修正量（V）。

        error_nm: 目标位移 - 当前位移（正值表示需增大位移）
        dt: 距上次调用的时间间隔（s）
        返回值：应叠加到当前电压上的修正量（V）
        """
        # 积分项（限幅防飞车）
        self._integral += error_nm * dt
        i_contribution = max(
            -self.integral_limit,
            min(self.integral_limit, self.ki * self._integral),
        )
        if self.ki > 1e-12:
            self._integral = i_contribution / self.ki  # 反向修正保持一致

        # 微分项（基于误差差分）
        d_contribution = (
            self.kd * (error_nm - self._prev_error) / dt if dt > 1e-6 else 0.0
        )
        self._prev_error = error_nm

        return self.kp * error_nm + i_contribution + d_contribution


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

    控制策略：
    1. 若提供 LUT，先用反向查询得到前馈电压（快速接近目标，消除大部分误差）
    2. PI 反馈修正残差（精确定位）
    3. 连续 pid_converge_count 次误差 < pid_tolerance_nm 则判定收敛
    4. KeyboardInterrupt 立即中止循环并返回当前状态
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

    # Step 1：前馈初始化
    if lut is not None:
        try:
            v_current = float(np.clip(
                lut.inverse(temperature_C, target_nm, direction="up"), v_min, v_max
            ))
            print(f"LUT 前馈电压: {v_current:.4f} V")
            logger.info(f"[PID] LUT 前馈: {v_current:.4f} V")
        except Exception as e:
            logger.warning(f"[PID] LUT 前馈失败: {e}，从 {v_min}V 开始")
            v_current = v_min
    else:
        v_current = v_min
        print(f"无 LUT 前馈，从 {v_current:.2f}V 开始")
        logger.info(f"[PID] 无 LUT，从 {v_current:.2f}V 开始")

    moku.set_voltage(channel, v_current)
    time.sleep(cfg.settle_time * 2)
    umd2.flush_queue()

    # Step 2：PID 反馈循环
    pid = PIDController(
        kp=cfg.pid_kp,
        ki=cfg.pid_ki,
        kd=cfg.pid_kd,
        integral_limit=cfg.pid_integral_limit,
    )

    converge_count = 0
    iteration = 0
    t_start = time.monotonic()
    t_prev = t_start
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

            # 采集当前位移均值
            raw = umd2.read_displacement(cfg.pid_sample_avg, timeout=5.0)
            if not raw:
                logger.warning("[PID] 采样为空，跳过本次迭代")
                continue

            stats = compute_stats(raw, cfg.outlier_sigma)
            pos_nm = stats["mean"]
            last_pos = pos_nm
            error_nm = target_nm - pos_nm
            iteration += 1

            # 计算 dt 并更新 PID
            t_now = time.monotonic()
            dt = max(t_now - t_prev, 1e-6)
            t_prev = t_now

            delta_v = pid.update(error_nm, dt)
            v_current = float(np.clip(v_current + delta_v, v_min, v_max))
            moku.set_voltage(channel, v_current)

            # 收敛计数
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

            # 控制循环节拍
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


# ============================================================
# CLI 入口
# ============================================================


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
        for temp in temps[:2]:   # 最多演示前两个温度点
            try:
                nm  = lut.forward(temp, mid_v, direction=direction)
                v   = lut.inverse(temp, nm,    direction=direction)
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
) -> None:
    """PID 闭环定位模式：连接设备，驱动 Piezo 到达目标位移后保持。"""
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

    try:
        port = umd2.connect()
        info = umd2.read_firmware_info(timeout=5.0)
        print(f"[设备] µMD2: {port}  固件: {info.firmware_version or '未知'}")
        moku.connect()
        print(f"[设备] Moku:Go: {cfg.moku_ip}")

        result = run_pid_control(
            target_nm=target_nm,
            cfg=cfg,
            umd2=umd2,
            moku=moku,
            logger=logger,
            lut=lut,
            temperature_C=temperature_C,
        )

        if result.converged:
            print(f"\n[PID] 已锁定在 {result.final_position_nm:.1f} nm，按 Ctrl+C 归零退出...")
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
        print("[PID] 电压已归零，退出")


def main() -> None:
    """命令行入口：支持 --dry-run、--load、--pid 参数。"""
    parser = argparse.ArgumentParser(
        description="Piezo 电压-位移 LUT 自动采集系统 / PID 闭环定位系统",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
示例:
  python main.py                                    # 正常采集（需连接硬件）
  python main.py --dry-run                          # 模拟采集（无需硬件）
  python main.py --load lut_xxx.csv                 # 查询模式
  python main.py --pid 1000                         # PID 定位到 1000 nm
  python main.py --pid 1000 --load lut_xxx.csv      # PID + LUT 前馈
  python main.py --pid 1000 --dry-run               # PID 模拟模式
        """,
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="不连接硬件，用随机数模拟，用于测试脚本逻辑",
    )
    parser.add_argument(
        "--load",
        metavar="CSV",
        help="加载已有 LUT CSV；单独使用时进入查询模式，与 --pid 合用时作为前馈",
    )
    parser.add_argument(
        "--pid",
        metavar="NM",
        type=float,
        help="PID 闭环定位：驱动 Piezo 到达目标位移（nm）",
    )
    parser.add_argument(
        "--pid-temp",
        metavar="TEMP",
        type=float,
        default=25.0,
        help="PID 模式的温度 °C，用于 LUT 前馈查询（默认 25）",
    )
    args = parser.parse_args()

    cfg = Config(dry_run=args.dry_run)

    if args.pid is not None:
        _pid_mode(
            target_nm=args.pid,
            temperature_C=args.pid_temp,
            lut_path=args.load,
            cfg=cfg,
        )
        return

    if args.load:
        _query_mode(args.load)
        return

    run_acquisition(cfg)


if __name__ == "__main__":
    main()
