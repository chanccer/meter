"""日志配置、统计工具、DataStore、ProgressDisplay。"""
from __future__ import annotations

import logging
import math
import sys
import threading
import time
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np
import pandas as pd

if TYPE_CHECKING:
    from models import MeasurementPoint


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


def filter_outliers(data: np.ndarray, sigma: float) -> tuple[np.ndarray, int]:
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
    return {
        "mean": mean, "std": std, "sem": sem, "ci_95": 1.96 * sem,
        "n_samples": n, "outliers_removed": n_removed,
    }


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


class ProgressDisplay:
    """实时进度打印，含 ETA 估算。"""

    def __init__(self, total_steps: int) -> None:
        self._total = total_steps
        self._done = 0
        self._start = time.monotonic()

    def update(self, point: MeasurementPoint, step: int, total: int) -> None:
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
