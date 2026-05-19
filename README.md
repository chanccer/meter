# meter — Piezo Voltage-Displacement LUT Acquisition System

Automatically builds a voltage-displacement lookup table (LUT) for Piezo actuators, and provides **closed-loop positioning** via PID or ADRC (Active Disturbance Rejection Control), driving the Piezo to a target displacement with nanometer precision. Displacement data is collected via a **µMD2** USB serial sensor; drive voltage is output by a **Moku:Go** waveform generator. Supports multi-temperature characterization, hysteresis measurement, and bidirectional interpolation queries.

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
git clone https://github.com/chanccer/meter.git
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

### Closed-loop positioning

```bash
# Drive Piezo to 1000 nm (no feedforward — starts from V_START, pure PI control)
uv run python main.py --goto 1000

# Recommended: add LUT feedforward for fast, accurate convergence
uv run python main.py --goto 1000 --load lut_output/lut_20250506_143022.csv

# Specify temperature for LUT lookup (default 25 °C)
uv run python main.py --goto 1000 --load lut_xxx.csv --temp 30

# Simulate without hardware
uv run python main.py --goto 1000 --load lut_xxx.csv --dry-run
```

### ADRC closed-loop positioning

ADRC (Active Disturbance Rejection Control) uses an Extended State Observer (ESO) to estimate and cancel disturbances (including hysteresis and model mismatch) in real time. It automatically identifies the plant model before positioning.

```bash
# ADRC with Smith Predictor (default, recommended when θ_piezo is significant)
uv run python main.py --goto 1000 --controller adrc

# ADRC without Smith Predictor
uv run python main.py --goto 1000 --controller adrc --no-smith

# ADRC + LUT feedforward
uv run python main.py --goto 1000 --controller adrc --load lut_output/lut_xxx.csv

# Simulate ADRC without hardware
uv run python main.py --goto 1000 --controller adrc --dry-run
```

ADRC mode automatically runs `identify_model()` (step-response identification) before the control loop to determine plant parameters K, τ, and θ. If identification fails, it falls back to PID mode.

### PID auto-tuning (recommended for first use)

```bash
# Auto-tune PID gains, then drive to 1000 nm
uv run python main.py --goto 1000 --autotune

# Auto-tune + LUT feedforward (best accuracy)
uv run python main.py --goto 1000 --autotune --load lut_output/lut_20250506_143022.csv

# Simulate auto-tuning (no hardware)
uv run python main.py --goto 1000 --autotune --dry-run
```

`--autotune` runs a step-response identification test before PID positioning. It automatically computes `Kp` and `Ki` from the measured plant dynamics — no manual tuning required. The identified gains apply for the current session; copy them to `main.py` to make them permanent.

The controller outputs the current voltage, measured displacement, and positioning error on each iteration. When the error has stayed within `PID_TOLERANCE_NM` for `PID_CONVERGE_COUNT` consecutive iterations, the Piezo is locked at the target and the script holds until `Ctrl+C`. On exit, the voltage is zeroed automatically.

### Acquire LUT then position immediately (`--acquire`)

Run LUT acquisition and closed-loop positioning in a single command. The LUT path is passed automatically as feedforward — no `--load` needed.

```bash
# Acquire LUT, then position to 1000 nm with feedforward (PID)
uv run python main.py --acquire --goto 1000

# Acquire LUT, then ADRC-position to 1000 nm
uv run python main.py --acquire --goto 1000 --controller adrc

# Full pipeline (dry-run simulation, no hardware)
uv run python main.py --acquire --goto 1000 --dry-run
```

`--acquire` requires `--goto`. After acquisition completes the freshly saved LUT is loaded automatically as the feedforward starting point for the control loop.

### Trajectory tracking (`--trajectory`)

Drive the Piezo to continuously follow an arbitrary waveform. ADRC's built-in setpoint-derivative feedforward (`sp_dot = Δr/Δt`) automatically provides velocity feedforward — no explicit inverse-model code needed.

