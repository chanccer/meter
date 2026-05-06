# meter — Piezo Voltage-Displacement LUT Acquisition System

Automatically builds a voltage-displacement lookup table (LUT) for Piezo actuators, and provides a **closed-loop PID positioning mode** that drives the Piezo to a target displacement. Displacement data is collected at nanometer resolution via a **µMD2** USB serial sensor; drive voltage is output by a **Moku:Go** waveform generator. Supports multi-temperature characterization, hysteresis measurement, and bidirectional interpolation queries.

---

## Hardware Requirements

| Device | Description |
|--------|-------------|
| µMD2 | Teensy 4.0-based USB serial sensor, 1000 samples/s, PMI=40 nm/count or LI=79 nm/count |
| Moku:Go | Network-connected (default IP `192.168.73.1`), DC voltage output to drive Piezo |

---

## Installation

Requires Python 3.14+ and [uv](https://docs.astral.sh/uv/). Runs on **Windows, macOS, and Linux**.

```bash
git clone <repo>
cd meter
uv sync
```

Dependencies (`pyproject.toml`): `moku`, `numpy`, `pandas`, `pyserial`, `scipy`

### Windows notes

| Topic | Detail |
|-------|--------|
| Serial port | Use `COM`-style names (`COM3`, `COM7`, …). `AUTO` detection works automatically. |
| Console encoding | The script patches stdout to UTF-8 at startup for Chinese characters and Unicode symbols. For the best experience use **Windows Terminal** or **PowerShell 7+**; old `cmd.exe` may still mangle some glyphs. |
| Run command | `uv run python main.py` — identical to macOS/Linux. |
| Moku SDK | Supported on Windows — no extra steps needed. |

If you see garbled output in `cmd.exe`, run once with UTF-8 mode forced:

```cmd
set PYTHONUTF8=1
uv run python main.py --dry-run
```

---

## Quick Start

### Simulate acquisition (no hardware needed)

```bash
uv run python main.py --dry-run
```

Simulates µMD2 and Moku:Go with random data, runs the full acquisition pipeline, and saves output files to `./lut_output/`. Use this to verify script logic and output format before connecting hardware.

### Live acquisition

```bash
uv run python main.py
```

Connects to hardware and runs the voltage sweep according to the configuration parameters. Saves the LUT CSV and statistics summary on completion.

### Load an existing LUT for queries

```bash
uv run python main.py --load lut_output/lut_20250506_143022.csv
```

Skips acquisition and loads a previously saved CSV file, then demonstrates forward and inverse interpolation queries.

### PID closed-loop positioning

```bash
# Drive Piezo to 1000 nm (no feedforward — starts from V_START, pure PI control)
uv run python main.py --pid 1000

# Recommended: add LUT feedforward for fast, accurate convergence
uv run python main.py --pid 1000 --load lut_output/lut_20250506_143022.csv

# Specify temperature for LUT lookup (default 25 °C)
uv run python main.py --pid 1000 --load lut_xxx.csv --pid-temp 30

# Simulate PID without hardware
uv run python main.py --pid 1000 --load lut_xxx.csv --dry-run
```

The controller outputs the current voltage, measured displacement, and positioning error on each iteration. When the error has stayed within `PID_TOLERANCE_NM` for `PID_CONVERGE_COUNT` consecutive iterations, the Piezo is locked at the target and the script holds until `Ctrl+C`. On exit, the voltage is zeroed automatically.

---

## Configuration

All parameters are defined at the top of `main.py`. Edit them directly before running.

```python
UMD2_PORT           = "AUTO"       # Auto-detect, or specify 'COM7' / '/dev/ttyUSB0'
UMD2_BAUD           = 9600
UMD2_RESOLUTION     = "PMI"        # 'PMI'=40 nm/count, 'LI'=79 nm/count

MOKU_IP             = "192.168.73.1"
MOKU_CHANNEL        = 1

V_START             = 0.0          # Start voltage (V)
V_END               = 5.0          # End voltage (V)
V_STEP              = 0.1          # Step size (V)
SETTLE_TIME         = 0.5          # Settling wait per step (s)

TEMPERATURES        = [25.0]       # Temperature list (°C); multiple values pause for operator
TEMP_STABILIZE_TIME = 300          # Stabilization wait after temperature change (s)

N_SAMPLES           = 100          # Frames collected per voltage point
OUTLIER_SIGMA       = 3.0          # Outlier rejection threshold (σ)

OUTPUT_DIR          = "./lut_output"

# PID closed-loop control
PID_KP              = 0.001        # Proportional gain (V/nm)
PID_KI              = 0.0002       # Integral gain (V/(nm·s))
PID_KD              = 0.0          # Derivative gain (V·s/nm) — off by default
PID_TOLERANCE_NM    = 5.0          # Convergence tolerance (nm)
PID_CONVERGE_COUNT  = 5            # Consecutive readings within tolerance to confirm lock
PID_TIMEOUT_S       = 30.0         # Maximum time to converge (s)
PID_SAMPLE_AVG      = 20           # Frames averaged per PID iteration
PID_LOOP_INTERVAL   = 0.05         # Target loop interval (s)
PID_INTEGRAL_LIMIT  = 0.5          # Maximum I-term contribution (V) — anti-windup cap
```

**Multi-temperature example:**

```python
TEMPERATURES = [20, 25, 30, 35, 40]
```

The script pauses before each temperature point, prompts the operator to adjust the setpoint, then counts down `TEMP_STABILIZE_TIME` seconds before sweeping. With a single temperature (the default), the prompt and countdown are skipped.

---

## Acquisition Flow

For each temperature point:

1. **Up sweep** — `V_START → V_END`, step `V_STEP`
2. **Down sweep** — `V_END → V_START`, step `V_STEP`

Each step:

```
set_voltage(V) → sleep(SETTLE_TIME) → flush stale frames → collect N_SAMPLES frames
→ 3-sigma outlier rejection → compute mean / std / sem / CI₉₅ → record
```

An intermediate CSV is saved immediately after each temperature point completes (protects against data loss). The full LUT and summary are saved at the end.

---

## Measurement Methodology

### Sampling and averaging

Each voltage step collects **`N_SAMPLES` raw displacement frames** from the µMD2 (default: 100 frames). The µMD2 outputs at **1000 samples/s**, so 100 frames span approximately 0.1 s of stationary signal. Before sampling begins, the script waits `SETTLE_TIME` (default: 0.5 s) to let the Piezo reach mechanical equilibrium, then flushes any queued frames so only steady-state data enters the statistics.

### Outlier rejection — 3-σ filter

Raw samples occasionally contain glitches from electrical interference or serial framing errors. A **3-sigma filter** removes them:

```
μ  = mean of all n raw samples
σ  = sample standard deviation  (ddof = 1)

Keep sample xᵢ  if  |xᵢ − μ| ≤ 3σ
Discard otherwise  (recorded as outliers_removed)
```

Typically fewer than 1 % of samples are rejected under normal lab conditions. The threshold can be tightened (e.g. `OUTLIER_SIGMA = 2.5`) for noisier environments or loosened for very low-noise setups.

### Expected-value estimation

After filtering, the **arithmetic mean of the surviving samples** is used as the best linear unbiased estimator (BLUE) of the true displacement at that voltage:

| Statistic | Formula | Meaning |
|-----------|---------|---------|
| `mean_nm` | $\bar{x} = \frac{1}{n}\sum x_i$ | Point estimate of true displacement |
| `std_nm` | $s = \sqrt{\frac{\sum(x_i-\bar{x})^2}{n-1}}$ | Spread of individual readings (sensor noise) |
| `sem_nm` | $\text{SEM} = s / \sqrt{n}$ | Uncertainty of the mean itself |
| `ci_95_nm` | $1.96 \times \text{SEM}$ | 95 % confidence interval half-width (large-*n* approximation) |

With µMD2 noise of approximately **5 nm RMS** and **n = 100** samples, the uncertainty of the mean is:

$$\text{SEM} \approx \frac{5\,\text{nm}}{\sqrt{100}} = 0.5\,\text{nm}$$

Increasing `N_SAMPLES` to 500 reduces SEM to ~0.22 nm at the cost of longer acquisition time per point.

### Resolution and unit conversion

The µMD2 firmware outputs raw **displacement counts**. The physical scale factor depends on the selected sensor mode:

| Mode | Scale | Typical full-range displacement |
|------|-------|-------------------------------|
| `PMI` | 40 nm/count | ~0–4 µm over 0–5 V |
| `LI`  | 79 nm/count | ~0–8 µm over 0–5 V |

The conversion `nm = count × nm_per_count` is applied to every raw frame before any statistics are computed.

### Hysteresis characterization

Piezo actuators exhibit **mechanical hysteresis**: the displacement at a given voltage differs depending on whether the voltage was approached from below (up-sweep) or above (down-sweep). The script captures both directions and stores them as separate `direction = "up"` / `"down"` rows. The summary CSV reports the **maximum absolute difference** between the two curves at the same voltage points as `hysteresis_max_nm`.

---

## Output Files

All files are written to `OUTPUT_DIR` (default `./lut_output/`):

| File | Description |
|------|-------------|
| `lut_YYYYMMDD_HHMMSS.csv` | Complete LUT data |
| `summary_YYYYMMDD_HHMMSS.csv` | Per-temperature statistics summary |
| `lut_partial_25C.csv` | Intermediate results (updated after each temperature) |
| `lut_YYYYMMDD_HHMMSS.log` | Full log file (DEBUG level) |

### Main LUT CSV columns

| Column | Description |
|--------|-------------|
| `temperature_C` | Temperature (°C) |
| `voltage_V` | Drive voltage (V) |
| `direction` | `up` (ascending) or `down` (descending) |
| `mean_nm` | Mean displacement (nm) |
| `std_nm` | Standard deviation (nm) |
| `sem_nm` | Standard error of the mean (nm) |
| `ci_95_nm` | 95% confidence interval half-width (nm) |
| `n_samples` | Effective sample count after outlier removal |
| `outliers_removed` | Number of rejected outliers |
| `timestamp` | Acquisition time (ISO 8601) |

### Summary CSV columns

| Column | Description |
|--------|-------------|
| `temperature_C` | Temperature (°C) |
| `max_displacement_nm` | Maximum displacement (nm) |
| `hysteresis_max_nm` | Maximum hysteresis between up/down curves (nm) |
| `linearity_r2` | R² of the up-sweep linear fit |
| `sensitivity_nm_per_V` | Sensitivity (nm/V, slope of up-sweep) |

---

## PiezoLUT Query Interface

After acquisition the script prints a short query demonstration. You can also import and use `PiezoLUT` directly:

```python
from main import PiezoLUT

# Load a saved LUT
lut = PiezoLUT.from_csv("lut_output/lut_20250506_143022.csv")

# Forward query: (temperature, voltage) → displacement nm  (bilinear interpolation)
displacement_nm = lut.forward(25.0, 3.0, direction="up")

# Inverse query: (temperature, target displacement) → voltage V  (Brent's method)
voltage_V = lut.inverse(25.0, 1000.0, direction="up")

# List all temperature points in the LUT
temps = lut.temperatures()           # e.g. [20.0, 25.0, 30.0]

# Get the voltage range for a given direction
v_min, v_max = lut.voltage_range(direction="up")
```

The `direction` parameter (`"up"` or `"down"`) selects which hysteresis branch to query.

---

## PID Closed-Loop Positioning

### Control strategy

```
LUT inverse query → feedforward voltage (fast, ~99 % of the way)
                 ↓
           PI feedback → corrects residual error (precise)
                 ↓
       Converged when |error| < PID_TOLERANCE_NM for PID_CONVERGE_COUNT consecutive steps
```

The LUT feedforward is **strongly recommended**. Without it, the controller starts from `V_START` and relies on pure PI, which accumulates a large integral over the initial approach and may converge slowly. With LUT feedforward, the initial error is typically < 20 nm and convergence takes only a few iterations.

### Console output example

```
========================================
PID 闭环定位
========================================
目标位移 : 1000.0 nm   温度: 25.0°C
增益     : Kp=0.001  Ki=0.0002  Kd=0.0
收敛条件 : |误差| < 5.0 nm  连续 5 次
超时     : 30.0 s
LUT 前馈电压: 2.4380 V

    迭代     电压(V)      位移(nm)      误差(nm)  状态
--------------------------------------------------------
     1    2.4391       998.9        +1.1  ✓ ×1
     2    2.4377      1001.3        -1.3  ✓ ×2
     3    2.4368      1000.9        -0.9  ✓ ×3
     4    2.4388       998.0        +2.0  ✓ ×4
     5    2.4387      1000.1        -0.1  ✓ ×5

✅ 收敛！  位移=1000.1nm  误差=-0.1nm  电压=2.4387V  用时=0.2s
```

### Tuning guidelines

| Parameter | Effect | Starting point |
|-----------|--------|----------------|
| `PID_KP` | Speed of initial correction. Too high → oscillation. | `0.001` V/nm |
| `PID_KI` | Eliminates steady-state offset. Too high → slow windup/overshoot. | `0.0002` V/(nm·s) |
| `PID_KD` | Damps oscillation. Amplifies sensor noise — leave at `0` unless needed. | `0.0` |
| `PID_INTEGRAL_LIMIT` | Anti-windup cap on I-term contribution. | `0.5` V |
| `PID_TOLERANCE_NM` | Tighten for higher accuracy; loosen if sensor noise is large. | `5.0` nm |

### Using PID from your own code

```python
from main import Config, PiezoLUT, UMD2Reader, MokuController, run_pid_control
import logging

cfg = Config()
logger = logging.getLogger("piezo_lut")
lut = PiezoLUT.from_csv("lut_output/lut_20250506_143022.csv")

umd2 = UMD2Reader(cfg, logger)
moku = MokuController(cfg, logger)
umd2.connect()
moku.connect()

result = run_pid_control(
    target_nm=1000.0,
    cfg=cfg,
    umd2=umd2,
    moku=moku,
    logger=logger,
    lut=lut,
    temperature_C=25.0,
)

print(f"Converged: {result.converged}")
print(f"Final position: {result.final_position_nm:.1f} nm")
print(f"Final voltage:  {result.final_voltage_V:.4f} V")
print(f"Iterations: {result.iterations}  Time: {result.elapsed_s:.2f} s")

moku.zero_output(cfg.moku_channel)
umd2.close()
moku.close()
```

---

## Error Handling

| Situation | Behavior |
|-----------|----------|
| Serial port not found (AUTO mode) | Prints available ports and exits |
| µMD2 serial disconnect | Reconnect up to 3 times (2 s apart); save data and exit on failure |
| Moku:Go disconnect | Reconnect up to 3 times; zero voltage, save data and exit on failure |
| Insufficient samples (< 50% of N_SAMPLES) | Logs a warning, records actual sample count, continues |
| `Ctrl+C` interrupt | Immediately zeros voltage, saves collected data, exits cleanly |

---

## Console Output Example

```
========================================
µMD2 LUT 自动采集系统
========================================
[设备] µMD2 已连接: /dev/ttyACM0  固件版本: 1.26  采样率: 1000Hz
[设备] Moku:Go 已连接: 192.168.73.1
[配置] 分辨率: 40nm/count  电压范围: 0.0~5.0V  步长: 0.1V
[配置] 温度点: [25.0]°C  每点采样: 100次

----------------------------------------
温度点 1/1: 25.0°C
----------------------------------------

── 升压扫描 ──
[  1/ 51] V= 0.00V  位移=    0.0 ±  5.5 nm  CI95=±1.1nm  n=100  ETA:00:25
[  2/ 51] V= 0.10V  位移=   40.6 ±  5.7 nm  CI95=±1.1nm  n=100  ETA:00:24
...
[ 51/ 51] V= 5.00V  位移= 2050.7 ±  4.6 nm  CI95=±0.9nm  n=100  ETA:00:00

[进度] 25.0°C 升压完成，最大位移=2050.7nm

── 降压扫描 ──
...

[保存] 中间结果已保存: lut_output/lut_partial_25C.csv

========================================
全部完成！
[保存] 完整LUT: lut_output/lut_20250506_143022.csv
[保存] 摘要:    lut_output/summary_20250506_143022.csv
========================================

[LUT示例] forward(25.0°C, 2.5V, 'up') = 1025.5 nm
[LUT示例] inverse(25.0°C, 1025.5nm, 'up') = 2.5000 V
```
