"""项目共用数据结构（纯 dataclass，无业务逻辑）。"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class MeasurementPoint:
    temperature_C: float
    voltage_V: float
    direction: str
    mean_nm: float
    std_nm: float
    sem_nm: float
    ci_95_nm: float
    n_samples: int
    outliers_removed: int
    timestamp: str


@dataclass
class DeviceInfo:
    firmware_version: Optional[str] = None
    sample_rate_hz: Optional[int]   = None
    temperature_C: Optional[float]  = None
    port: Optional[str]             = None


@dataclass
class ModelParams:
    """单温度点的 FOPDT 动态模型参数（由阶跃响应辨识得到）。"""

    temperature_C: float
    K_nm_per_V: float
    tau_ms: float
    theta_ms: float
    v_dead_V: float
    r2_fit: float
    noise_rms_nm: float
    theta_piezo_ms: float    = 0.0
    theta_protocol_ms: float = 0.0
    timestamp: str           = ""

    # ── 便捷属性（供控制器使用）──────────────────────────────────────
    @property
    def K(self) -> float:
        return self.K_nm_per_V

    @property
    def tau_s(self) -> float:
        return self.tau_ms * 1e-3

    @property
    def theta_plant_s(self) -> float:
        return self.theta_piezo_ms * 1e-3

    @property
    def theta_sensor_s(self) -> float:
        return self.theta_protocol_ms * 1e-3


@dataclass
class PIDResult:
    converged: bool
    final_voltage_V: float
    final_position_nm: float
    final_error_nm: float
    iterations: int
    elapsed_s: float


@dataclass
class AutoTuneResult:
    success: bool
    message: str
    K_nm_per_V: float = 0.0
    tau_s: float      = 0.0
    theta_s: float    = 0.0
    kp: float         = 0.0
    ki: float         = 0.0
    method: str       = ""


@dataclass
class TrajectoryResult:
    """轨迹跟踪运行结果与性能指标。"""
    waveform: str
    frequency_hz: float
    amplitude_nm: float
    offset_nm: float
    duration_s: float
    times_s: list
    setpoints_nm: list
    measured_nm: list
    voltages_V: list
    rmse_nm: float
    max_error_nm: float
    bandwidth_warning: bool
