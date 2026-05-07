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

### PID auto-tuning (recommended for first use)

```bash
# Auto-tune PID gains, then drive to 1000 nm
uv run python main.py --pid 1000 --autotune

# Auto-tune + LUT feedforward (best accuracy)
uv run python main.py --pid 1000 --autotune --load lut_output/lut_20250506_143022.csv

# Simulate auto-tuning (no hardware)
uv run python main.py --pid 1000 --autotune --dry-run
```

`--autotune` runs a step-response identification test before PID positioning. It automatically computes `Kp` and `Ki` from the measured plant dynamics — no manual tuning required. The identified gains apply for the current session; copy them to `main.py` to make them permanent.

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

# Auto-tuning (--autotune)
AUTOTUNE_V_LOW      = 0.5          # Step test start voltage (V)
AUTOTUNE_V_HIGH     = 2.5          # Step test end voltage (V)
AUTOTUNE_COLLECT_S  = 3.0          # Step response collection duration (s)
AUTOTUNE_METHOD     = "IMC"        # Tuning method: 'IMC' (recommended) or 'ZN'
AUTOTUNE_LAMBDA     = 1.0          # IMC closed-loop time constant multiplier (larger = more conservative)
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

## PID Auto-Tuning

### Physical and mathematical background

#### Why Piezo actuators need tuning

A Piezo actuator is an electromechanical transducer that converts voltage to mechanical displacement through the inverse piezoelectric effect. From a control perspective, three physical phenomena make manual PID tuning difficult:

| Phenomenon | Physical cause | Control impact |
|------------|---------------|----------------|
| **Hysteresis** | Ferroelectric domain switching | Output depends on voltage history, not just present voltage |
| **Creep** | Slow domain relaxation after a voltage step | Displacement drifts for seconds to minutes after the voltage is set |
| **Capacitive dynamics** | Piezo is a lossy capacitor (driving source has finite output impedance) | Finite rise time; exponential approach to steady state |

The LUT acquisition addresses hysteresis by sweeping both directions. The PID controller — once properly tuned — compensates for creep and dynamic lag in real time. `--autotune` automates the identification of the dynamic parameters needed to set the PID gains correctly.

#### Plant model: First-Order Plus Dead Time (FOPDT)

The dominant dynamics of the Piezo + sensor + communication chain are well approximated by:

$$G(s) = \frac{K \, e^{-\theta s}}{\tau s + 1}$$

| Symbol | Unit | Physical meaning |
|--------|------|-----------------|
| K | nm/V | Static (DC) gain — how many nm per volt at steady state |
| τ | s | Time constant — speed of the exponential approach to steady state (mechanical + electrical) |
| θ | s | Dead time — lumped delay from serial latency (~1 ms), PID loop interval, and Piezo mechanical lag |

The corresponding step response (voltage jumps by ΔV at t = 0) is:

$$y(t) = \begin{cases} y_0 & t \leq \theta \\ y_0 + K \cdot \Delta V \left(1 - e^{-(t-\theta)/\tau}\right) & t > \theta \end{cases}$$

This is the equation fitted by `scipy.optimize.curve_fit` during the identification step.

#### Step-response identification

Given N timed samples {tᵢ, yᵢ} collected after the voltage step, the code minimises the nonlinear least-squares residual:

$$\min_{K,\,\tau,\,\theta} \sum_{i=1}^{N} \left[ y_i - y(t_i;\, K, \tau, \theta) \right]^2$$

The Levenberg-Marquardt algorithm (via `curve_fit`) converges reliably for the parameter ranges typical of Piezo + µMD2 systems (K: 10–5000 nm/V, τ: 1 ms–60 s, θ: 0–10 s).

#### IMC-based PI tuning (recommended)

Internal Model Control (IMC) designs the controller so that the closed-loop behaves like a first-order system with a freely chosen time constant λ:

$$T_{cl}(s) = \frac{e^{-\theta s}}{\lambda s + 1}$$

The corresponding IMC controller is:

$$Q(s) = \frac{T_{cl}(s)}{G(s)} = \frac{\tau s + 1}{K(\lambda s + 1)}$$

Converting to the equivalent standard feedback PI form:

$$C(s) = K_p \left(1 + \frac{1}{T_i s}\right), \quad \text{where}$$

$$\boxed{K_p = \frac{\tau}{K(\lambda + \theta)}}, \qquad \boxed{K_i = \frac{K_p}{\tau} = \frac{1}{K(\lambda + \theta)}}$$

