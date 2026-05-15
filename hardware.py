"""硬件驱动：µMD2 串口读取器 + Moku:Go 电压控制器（含 dry-run 模拟类）。"""
from __future__ import annotations

import logging
import queue
import threading
import time
from typing import Optional

import numpy as np
import serial
import serial.tools.list_ports

from config import Config
from models import DeviceInfo


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
        while not self._queue.empty():
            try:
                self._queue.get_nowait()
            except queue.Empty:
                break

    def read_displacement(self, n: int, timeout: float = 15.0) -> list[float]:
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

    def read_displacement_timed(
        self, duration_s: float
    ) -> tuple[list[float], list[float]]:
        nm_per_count = self._cfg.nm_per_count
        times: list[float] = []
        samples: list[float] = []
        t_start = time.monotonic()
        deadline = t_start + duration_s
        while time.monotonic() < deadline:
            try:
                line = self._queue.get(timeout=0.005)
            except queue.Empty:
                continue
            parsed = self._parse_line(line)
            if parsed:
                disp_count, _, _ = parsed
                times.append(time.monotonic() - t_start)
                samples.append(float(disp_count) * nm_per_count)
        return times, samples

    def read_temperature(self, timeout: float = 2.0) -> Optional[float]:
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

    def measure_frame_interval(self, timeout: float = 0.5) -> Optional[float]:
        t0 = time.monotonic()
        try:
            self._queue.get(timeout=timeout)
            return (time.monotonic() - t0) * 1000.0
        except queue.Empty:
            return None

    def close(self) -> None:
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
        self._prev_voltage: float = 0.0
        self._y_state: float = 0.0   # first-order plant state for ADRC dry-run
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
        # Simulate first-order FOPDT plant dynamics so ADRC ESO stays stable
        K, tau = 410.0, 0.08
        dt = self._cfg.pid_loop_interval
        alpha = np.exp(-dt / tau)
        self._y_state = alpha * self._y_state + (1.0 - alpha) * (self._current_voltage * K)
        return list(np.random.normal(self._y_state, 5.0, n))

    def read_temperature(self, timeout: float = 2.0) -> Optional[float]:
        return self.device_info.temperature_C

    def set_voltage_hint(self, v: float) -> None:
        self._prev_voltage = self._current_voltage
        self._current_voltage = v
        # _y_state evolves lazily in read_displacement, no update needed here

    def read_displacement_timed(
        self, duration_s: float
    ) -> tuple[list[float], list[float]]:
        K, tau, theta = 410.0, 0.08, 0.01
        y0 = getattr(self, "_prev_voltage", self._current_voltage) * K
        y_inf = self._current_voltage * K
        delta_nm = y_inf - y0
        dt = 0.001
        n = max(int(duration_s / dt), 1)
        t = np.arange(n, dtype=float) * dt
        resp = np.where(
            t > theta,
            y0 + delta_nm * (1.0 - np.exp(-(t - theta) / tau)),
            y0,
        )
        resp += np.random.normal(0.0, 5.0, n)
        return list(t), list(resp)

    def measure_frame_interval(self, timeout: float = 0.5) -> Optional[float]:
        time.sleep(0.001)
        return 3.0

    def close(self) -> None:
        pass


class MokuController:
    """通过 Moku:Go WaveformGenerator 输出 DC 电压。"""

    def __init__(self, cfg: Config, logger: logging.Logger) -> None:
        self._cfg = cfg
        self._log = logger
        self._wg = None

    def connect(self, retries: int = 3) -> None:
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
        if self._wg is None:
            raise RuntimeError("Moku 未连接，请先调用 connect()")
        self._wg.set_output(channel, "DC", dc_level=voltage)

    def zero_output(self, channel: int) -> None:
        try:
            self.set_voltage(channel, 0.0)
        except Exception as e:
            self._log.warning(f"归零失败: {e}")

    def reconnect(self, retries: int = 3) -> bool:
        try:
            self.connect(retries=retries)
            return True
        except RuntimeError:
            return False

    def close(self) -> None:
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