```bash
# Sine wave: ±500 nm around 1000 nm, 0.5 Hz, 3 cycles (ADRC recommended)
uv run python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 \
    --traj-freq 0.5 --traj-cycles 3 --controller adrc

# Triangle wave: ±800 nm, 0.2 Hz, 20 s
uv run python main.py --trajectory triangle --traj-amp 800 --traj-offset 1000 \
    --traj-freq 0.2 --traj-duration 20 --controller adrc

# With LUT feedforward for better initial position (reduces transient)
uv run python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 \
    --traj-freq 0.5 --traj-cycles 5 --controller adrc \
    --load lut_output/lut_xxx.csv

# Dry-run simulation (no hardware)
uv run python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 \
    --traj-freq 0.5 --traj-cycles 3 --controller adrc --dry-run
```

Supported waveforms: `sine`, `triangle`, `sawtooth`, `square`. Results are saved to `lut_output/trajectory_<timestamp>.csv` with columns `time_s`, `setpoint_nm`, `measured_nm`, `voltage_V`.

A bandwidth warning is printed when `freq_hz > 1/(2πτ) ≈ 2 Hz` — above this frequency the first-order plant attenuates the output amplitude and requires large voltage swings to compensate.

---

## Python Module Structure

The Python codebase is split into focused modules with a single-direction dependency graph:

```
meter/
├── main.py          — CLI entry point (~120 lines)
├── config.py        — Config dataclass + all constants
├── models.py        — Pure dataclasses (ModelParams, PIDResult, …)
├── utils.py         — Logging, statistics, progress display
├── hardware.py      — UMD2Reader, MokuController (+ DryRun variants)
├── data.py          — PiezoLUT, CSVWriter
├── acquisition.py   — run_sweep(), run_acquisition()
├── control/
│   ├── pid.py       — PIDController
│   ├── adrc.py      — ADRCController, SmithPredictor (ZOH-exact ESO)
│   ├── hysteresis.py — BoucWen, SimpleHysteresis
│   └── loop.py      — run_pid_control(), run_adrc_control(), run_control()
└── tune/
    ├── system_id.py — AutoTuner, identify_model(), measure_protocol_delay()
    └── imc.py       — imc_tune_from_model() (Rivera 1986 IMC formulas)
```

---

## Configuration

All parameters are defined in `config.py`. The `Config` dataclass holds hardware settings, PID/ADRC gains, and acquisition parameters.

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

# Model identification (runs automatically after each temperature sweep)
STEP_IDENT_ENABLED  = True         # Run step-response identification after each temperature
STEP_IDENT_V_LOW    = 0.5          # Identification step start voltage (V)
STEP_IDENT_V_HIGH   = 2.5          # Identification step end voltage (V)
STEP_IDENT_COLLECT_S = 3.0         # Collection duration per repetition (s)
STEP_IDENT_REPS     = 3            # Repetitions — results are averaged
PROTO_DELAY_REPS    = 10           # Repetitions for protocol delay measurement

# ADRC (--controller adrc)
ADRC_WC             = 20.0         # Controller bandwidth ω_c (rad/s) — auto-set by IMC if model available
ADRC_W0             = 100.0        # ESO bandwidth ω₀ (rad/s) — auto-set as 5·ω_c
ADRC_K              = 410.0        # Plant gain fallback nm/V (used if identify_model() fails)
ADRC_TAU_US         = 80000.0      # Plant time constant fallback (µs)
ADRC_SMITH          = True         # Enable Smith Predictor by default
```

**Multi-temperature example:**

```python
TEMPERATURES = [20, 25, 30, 35, 40]
```

**Temperature points and voltage range can be overridden at runtime without editing `config.py`:**

```bash
# Single temperature (default behavior)
uv run python main.py --temperatures 25

# Multi-temperature sweep
uv run python main.py --temperatures 20 25 30 35 40
```

**Voltage range and step can also be overridden:**

```bash
# Sweep only 0–3 V (e.g., piezo safe working range)
uv run python main.py --v-end 3.0

# Finer LUT resolution: 0.05 V steps instead of 0.1 V
uv run python main.py --v-step 0.05

# Custom range and step together
uv run python main.py --v-start 0.2 --v-end 4.5 --v-step 0.05

