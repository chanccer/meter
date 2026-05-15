"""全局配置常量与 Config dataclass。"""
from __future__ import annotations

from dataclasses import dataclass, field

# ── 硬件连接 ────────────────────────────────────────────────────────────────
UMD2_PORT           = "AUTO"
UMD2_BAUD           = 9600
UMD2_RESOLUTION     = "PMI"   # 'PMI'=40nm/count, 'LI'=79nm/count

MOKU_IP             = "192.168.73.1"
MOKU_CHANNEL        = 1

# ── 扫描参数 ────────────────────────────────────────────────────────────────
V_START             = 0.0
V_END               = 5.0
V_STEP              = 0.1
SETTLE_TIME         = 0.5    # s

TEMPERATURES        = [25.0]
TEMP_STABILIZE_TIME = 300    # s

N_SAMPLES           = 100
OUTLIER_SIGMA       = 3.0
OUTPUT_DIR          = "./lut_output"

# ── PID 控制参数 ─────────────────────────────────────────────────────────────
PID_KP              = 0.001
PID_KI              = 0.0002
PID_KD              = 0.0
PID_TOLERANCE_NM    = 5.0
PID_CONVERGE_COUNT  = 5
PID_TIMEOUT_S       = 30.0
PID_SAMPLE_AVG      = 20
PID_LOOP_INTERVAL   = 0.05   # s
PID_INTEGRAL_LIMIT  = 0.5    # V

# ── ADRC 控制参数（需配合模型辨识或手动设定）────────────────────────────────
ADRC_WC             = 20.0   # rad/s  控制器带宽
ADRC_W0             = 100.0  # rad/s  ESO 带宽（通常 5×ωc）
ADRC_K              = 410.0  # nm/V   植物增益（无模型文件时使用）
ADRC_TAU_MS         = 80.0   # ms     时间常数（无模型文件时使用）
ADRC_SMITH          = True   # Smith Predictor 开关

# ── 自动整定参数 ─────────────────────────────────────────────────────────────
AUTOTUNE_V_LOW      = 0.5
AUTOTUNE_V_HIGH     = 2.5
AUTOTUNE_COLLECT_S  = 3.0
AUTOTUNE_METHOD     = "IMC"
AUTOTUNE_LAMBDA     = 1.0

# ── 模型辨识参数 ─────────────────────────────────────────────────────────────
STEP_IDENT_ENABLED  = True
STEP_IDENT_V_LOW    = 0.5
STEP_IDENT_V_HIGH   = 2.5
STEP_IDENT_COLLECT_S = 3.0
STEP_IDENT_REPS     = 3

PROTO_DELAY_REPS    = 10

# ── 轨迹跟踪参数 ─────────────────────────────────────────────────────────────
TRAJ_WAVEFORM       = "sine"   # 默认波形：sine / triangle / sawtooth / square
TRAJ_FREQ_HZ        = 0.5     # Hz
TRAJ_AMP_NM         = 500.0   # nm（半幅值）
TRAJ_OFFSET_NM      = 1000.0  # nm（轨迹中心位置）
TRAJ_DURATION_S     = 10.0    # s

# ── 内部常量 ──────────────────────────────────────────────────────────────────
_RESOLUTION_NM: dict[str, int] = {"PMI": 40, "LI": 79}


@dataclass
class Config:
    """所有运行参数的集中配置（通过 dataclass 传递，避免全局变量）。"""

    umd2_port: str           = UMD2_PORT
    umd2_baud: int           = UMD2_BAUD
    umd2_resolution: str     = UMD2_RESOLUTION
    moku_ip: str             = MOKU_IP
    moku_channel: int        = MOKU_CHANNEL
    v_start: float           = V_START
    v_end: float             = V_END
    v_step: float            = V_STEP
    settle_time: float       = SETTLE_TIME
    temperatures: list[float] = field(default_factory=lambda: list(TEMPERATURES))
    temp_stabilize_time: int = TEMP_STABILIZE_TIME
    n_samples: int           = N_SAMPLES
    outlier_sigma: float     = OUTLIER_SIGMA
    output_dir: str          = OUTPUT_DIR
    dry_run: bool            = False
    # PID
    pid_kp: float            = PID_KP
    pid_ki: float            = PID_KI
    pid_kd: float            = PID_KD
    pid_tolerance_nm: float  = PID_TOLERANCE_NM
    pid_converge_count: int  = PID_CONVERGE_COUNT
    pid_timeout_s: float     = PID_TIMEOUT_S
    pid_sample_avg: int      = PID_SAMPLE_AVG
    pid_loop_interval: float = PID_LOOP_INTERVAL
    pid_integral_limit: float = PID_INTEGRAL_LIMIT
    # ADRC
    adrc_wc: float           = ADRC_WC
    adrc_w0: float           = ADRC_W0
    adrc_K: float            = ADRC_K
    adrc_tau_ms: float       = ADRC_TAU_MS
    adrc_smith: bool         = ADRC_SMITH
    # 自动整定
    autotune_v_low: float    = AUTOTUNE_V_LOW
    autotune_v_high: float   = AUTOTUNE_V_HIGH
    autotune_collect_s: float = AUTOTUNE_COLLECT_S
    autotune_method: str     = AUTOTUNE_METHOD
    autotune_lambda: float   = AUTOTUNE_LAMBDA
    # 模型辨识
    step_ident_enabled: bool  = STEP_IDENT_ENABLED
    step_ident_v_low: float   = STEP_IDENT_V_LOW
    step_ident_v_high: float  = STEP_IDENT_V_HIGH
    step_ident_collect_s: float = STEP_IDENT_COLLECT_S
    step_ident_reps: int      = STEP_IDENT_REPS
    proto_delay_reps: int     = PROTO_DELAY_REPS
    # 轨迹跟踪
    traj_waveform: str        = TRAJ_WAVEFORM
    traj_freq_hz: float       = TRAJ_FREQ_HZ
    traj_amp_nm: float        = TRAJ_AMP_NM
    traj_offset_nm: float     = TRAJ_OFFSET_NM
    traj_duration_s: float    = TRAJ_DURATION_S

    @property
    def nm_per_count(self) -> int:
        return _RESOLUTION_NM.get(self.umd2_resolution, 40)

    @property
    def voltage_steps(self) -> list[float]:
        n = round((self.v_end - self.v_start) / self.v_step) + 1
        return [round(self.v_start + i * self.v_step, 9) for i in range(n)]