**Design guideline for λ:** λ = τ (`AUTOTUNE_LAMBDA = 1.0`) is a good starting point. Increase λ to slow down the response and gain robustness against model mismatch (e.g. nonlinear hysteresis); decrease λ for faster convergence when the model is accurate.

**Stability guarantee:** The IMC design is inherently stable for any λ > 0 as long as the FOPDT model is a reasonable approximation of the plant. Unlike direct Ziegler-Nichols tuning, there is no risk of selecting gains above the stability boundary.

#### Ziegler-Nichols (process reaction curve)

The ZN method uses only two scalars extracted from the step response:

- **Reaction rate:** $R = K/\tau$ (slope of the tangent at the inflection point, nm V⁻¹ s⁻¹)
- **Dead time:** L = θ

Recommended PI settings (Ziegler & Nichols, 1942):

$$K_p = \frac{0.9}{R \cdot L} = \frac{0.9\,\tau}{K\,\theta}, \qquad T_i = \frac{L}{0.3} = 3.33\,\theta, \qquad K_i = \frac{K_p}{T_i} = \frac{0.27\,\tau}{K\,\theta^2}$$

ZN targets approximately 25 % overshoot and is more aggressive than IMC. It is suitable when speed matters more than smooth convergence, but it can oscillate when θ is large relative to τ.

#### Units and sign convention

The discrete-time PI update implemented in `PIDController.update()` is:

$$v[k] = v[k-1] + K_p \cdot e[k] + K_i \cdot \Delta t \cdot \sum_{j \leq k} e[j]$$

where e[k] = target_nm − measured_nm (positive when the actuator needs to extend further). Kp and Ki both have units V/nm and V/(nm·s) respectively, consistent with the continuous-time derivation above.

---

### Method overview

`--autotune` identifies the Piezo plant model from a measured step response, then computes `Kp` and `Ki` automatically. No manual tuning is needed.

```
Step: V_LOW → V_HIGH
         ↓
Collect displacement vs. time (AUTOTUNE_COLLECT_S seconds)
         ↓
Fit First-Order Plus Dead Time (FOPDT) model:
    G(s) = K · e^(−θs) / (τs + 1)
    K = static gain (nm/V)
    τ = time constant (s)
    θ = dead time (s)
         ↓
Compute Kp, Ki from tuning rules (IMC or Ziegler-Nichols)
         ↓
Apply gains and run PID positioning
```

### Tuning rules

**IMC (Internal Model Control) — recommended:**

$$K_p = \frac{\tau}{K(\lambda + \theta)}, \quad K_i = \frac{K_p}{\tau}$$

where λ = `AUTOTUNE_LAMBDA × τ` is the desired closed-loop time constant. Larger λ → slower but more robust response.

**Ziegler-Nichols (process reaction curve):**

$$K_p = \frac{0.9\,\tau}{K\,\theta}, \quad K_i = \frac{K_p}{3.33\,\theta}$$

ZN gives more aggressive gains and is suitable when fast convergence is prioritized over robustness.

### Console output example

```
========================================
PID 自动整定（阶跃响应法）
========================================
阶跃：0.50V → 2.50V  (ΔV=+2.00V)
采集：3.0s  方法：IMC

[1/4] 稳定至初始电压…
[2/4] 施加阶跃，采集 3.0s 响应…
[3/4] 拟合 FOPDT 模型…
[4/4] 计算 PID 增益…

────────────────────────────────────────
模型识别结果（FOPDT）：
  增益     K  = 409.4 nm/V
  时间常数 τ  = 80.2 ms
  纯滞后   θ  = 10.0 ms

整定结果（IMC）：
  Kp = 0.002171 V/nm
  Ki = 0.027078 V/(nm·s)
  Kd = 0.0  （保持关闭）

如需永久保存，请将以上值写入 main.py 顶部配置。
────────────────────────────────────────
[自动整定] 已应用 Kp=0.002171  Ki=0.027078
```

### When to use auto-tuning

| Situation | Recommendation |
|-----------|----------------|
| First time using a new Piezo | Always run `--autotune` to identify the plant |
| After changing temperature | Re-run `--autotune` — dynamics may shift |
| PID oscillates or converges slowly | Re-run with `AUTOTUNE_LAMBDA` adjusted |
| Plant is well-characterized | Skip `--autotune`; use manually configured gains |

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