# Voltage limits also clamp the controller output during positioning
uv run python main.py --goto 1000 --v-start 0.2 --v-end 4.5
```

`V_STEP` is a user-chosen LUT grid density, not the Moku DAC hardware resolution. The Moku:Go Waveform Generator is 16-bit over ±5 V (≈ 0.15 mV precision), so any step ≥ 1 mV is well within hardware capability. `V_START` and `V_END` default to 0–5 V to match the Moku single-ended output range, but should be narrowed to the piezo's safe operating window.

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

> **Note — steady-state detection is time-based only.** The current implementation assumes `SETTLE_TIME = 0.5 s` is sufficient for the Piezo to reach steady state. This is a fixed wait with no active convergence check: the script does not monitor displacement variance or verify that the signal has stopped drifting before sampling begins. For most Piezos this is adequate — at τ ≈ 80 ms, five time constants (5τ ≈ 400 ms) elapse before the 0.5 s wait ends. However, Piezos with significant **creep** (slow ferroelectric domain relaxation, which can continue for seconds to minutes after voltage is applied) may produce readings that are still drifting within the sampling window. If the LUT shows unexpectedly high hysteresis or non-repeatability, consider increasing `SETTLE_TIME`.

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
| `model_YYYYMMDD_HHMMSS.csv` | FOPDT model parameters (K, τ, θ, dead-band, delay breakdown) |
| `summary_YYYYMMDD_HHMMSS.csv` | Per-temperature statistics summary |
| `lut_partial_25C.csv` | Intermediate results (updated after each temperature) |
| `lut_YYYYMMDD_HHMMSS.log` | Full log file (DEBUG level) |

The `model_*.csv` file shares the same timestamp as the corresponding `lut_*.csv`. When you click **Load LUT** in the MATLAB GUI, the companion model file is auto-detected and used to populate the Plant K / τ / θ / V_dead / noise fields.

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

### Model CSV columns (`model_YYYYMMDD_HHMMSS.csv`)

Saved automatically after each temperature point when `STEP_IDENT_ENABLED = True`.

| Column | Description |
|--------|-------------|
| `temperature_C` | Temperature (°C) |
| `K_nm_per_V` | Static gain (nm/V) |
| `tau_us` | Time constant (µs) |
| `theta_us` | Total dead time (µs) — θ_piezo + θ_protocol |
| `v_dead_V` | Dead-band voltage (V) — minimum voltage before Piezo moves |
| `r2_fit` | FOPDT fit quality R² |
| `noise_rms_nm` | Sensor noise RMS (nm, estimated from static LUT std_nm) |
| `theta_piezo_us` | Estimated Piezo-only mechanical delay (µs) |
| `theta_protocol_us` | Estimated protocol delay (µs) — Moku command + serial frame + USB |
| `timestamp` | Identification time (ISO 8601) |

---

## PiezoLUT Query Interface

After acquisition the script prints a short query demonstration. You can also import and use `PiezoLUT` directly:

```python
from data import PiezoLUT

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
| θ | s | Total dead time — θ_piezo (mechanical lag) + θ_protocol (Moku command + serial frame + USB polling) |

The script measures θ_protocol separately via `measure_protocol_delay()` (N repeated no-op Moku commands + frame arrival timing), then computes θ_piezo = θ_total − θ_protocol. Both are stored in the model CSV in microseconds (`theta_piezo_us`, `theta_protocol_us`). The **Load LUT** button reads these columns and populates **θ_piezo (µs)** and **θ_protocol (µs)** directly.

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

### Using PID or ADRC from your own code

```python
from config import Config
from data import PiezoLUT
from hardware import UMD2Reader, MokuController
from control.loop import run_control   # dispatches to PID or ADRC
import logging

cfg = Config()
logger = logging.getLogger("piezo_lut")
lut = PiezoLUT.from_csv("lut_output/lut_20250506_143022.csv")

umd2 = UMD2Reader(cfg, logger)
moku = MokuController(cfg, logger)
umd2.connect()
moku.connect()

# PID mode (default)
result = run_control(
    mode="pid",          # or "adrc"
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

## PID / ADRC Simulation GUI (MATLAB)

`simulate.m` is a standalone MATLAB interactive GUI for exploring Piezo closed-loop behaviour without hardware. It simulates a discrete-time FOPDT plant with two controller choices — **PID** (with filtered derivative) and **ADRC** (Active Disturbance Rejection Control) — plus a live performance-metrics panel and a scrollable log.

### Launch

Open MATLAB and run:

```matlab
simulate()
```

Requires MATLAB R2023b or later (uses `uifigure`, `uigridlayout`, `uitable`). Tested with MATLAB 2026a.

### File structure

```
simulate.m          — GUI entry point (calls +sim package functions)
+sim/
  defaultParams.m   — factory-default parameter struct
  runSim.m          — discrete-time FOPDT simulation loop (PID + ADRC)
  makeSetpoint.m    — setpoint waveform generator
  makeDisturbance.m — disturbance waveform generator
  computeMetrics.m  — step-response performance metrics
  saveConfig.m      — JSON config save
  loadConfig.m      — JSON config load (falls back to defaults)
test_simulate.m     — unit test suite (call sim.* package functions directly)
```

Run unit tests without opening the GUI:

```matlab
results = runtests('test_simulate');
table(results)
```

### Interface layout

```
┌─ Parameters (left, scrollable) ──────────────────┐
│  Plant (Piezo)                                    │
│    K  (nm/V)          [    350 ]                  │
│    τ  (µs)            [     20 ]                  │
│    θ_piezo (µs)       [    500 ]                  │
│    V dead (V)         [      0 ]                  │
│    Hysteresis (nm)    [      0 ]                  │
│    Noise RMS (nm)     [      5 ]                  │
│  Controller                                       │
│    Mode          [ PID ▼ / ADRC ]                 │
│    Kp  [ 0.002 ]  Ki  [ 0.027 ]  Kd  [ 0 ]       │
│    D filter N    [     20 ]                       │
│  ADRC                                             │
│    ω_c (rad/s)   [    500 ]                       │
│    ω₀  (rad/s)   [   2000 ]                       │
│    Smith Predictor [ Off ▼ ]                      │
│  Feedback Delay                                   │
│    θ_protocol (µs) [      0 ]                     │
│  Simulation                                       │
│    Controller DT (µs) [    1 ]                    │
│  Setpoint / Disturbance / Simulation …            │
└──────────────────────────────────────────────────┘
┌─ Plots + Metrics (right) ───────────────────────────────────────┐
│  ┌────────────────────┐  ┌────────────────────┐                 │
│  │  Displacement (nm) │  │  Positioning Error │                 │
│  └────────────────────┘  └────────────────────┘                 │
│  ┌────────────────────┐  ┌────────────────────┐                 │
│  │  Control Voltage   │  │  Disturbance (nm)  │                 │
│  └────────────────────┘  └────────────────────┘                 │
│  [▶ Run] [IMC/ADRC Auto-tune] [Auto-tune+Run] [Reset] [Load LUT]│
│  [Export…] [Save Config] [Dist on Error ☐]                      │
│  ┌── Step Response Metrics ────────────────────────────────┐    │
│  │  Overshoot: 0.0%   Rise: 120 ms   Settling: 250 ms      │    │
│  │  SS RMS: 0.8 nm    IAE: 12.3 nm·s   ITAE: 8.4 nm·s²    │    │
│  └─────────────────────────────────────────────────────────┘    │
│  ┌── Log ──────────────────────────────────────────────────┐    │
│  │  09:01:02  Ready — press ▶ Run Simulation               │    │
│  │  09:01:15  Running PID simulation  (2.0 s)…             │    │
│  │  09:01:15  Done  |  SS RMS: 0.8 nm  — Converged ✓      │    │
│  └─────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

### Parameters

All parameters are numeric input fields or drop-downs. Fields that belong to the inactive controller (PID vs. ADRC) are automatically greyed out.

| Section | Parameter | Default | Range |
|---------|-----------|---------|-------|
| Plant (Piezo) | K — static gain (nm/V) | 350 | 0–10 000 000 |
| Plant (Piezo) | τ — time constant (µs) | 20 | 0–1 000 000 000 |
| Plant (Piezo) | θ_piezo — mechanical dead time (µs) | 500 | 0–1 000 000 000 |
| Plant (Piezo) | V dead (V) — dead-band voltage | 0 | 0–5 |
| Plant (Piezo) | Hysteresis (nm) | 0 | 0–500 |
| Plant (Piezo) | Noise RMS (nm) | 5 | 0–50 |
| Controller | Mode | PID | PID / ADRC |
| Controller (PID) | Kp | 0.002 | 0–0.05 |
| Controller (PID) | Ki | 0.027 | 0–2.00 |
| Controller (PID) | Kd | 0 | 0–0.10 |
| Controller (PID) | D filter N | 20 | 0–200 |
| ADRC | ω_c (rad/s) — controller bandwidth | 500 | 0–1 000 000 000 |
| ADRC | ω₀ (rad/s) — ESO bandwidth | 2000 | 0–1 000 000 000 |
| ADRC | Smith Predictor — dead-time compensation | Off | Off / On |
| Feedback Delay | θ_protocol (µs) — sensor + protocol latency | 0 | 0–1 000 000 000 |
| Setpoint | Base DC (nm) | 0 | −1 000 000 000–1 000 000 000 |
| Simulation | Duration (s) | 2.0 | 0–1 000 000 |
| Simulation | V max (V) | 20 | 0–1 000 000 |
| Simulation | Controller DT (µs) | 1 | 0–1 000 000 000 |