## PID Simulation GUI

`simulate.py` is a standalone interactive GUI for exploring Piezo PID behaviour without hardware. It runs a discrete-time FOPDT simulation with a PI controller and lets you tune every parameter in real time.

### Launch

```bash
uv run python simulate.py
```

Requires tkinter (install `python-tk` for your Python version, e.g. `brew install python-tk@3.13` on macOS).

### Interface layout

```
┌─ Controls (left) ──────────────────────────────────────────────────────────┐
│  Plant (FOPDT)        K (nm/V)  τ (ms)  θ (ms)                            │
│  PID Gains            Kp  Ki  Kd   [IMC Auto-tune]                         │
│  Feedback Delay       Extra delay (ms)                                      │
│  Setpoint             Target displacement (nm)                              │
│  Disturbance          Type ▾   Amplitude (nm)   Freq (Hz)                  │
│  Sensor Noise         RMS (nm)                                              │
│  Simulation           Duration (s)   Step time (s)   V max (V)             │
│  [▶ Run Simulation]  [Reset]                                                │
└────────────────────────────────────────────────────────────────────────────┘
┌─ Plots (right) ────────────────────────────────────────────────────────────┐
│  ┌──────────────────┐  ┌──────────────────┐                                │
│  │ Displacement (nm)│  │ Positioning Error │                                │
│  └──────────────────┘  └──────────────────┘                                │
│  ┌──────────────────┐  ┌──────────────────┐                                │
│  │ Control Voltage  │  │ Disturbance (nm) │                                │
│  └──────────────────┘  └──────────────────┘                                │
│  [matplotlib toolbar: pan | zoom | save PNG/PDF/SVG]                       │
└────────────────────────────────────────────────────────────────────────────┘
```

### Parameters

| Section | Parameter | Default | Range |
|---------|-----------|---------|-------|
| Plant | K — static gain (nm/V) | 410 | 10–2000 |
| Plant | τ — time constant (ms) | 80 | 5–500 |
| Plant | θ — plant dead time (ms) | 10 | 0–200 |
| PID | Kp | 0.002 | 0–0.05 |
| PID | Ki | 0.027 | 0–2.00 |
| PID | Kd | 0 | 0–0.01 |
| Feedback | Extra sensor delay (ms) | 0 | 0–500 |
| Setpoint | Target displacement (nm) | 1000 | 100–5000 |
| Disturbance | Type | none | none / high-freq sine / low-freq sine / periodic square |
| Disturbance | Amplitude (nm) | 50 | 0–500 |
| Disturbance | Frequency (Hz) | 10 | 0.1–200 |
| Noise | Sensor RMS (nm) | 5 | 0–50 |
| Simulation | Duration (s) | 2.0 | 0.5–10 |

### Simulation model

The simulation engine uses a 1 ms plant integration step (Euler method) with a 50 ms PID update interval — matching the typical real-time loop cadence.

**Plant** (first-order plus dead time):

$$G(s) = \frac{K\,e^{-\theta s}}{\tau s + 1}$$

Dead time is implemented as a circular delay buffer of length $\lceil \theta / \Delta t_{\rm plant} \rceil$.

**Additional feedback delay**: a second circular buffer delays the sensor measurement before it reaches the PID controller, simulating cable latency, filter lag, or slow communication.

**Disturbance types** (applied at plant output, starting at `Step time`):

| Type | Signal |
|------|--------|
| high-freq sine | $d(t) = A \sin(2\pi f t)$ |
| low-freq sine | $d(t) = A \sin(2\pi (f/10)\, t)$ |
| periodic square | $d(t) = A \operatorname{sgn}[\sin(2\pi f t)]$ |

**Anti-windup**: the integrator accumulation is clamped so that the integral term alone cannot saturate the output beyond the voltage limits.

### IMC Auto-tune button

Computes IMC PI gains directly from the current slider values (K, τ, θ) with $\lambda = 2\theta$:

$$K_p = \frac{\tau}{K(\lambda + \theta)}, \quad K_i = \frac{K_p}{\tau}$$

The result is written back to the Kp and Ki sliders immediately, so you can press **Run Simulation** again to see the closed-loop response.

### Chart export

Use the matplotlib navigation toolbar at the bottom of the plot panel:

- **Floppy disk icon** → Save dialog (PNG, PDF, SVG, EPS)
- **Magnifier icon** → Zoom to region
- **Pan icon** → Pan / scroll

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