### Setpoint generator

The **Setpoint** section uses a waveform table. Each row defines one signal added on top of the base DC offset:

| Column | Description |
|--------|-------------|
| En | Enable/disable this row |
| Type | `Step` / `Sine` / `Square` / `Sawtooth` / `Triangle` / `Random` / `Noise` |
| Amp (nm) | Signal amplitude |
| Period (s) | Waveform period (`Step` and `Noise` ignore this) |
| Start (s) | Time at which signal begins |
| Dur (s) | Duration (0 = until end of simulation) |

`Random` generates a piecewise-constant random signal that changes value every period. `Noise` adds white Gaussian noise at every timestep with standard deviation equal to Amp.

Multiple rows are summed to form the final setpoint trajectory. Use **+ Add SP** / **− Remove SP** to manage rows.

### Disturbance generator

The **Disturbance** section uses the same waveform table schema (without `Step` type), including `Noise`. Multiple rows are summed to produce a complex disturbance signal applied at the plant output.

| Type | Waveform |
|------|----------|
| Sine | $A\sin(2\pi f t')$ |
| Square | $A\,\operatorname{sgn}[\sin(2\pi f t')]$ |
| Sawtooth | $A(2\{ft'\}-1)$ |
| Triangle | $A(1-4\lvert\{ft'+0.25\}-0.5\rvert)$ |

where $t' = t - t_\text{start}$ and $f = 1/\text{period}$.

### Plot interactions

The four subplots support independent mouse-driven zoom and pan. All X axes are linked — any time-axis change applies to all four plots simultaneously.

| Gesture | Effect |
|---------|--------|
| Scroll wheel | Zoom X axis (time) — all 4 plots synchronized |
| Shift + Scroll | Zoom Y axis of the hovered plot only |
| Left-click drag | Pan — X shifts all plots; Y shifts hovered plot only |

Scroll wheel zoom is active **only when the cursor is inside a plot**; scrolling over the parameter panel has no effect. After each simulation run the view resets to show the full time range.

### Simulation model

The simulation engine uses a **1 µs plant integration step** (Euler method). The controller update interval is set by the **Controller DT (µs)** parameter (default 1 µs; increasing it reduces CPU cost for long simulations).

**Plant** (first-order plus dead time with hysteresis):

$$G(s) = \frac{K\,e^{-\theta s}}{\tau s + 1}$$

Dead time and feedback delay are each implemented as circular delay buffers. **Hysteresis** is implemented as either:
- **Simple directional offset** (default): −Hysteresis (nm) when voltage is decreasing, 0 when increasing.
- **Bouc-Wen model** (`bw_enable = true`): physics-based nonlinear hysteresis ODE  
  $\Delta z = A\Delta u - \beta|\Delta u|z - \gamma\Delta u|z|$, output $= -D \cdot z$. Accurately captures rate-dependent hysteresis loops. Parameters: A (pre-yield slope), β, γ (shape), D_nm (maximum hysteretic displacement).

#### PID controller (D filtered on measurement)

The derivative term uses a first-order low-pass filter on the **measurement** (not the error), avoiding the setpoint kick that results from a raw derivative:

$$C_d(s) = \frac{K_d N}{s + N}$$

Discrete update (applied to measured output `yMeas`):

$$d_\text{filt}[k] = \frac{d_\text{filt}[k-1]}{1+N\,T} + \frac{K_d\,N}{1+N\,T}\,\bigl(y[k-1] - y[k]\bigr)$$

**Anti-windup** clamps the integrator so the integral term alone cannot saturate the output. Setting N = 0 disables the D term entirely.

#### ADRC controller (1st-order)

Active Disturbance Rejection Control treats the combined effect of model mismatch, hysteresis, and external disturbances as a single "total disturbance" that the Extended State Observer (ESO) estimates and cancels in real time.

**Plant parameter needed:** $b_0 = K/\tau$ [nm/(V·s)]

**ESO update** — exact ZOH discretization via matrix exponential (stable for any ω₀ and DT combination):

$$\begin{bmatrix}z_1\\z_2\end{bmatrix}_{k+1} = A_d\begin{bmatrix}z_1\\z_2\end{bmatrix}_k + B_d\begin{bmatrix}u\\y\end{bmatrix}_k, \quad A_d,B_d = \text{expm}\!\left(\begin{bmatrix}A_c & B_c\\0&0\end{bmatrix}DT\right)$$

where $A_c = \begin{bmatrix}-2\omega_0 & 1\\-\omega_0^2 & 0\end{bmatrix}$, $B_c = \begin{bmatrix}b_0 & 2\omega_0\\0 & \omega_0^2\end{bmatrix}$ and $z_1 \approx y$, $z_2 \approx$ total disturbance.

**Control law with setpoint derivative feedforward** (cancels first-order tracking lag):

$$u = \frac{\omega_c (r - z_1) + \dot{r} - z_2}{b_0}, \quad \dot{r} = \frac{r[k] - r[k-1]}{DT}$$

The $\dot{r}$ term changes the closed-loop transfer function from $\omega_c/(s+\omega_c)$ to approximately $1$, eliminating the phase lag that would otherwise appear when tracking sinusoidal or ramp references.

**Smith Predictor** (enabled with Smith Predictor = On): runs a dead-time-free internal model in parallel and corrects the ESO measurement:

$$y_\text{eso} = y_\text{meas} + (y_\text{model} - y_\text{model,delayed})$$

This removes θ_plant from the ESO's effective dead time, allowing a higher ω_c without instability. **Toggling Smith Predictor automatically triggers IMC Auto-tune** so ω_c updates immediately (Off: ω_c ≈ 1921 rad/s for τ=20 µs, θ=500 µs; On: ω_c ≈ 48780 rad/s). The Run log also indicates `[Smith ON]` when Smith is active.

**Tuning guidelines:**
- Start with $\omega_c = 1/(\tau + \theta)$ and $\omega_0 = 5\,\omega_c$
- Increase $\omega_0$ for faster disturbance rejection; decrease if the ESO amplifies noise
- Increase $\omega_c$ for faster tracking; decrease if the control voltage saturates
- Enable Smith Predictor when θ_piezo is large relative to τ (θ/τ > 0.3)

### Performance metrics panel

After each simulation run, the metrics panel displays step-response quality measures computed over the full trajectory:

| Metric | Definition |
|--------|-----------|
| Overshoot (%) | $(y_\text{peak} - y_\text{ref}) / \|y_\text{step}\| \times 100$ |
| Rise time (µs) | Time from 10% to 90% of the step amplitude |
| Settling time (µs) | Last time the output leaves the ±2% band |
| SS RMS error (nm) | RMS of tracking error over final 10% of simulation |
| IAE (nm·s) | $\int_0^T \|e(t)\|\,dt$ — cumulative absolute error |
| ITAE (nm·s²) | $\int_0^T t\,\|e(t)\|\,dt$ — weights late errors more heavily |

Lower IAE/ITAE values indicate better overall tracking. ITAE penalises slow convergence more strongly than IAE.

### Scrollable log

All simulation events — run start, auto-tune results, load LUT messages, export paths, and errors — are appended to a timestamped scrollable log at the bottom of the right panel. The log retains the full session history, so you can review a sequence of parameter sweeps without losing earlier entries.

### Buttons

| Button | Action |
|--------|--------|
| ▶ Run Simulation | Run simulation with current parameters; compute and display metrics |
| IMC Auto-tune | **PID mode:** compute Kp, Ki from IMC rules (λ = 2θ). **ADRC mode:** compute ω_c = 1/(τ+θ_eff), ω₀ = 5ω_c; if Smith Predictor is On, θ_plant is excluded from θ_eff |
| Auto-tune + Run | Auto-tune then immediately run simulation |
| Reset | Restore all parameters to factory defaults |
| Load LUT… | Load a `lut_*.csv`; auto-detects `model_*.csv` → fills K / τ / θ_piezo / θ_protocol / V_dead / noise; auto-detects `summary_*.csv` → fills Hysteresis |
| Export… | Save figure as PNG / PDF / SVG / EPS |
| Save Config | Manually save all current parameters to `simulate_config.json` |
| Dist on Error ☐ | Overlay the disturbance signal on the Positioning Error plot for visual correlation |

### Config file persistence

All parameters are automatically persisted to `simulate_config.json` in the same directory as `simulate.m`. The file is written every time the GUI closes (via the window X button) and when **Save Config** is clicked. On next launch, `simulate()` loads the JSON and restores all parameters — no manual re-entry required.

The file is human-readable JSON:

```json
{
  "K": 350,
  "tau_us": 20,
  "theta_us": 500,
  "v_dead": 0,
  "hysteresis_nm": 0,
  "noise": 0,
  "ctrl_mode": "ADRC",
  "kp": 0.00066,
  "ki": 0.04482,
  "kd": 0.0,
  "d_filter_n": 9,
  "adrc_wc": 500,
  "adrc_w0": 2000,
  "smith_adrc": false,
  "delay_us": 0,
  "dt_pid_us": 1,
  "sp_dc": 1500,
  "v_max": 20,
  "t_total": 2.0,
  "setpoints": [
    {"en": true, "type": "Step", "amp": 1000, "period": 1.0, "t0": 0.1, "dur": 0.0}
  ],
  "signals": []
}
```

> **Backward compatibility:** Config files written by older versions that contain `tau_ms` (milliseconds) are automatically converted to `tau_us` (×1000) on load. Same applies to `theta_ms` and `dt_pid_ms`.

To reset to factory defaults: click **Reset** then **Save Config**, or simply delete `simulate_config.json`.

### Delay decomposition and Load LUT

When you load a `lut_*.csv` and a matching `model_*.csv` is present, the GUI automatically assigns:
- **θ_piezo (µs)** ← `theta_piezo_ms × 1000` — mechanical-only Piezo delay
- **θ_protocol (µs)** ← `theta_protocol_ms × 1000` — Moku command + serial frame + USB latency

If a companion `summary_*.csv` is found, the GUI also reads `hysteresis_max_nm` (average across temperatures) and populates the **Hysteresis (nm)** field.

If the model file lacks the decomposed columns (older format), `theta_ms × 1000` (converted to µs) is placed into θ_piezo as a conservative fallback.

### Auto-tune formulas

Implemented in `+sim/imcTune.m` (Rivera et al. 1986).

The IMC formula requires the **total effective dead time** — the sum of every delay in the closed loop:

$$\theta_\text{eff} = \underbrace{\theta_\text{plant}}_{\text{p.theta\_us}} + \underbrace{\theta_\text{sensor}}_{\text{p.delay\_us}} + \underbrace{DT/2}_{\text{p.dt\_pid\_us}/2}$$

The ZOH term $DT/2$ accounts for the fact that a discrete controller that updates every $DT$ seconds introduces the equivalent of a half-step dead time. Larger $DT$ → larger $\theta_\text{eff}$ → more conservative (lower) gains.

When **Smith Predictor is On**, the ADRC effective dead time excludes θ_plant (which is predicted away):

$$\theta_\text{eff,ADRC} = \theta_\text{sensor} + DT/2 \quad (\text{Smith On})$$

**PID — full IMC-PID including derivative (λ = 2θ_eff):**

$$K_p = \frac{\tau + \theta_\text{eff}/2}{K(\lambda + \theta_\text{eff}/2)}, \quad K_i = \frac{K_p}{\tau + \theta_\text{eff}/2}, \quad K_d = K_p \cdot \frac{\tau\theta_\text{plant}}{2\tau+\theta_\text{plant}}, \quad N = \left\lfloor\frac{2\tau+\theta_\text{plant}}{\theta_\text{plant}}\right\rceil$$

When θ_plant = 0, K_d = 0 automatically. Adding sensor delay or slowing the controller always reduces the tuned gains.

**ADRC:**

$$\omega_c = \frac{1}{\tau + \theta}, \quad \omega_0 = 5\,\omega_c$$

All four PID fields (Kp, Ki, Kd, N) are written simultaneously. Results appear immediately in the left panel and in the scrollable log.

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
