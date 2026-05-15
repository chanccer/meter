# meter — Piezo 电压-位移 LUT 自动采集系统

自动建立 Piezo 执行器的电压-位移查找表（LUT），并提供 **PID 和 ADRC（自抗扰控制）闭环定位模式**，以纳米级精度驱动 Piezo 到达指定位移。通过 **µMD2**（USB 串口位移传感器）采集位移数据，通过 **Moku:Go** 输出 DC 驱动电压，支持多温度点、迟滞测量和双向插值查询。

---

## 硬件要求

| 设备 | 说明 |
|------|------|
| µMD2 | 基于 Teensy 4.0，USB 串口，1000 samples/s，PMI=40nm/count 或 LI=79nm/count |
| Moku:Go | 网络连接（默认 IP `192.168.73.1`），驱动 Piezo 的 DC 电压输出 |

---

## 安装

需要 Python 3.14+ 和 [uv](https://docs.astral.sh/uv/)。支持 **Windows、macOS、Linux**。

```bash
git clone https://github.com/chanccer/meter.git
cd meter
uv sync
```

依赖项（`pyproject.toml`）：`moku`, `numpy`, `pandas`, `pyserial`, `scipy`

### Windows 注意事项

| 事项 | 说明 |
|------|------|
| 串口名称 | 使用 `COM` 格式（如 `COM3`、`COM7`），`AUTO` 自动检测同样有效 |
| 控制台编码 | 脚本启动时自动将 stdout 切换为 UTF-8，推荐使用 **Windows Terminal** 或 **PowerShell 7+**；旧版 `cmd.exe` 部分字符可能仍显示异常 |
| 运行方式 | `uv run python main.py`，与 macOS/Linux 完全一致 |
| Moku SDK | 支持 Windows，无需额外配置 |

若在 `cmd.exe` 中仍出现乱码，可手动强制 UTF-8 模式：

```cmd
set PYTHONUTF8=1
uv run python main.py --dry-run
```

---

## 快速开始

### 模拟采集（无需硬件）

```bash
uv run python main.py --dry-run
```

用随机数模拟 µMD2 和 Moku:Go，完整走完采集流程，输出文件保存到 `./lut_output/`。适合测试脚本逻辑、验证输出格式。

### 正式采集

```bash
uv run python main.py
```

连接硬件，按配置参数执行升压/降压扫描，完成后保存 LUT CSV 和统计摘要。

### 加载已有 LUT 进入查询模式

```bash
uv run python main.py --load lut_output/lut_20250506_143022.csv
```

跳过采集，直接加载 CSV 文件，演示正向/反向插值查询。

### PID 闭环定位

```bash
# 定位到 1000 nm（无前馈，从 V_START 出发，纯 PI 控制）
uv run python main.py --pid 1000

# 推荐：搭配 LUT 前馈，收敛更快、精度更高
uv run python main.py --pid 1000 --load lut_output/lut_20250506_143022.csv

# 指定温度（用于 LUT 前馈查询，默认 25°C）
uv run python main.py --pid 1000 --load lut_xxx.csv --pid-temp 30

# 模拟模式（无需硬件）
uv run python main.py --pid 1000 --load lut_xxx.csv --dry-run
```

### ADRC 闭环定位

ADRC（自抗扰控制）通过扩张状态观测器（ESO）实时估计并抵消包括迟滞和模型失配在内的总扰动，定位前自动执行植物模型辨识。

```bash
# ADRC + Smith Predictor（默认，θ_piezo 较大时推荐）
uv run python main.py --pid 1000 --controller adrc

# ADRC 不含 Smith Predictor
uv run python main.py --pid 1000 --controller adrc --no-smith

# ADRC + LUT 前馈
uv run python main.py --pid 1000 --controller adrc --load lut_output/lut_xxx.csv

# 模拟 ADRC（无需硬件）
uv run python main.py --pid 1000 --controller adrc --dry-run
```

ADRC 模式在控制循环前自动执行 `identify_model()`（阶跃响应辨识），获取 K、τ、θ 植物参数。辨识失败时自动回退到 PID 模式。

### PID 自动整定（首次使用推荐）

```bash
# 自动整定后定位到 1000 nm
uv run python main.py --pid 1000 --autotune

# 自动整定 + LUT 前馈（最高精度）
uv run python main.py --pid 1000 --autotune --load lut_output/lut_20250506_143022.csv

# 模拟自动整定（无需硬件）
uv run python main.py --pid 1000 --autotune --dry-run
```

`--autotune` 在 PID 定位前先执行阶跃响应辨识测试，自动计算 `Kp` 和 `Ki`，无需手动调参。整定增益仅对本次会话有效；如需永久保存，将打印的数值写入 `main.py` 顶部配置即可。

控制器每次迭代实时打印当前电压、位移和误差。当误差连续 `PID_CONVERGE_COUNT` 次满足 `PID_TOLERANCE_NM` 时宣告收敛，程序保持当前电压直到 `Ctrl+C`。退出时电压自动归零。

### 先采集 LUT 再立即定位（`--acquire`）

单条命令完成 LUT 采集与闭环定位全流程。LUT 路径自动传入，无需手动指定 `--load`。

```bash
# 采集 LUT，然后 PID 定位到 1000 nm（前馈自动启用）
uv run python main.py --acquire --pid 1000

# 采集 LUT，然后 ADRC 定位到 1000 nm
uv run python main.py --acquire --pid 1000 --controller adrc

# 完整流程模拟（无需硬件）
uv run python main.py --acquire --pid 1000 --dry-run
```

`--acquire` 需要同时指定 `--pid`。采集完成后，新保存的 LUT 自动作为前馈初始电压加载，无需手动 `--load`。

### 轨迹跟踪（`--trajectory`）

让 Piezo 持续跟踪任意波形。ADRC 控制律内置设定值导数前馈（`sp_dot = Δr/Δt`），自动提供速度前馈，无需额外编写逆模型代码。

```bash
# 正弦波：以 1000nm 为中心 ±500nm，0.5Hz，3 个周期（推荐 ADRC）
uv run python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 \
    --traj-freq 0.5 --traj-cycles 3 --controller adrc

# 三角波：±800nm，0.2Hz，20 秒
uv run python main.py --trajectory triangle --traj-amp 800 --traj-offset 1000 \
    --traj-freq 0.2 --traj-duration 20 --controller adrc

# 搭配 LUT 前馈（改善初始暂态）
uv run python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 \
    --traj-freq 0.5 --traj-cycles 5 --controller adrc \
    --load lut_output/lut_xxx.csv

# 模拟运行（无需硬件）
uv run python main.py --trajectory sine --traj-amp 500 --traj-offset 1000 \
    --traj-freq 0.5 --traj-cycles 3 --controller adrc --dry-run
```

支持波形：`sine`、`triangle`、`sawtooth`、`square`。结果保存至 `lut_output/trajectory_<时间戳>.csv`，列为 `time_s`、`setpoint_nm`、`measured_nm`、`voltage_V`。

当 `freq_hz > 1/(2πτ) ≈ 2 Hz` 时会打印带宽警告——超出此频率后一阶系统开始衰减输出幅度，补偿所需电压幅度迅速增大。

---

## Python 模块结构

Python 代码按职责拆分为独立模块，依赖关系单向：

```
meter/
├── main.py          — CLI 入口（约 120 行）
├── config.py        — Config dataclass + 所有常量
├── models.py        — 纯数据类（ModelParams、PIDResult 等）
├── utils.py         — 日志、统计、进度显示
├── hardware.py      — UMD2Reader、MokuController（含 DryRun 变体）
├── data.py          — PiezoLUT、CSVWriter
├── acquisition.py   — run_sweep()、run_acquisition()
├── control/
│   ├── pid.py       — PIDController
│   ├── adrc.py      — ADRCController、SmithPredictor（ZOH 精确 ESO）
│   ├── hysteresis.py — BoucWen、SimpleHysteresis
│   └── loop.py      — run_pid_control()、run_adrc_control()、run_control()
└── tune/
    ├── system_id.py — AutoTuner、identify_model()、measure_protocol_delay()
    └── imc.py       — imc_tune_from_model()（Rivera 1986 IMC 公式）
```

---

## 配置参数

所有参数集中在 `config.py` 中，通过 `Config` dataclass 管理。

```python
UMD2_PORT           = "AUTO"       # 自动检测，或指定 'COM7' / '/dev/ttyUSB0'
UMD2_BAUD           = 9600
UMD2_RESOLUTION     = "PMI"        # 'PMI'=40nm/count, 'LI'=79nm/count

MOKU_IP             = "192.168.73.1"
MOKU_CHANNEL        = 1

V_START             = 0.0          # 起始电压 V
V_END               = 5.0          # 终止电压 V
V_STEP              = 0.1          # 步长 V
SETTLE_TIME         = 0.5          # 每步稳定等待 s

TEMPERATURES        = [25.0]       # 温度列表 °C；多个温度点会逐一暂停提示
TEMP_STABILIZE_TIME = 300          # 换温度后等待稳定 s

N_SAMPLES           = 100          # 每个电压点采集帧数
OUTLIER_SIGMA       = 3.0          # 3-sigma 异常值剔除阈值

OUTPUT_DIR          = "./lut_output"

# PID 闭环控制参数
PID_KP              = 0.001        # 比例增益 V/nm
PID_KI              = 0.0002       # 积分增益 V/(nm·s)
PID_KD              = 0.0          # 微分增益 V·s/nm（默认关闭）
PID_TOLERANCE_NM    = 5.0          # 收敛容差 nm
PID_CONVERGE_COUNT  = 5            # 连续满足容差的次数才判定收敛
PID_TIMEOUT_S       = 30.0         # 最长等待时间 s
PID_SAMPLE_AVG      = 20           # 每次 PID 迭代平均采样帧数
PID_LOOP_INTERVAL   = 0.05         # 目标循环间隔 s
PID_INTEGRAL_LIMIT  = 0.5          # 积分项最大贡献 V（抗积分饱和）

# 自动整定参数（--autotune）
AUTOTUNE_V_LOW      = 0.5          # 阶跃测试起始电压 V
AUTOTUNE_V_HIGH     = 2.5          # 阶跃测试终止电压 V
AUTOTUNE_COLLECT_S  = 3.0          # 阶跃响应采集时长 s
AUTOTUNE_METHOD     = "IMC"        # 整定方法：'IMC'（推荐）或 'ZN'
AUTOTUNE_LAMBDA     = 1.0          # IMC 闭环时间常数倍数（越大越保守）

# 模型辨识（每温度点完成后自动执行阶跃响应辨识）
STEP_IDENT_ENABLED  = True         # 是否执行阶跃响应辨识
STEP_IDENT_V_LOW    = 0.5          # 辨识阶跃起始电压 V
STEP_IDENT_V_HIGH   = 2.5          # 辨识阶跃终止电压 V
STEP_IDENT_COLLECT_S = 3.0         # 每次阶跃响应采集时长 s
STEP_IDENT_REPS     = 3            # 重复辨识次数（结果取均值）
PROTO_DELAY_REPS    = 10           # 协议延迟测量重复次数

# ADRC（--controller adrc）
ADRC_WC             = 20.0         # 控制器带宽 ω_c rad/s（有模型辨识时由 IMC 自动设定）
ADRC_W0             = 100.0        # ESO 带宽 ω₀ rad/s（自动设为 5·ω_c）
ADRC_K              = 410.0        # 植物增益备用值 nm/V（辨识失败时使用）
ADRC_TAU_MS         = 80.0         # 植物时间常数备用值 ms
ADRC_SMITH          = True         # 默认启用 Smith Predictor
```

**多温度扫描示例：**

```python
TEMPERATURES = [20, 25, 30, 35, 40]
```

每个温度点开始前会暂停并提示操作者调温，然后倒计时等待 `TEMP_STABILIZE_TIME` 秒稳定。仅单温度时（默认）跳过提示，直接测量。

**温度点和电压范围均可在运行时通过命令行覆盖，无需修改 `config.py`：**

```bash
# 单温度（默认行为）
uv run python main.py --temperatures 25

# 多温度点扫描
uv run python main.py --temperatures 20 25 30 35 40
```

**电压范围和步长同样可覆盖：**

```bash
# 只扫描 0~3V（如压电安全工作范围）
uv run python main.py --v-end 3.0

# 更细的 LUT 网格：步长 0.05V
uv run python main.py --v-step 0.05

# 同时指定范围和步长
uv run python main.py --v-start 0.2 --v-end 4.5 --v-step 0.05

# 电压限制同样约束 PID/ADRC 定位时的控制器输出
uv run python main.py --pid 1000 --v-start 0.2 --v-end 4.5
```

`V_STEP` 是用户选择的 LUT 网格密度，与 Moku 的 DAC 硬件精度无关。Moku:Go 波形发生器为 16-bit，在 ±5V 范围内精度约 0.15 mV，远高于典型步长设定。`V_START`/`V_END` 默认 0~5V 对应 Moku 单端输出范围，实际使用时应根据压电执行器的安全工作范围缩小。

---

## 采集流程

每个温度点执行：

1. **升压扫描** `V_START → V_END`，步长 `V_STEP`
2. **降压扫描** `V_END → V_START`，步长 `V_STEP`

每步操作：

```
set_voltage(V) → sleep(SETTLE_TIME) → 清空积压帧 → 采集 N_SAMPLES 帧
→ 3-sigma 剔除异常值 → 计算 mean / std / sem / CI₉₅ → 记录
```

每完成一个温度点立即保存中间 CSV（防数据丢失），全部完成后保存完整 LUT 和统计摘要。

---

## 测量方法与统计原理

### 采样与平均

每个电压步进点采集 **`N_SAMPLES` 帧原始位移数据**（默认 100 帧）。µMD2 的输出频率为 **1000 samples/s**，因此 100 帧对应约 0.1 秒的稳态信号窗口。在每次采样开始前，脚本先等待 `SETTLE_TIME`（默认 0.5 s）让 Piezo 达到机械平衡，然后清空串口缓冲队列，确保统计仅使用稳态数据，不包含电压切换瞬间的过渡帧。

> **注意——稳态判断为纯时间等待。** 当前实现假设 `SETTLE_TIME = 0.5 s` 足以使 Piezo 达到稳态，不主动检测位移方差是否收敛、信号是否停止漂移。对大多数压电器件而言这已足够——时间常数 τ ≈ 80 ms，5τ ≈ 400 ms，0.5 s 等待结束时动态响应基本完成。但若压电器件存在明显**蠕变**（铁电畴缓慢弛豫，施压后位移可持续漂移数秒乃至数分钟），采样窗口内信号可能仍未稳定，导致 LUT 出现异常高的迟滞或重复性差。若遇此情况，建议适当增大 `SETTLE_TIME`。

### 离群值剔除——3-σ 滤波

由于电磁干扰或串口帧错误，原始样本中偶尔会出现野点。脚本采用 **3-sigma 滤波**自动剔除：

```
μ  = 所有 n 帧的均值
σ  = 样本标准差（ddof = 1）

保留满足 |xᵢ − μ| ≤ 3σ 的样本
超出阈值的样本视为离群值，记录于 outliers_removed
```

正常实验室环境下，被剔除的帧通常不超过 1%。可通过调整 `OUTLIER_SIGMA`（如改为 2.5）来适应噪声更大的环境，或在极低噪声场景下适当放宽。

### 期望值估计

剔除离群值后，以**剩余样本的算术均值**作为该电压点真实位移的最优线性无偏估计量（BLUE）：

| 统计量 | 公式 | 物理意义 |
|--------|------|---------|
| `mean_nm` | $\bar{x} = \frac{1}{n}\sum x_i$ | 真实位移的点估计 |
| `std_nm` | $s = \sqrt{\frac{\sum(x_i-\bar{x})^2}{n-1}}$ | 单次测量的分散程度（传感器噪声） |
| `sem_nm` | $\text{SEM} = s / \sqrt{n}$ | 均值本身的不确定度 |
| `ci_95_nm` | $1.96 \times \text{SEM}$ | 95% 置信区间半宽（大样本近似） |

以 µMD2 噪声约 **5 nm RMS**、采样 **n = 100** 帧为例，均值不确定度为：

$$\text{SEM} \approx \frac{5\,\text{nm}}{\sqrt{100}} = 0.5\,\text{nm}$$

将 `N_SAMPLES` 增大至 500 可将 SEM 降至约 0.22 nm，代价是每个电压点耗时增加。

### 分辨率与单位换算

µMD2 固件输出原始**位移计数**（counts），物理刻度因子取决于所选传感器模式：

| 模式 | 刻度 | 典型量程（0–5 V）|
|------|------|-----------------|
| `PMI` | 40 nm/count | 约 0–4 µm |
| `LI`  | 79 nm/count | 约 0–8 µm |

换算公式 `nm = count × nm_per_count` 在统计计算之前逐帧应用。

### 迟滞特性表征

Piezo 执行器存在**机械迟滞**：在同一电压下，从低压方向接近（升压）与从高压方向接近（降压）所达到的位移不同。脚本在两个方向均进行扫描，分别以 `direction = "up"` / `"down"` 存储。摘要 CSV 中的 `hysteresis_max_nm` 记录两条曲线在相同电压点处**差值的最大绝对值**，定量描述迟滞幅度。

---

## 输出文件

所有文件保存在 `OUTPUT_DIR`（默认 `./lut_output/`）：

| 文件 | 说明 |
|------|------|
| `lut_YYYYMMDD_HHMMSS.csv` | 完整 LUT 数据 |
| `model_YYYYMMDD_HHMMSS.csv` | FOPDT 模型参数（K、τ、θ、死区电压、延迟分解） |
| `summary_YYYYMMDD_HHMMSS.csv` | 每温度点统计摘要 |
| `lut_partial_25C.csv` | 单温度中间结果（每温度完成后更新） |
| `lut_YYYYMMDD_HHMMSS.log` | 完整日志（DEBUG 级别） |

`model_*.csv` 与对应 `lut_*.csv` 的时间戳相同。在 MATLAB GUI 中点击 **Load LUT** 时，会自动查找同名模型文件，并将 K / τ / θ / V_dead / 噪声字段一并填入。

### 主 LUT CSV 列

| 列 | 说明 |
|----|------|
| `temperature_C` | 温度（°C） |
| `voltage_V` | 电压（V） |
| `direction` | `up`（升压）或 `down`（降压） |
| `mean_nm` | 位移均值（nm） |
| `std_nm` | 标准差（nm） |
| `sem_nm` | 标准误差（nm） |
| `ci_95_nm` | 95% 置信区间半宽（nm） |
| `n_samples` | 有效样本数（剔除异常后） |
| `outliers_removed` | 被剔除的异常值数量 |
| `timestamp` | 采集时间（ISO 8601） |

### 摘要 CSV 列

| 列 | 说明 |
|----|------|
| `temperature_C` | 温度（°C） |
| `max_displacement_nm` | 最大位移（nm） |
| `hysteresis_max_nm` | 最大迟滞（升/降压曲线最大差值，nm） |
| `linearity_r2` | 升压曲线线性度 R² |
| `sensitivity_nm_per_V` | 灵敏度（nm/V，升压曲线斜率） |

### 模型 CSV 列（`model_YYYYMMDD_HHMMSS.csv`）

当 `STEP_IDENT_ENABLED = True` 时，每温度点完成后自动保存。

| 列 | 说明 |
|----|------|
| `temperature_C` | 温度（°C） |
| `K_nm_per_V` | 静态增益（nm/V） |
| `tau_ms` | 时间常数（ms） |
| `theta_ms` | 总纯滞后（ms）= θ_piezo + θ_protocol |
| `v_dead_V` | 死区电压（V）——低于此电压 Piezo 不动 |
| `r2_fit` | FOPDT 拟合优度 R² |
| `noise_rms_nm` | 传感器噪声 RMS（nm，从静态 LUT std_nm 估算） |
| `theta_piezo_ms` | Piezo 机械延迟（ms）= θ_total − θ_protocol |
| `theta_protocol_ms` | 通信协议延迟（ms）= Moku 命令 + 串口帧 + USB |
| `timestamp` | 辨识时间（ISO 8601） |

---

## PiezoLUT 查询接口

采集完成后，脚本末尾自动演示查询。也可以在自己的代码中直接使用：

```python
from data import PiezoLUT

# 加载 LUT
lut = PiezoLUT.from_csv("lut_output/lut_20250506_143022.csv")

# 正向查询：(温度, 电压) → 位移 nm（双线性插值）
displacement_nm = lut.forward(25.0, 3.0, direction="up")

# 反向查询：(温度, 目标位移) → 电压 V（Brent 二分法）
voltage_V = lut.inverse(25.0, 1000.0, direction="up")

# 查询 LUT 中的温度点列表
temps = lut.temperatures()           # e.g. [20.0, 25.0, 30.0]

# 查询电压范围
v_min, v_max = lut.voltage_range(direction="up")
```

`direction` 参数接受 `"up"`（升压）或 `"down"`（降压），用于区分迟滞曲线。

---

## PID 自动整定

### 物理与数学背景

#### 为什么 Piezo 需要整定

Piezo 执行器通过逆压电效应将电压转换为机械位移。从控制角度看，以下三种物理现象使得手动调参困难：

| 现象 | 物理根源 | 对控制的影响 |
|------|---------|------------|
| **迟滞** | 铁电畴翻转 | 输出不仅取决于当前电压，还取决于历史电压轨迹 |
| **蠕变** | 施加电压后铁电畴缓慢弛豫 | 电压稳定后位移仍会持续漂移数秒到数分钟 |
| **容性动态** | Piezo 本质上是有损电容，驱动源输出阻抗有限 | 位移以指数形式趋近稳态，存在有限上升时间 |

LUT 采集通过双向扫描处理迟滞问题。PID 控制器在正确整定后可实时补偿蠕变与动态滞后。`--autotune` 自动辨识动态参数，省去手动调参过程。

#### 被控对象模型：一阶加纯滞后（FOPDT）

Piezo + 传感器 + 串口通信链路的主导动态可由以下传递函数近似描述：

$$G(s) = \frac{K \, e^{-\theta s}}{\tau s + 1}$$

| 符号 | 单位 | 物理含义 |
|------|------|---------|
| K | nm/V | 静态增益——稳态下每伏特对应的位移量 |
| τ | s | 时间常数——位移指数趋近稳态的速度（机械+电气综合效应） |
| θ | s | 纯滞后——串口延迟（~1ms）、PID 循环间隔及 Piezo 机械延迟的综合等效值 |

施加电压阶跃 ΔV 后（t=0 时刻），对应的阶跃响应为：

$$y(t) = \begin{cases} y_0 & t \leq \theta \\ y_0 + K \cdot \Delta V \left(1 - e^{-(t-\theta)/\tau}\right) & t > \theta \end{cases}$$

这正是 `scipy.optimize.curve_fit` 在辨识步骤中拟合的方程。

#### 阶跃响应辨识

采集电压阶跃后的 N 个带时间戳样本 {tᵢ, yᵢ}，通过最小化非线性最小二乘残差来估计参数：

$$\min_{K,\,\tau,\,\theta} \sum_{i=1}^{N} \left[ y_i - y(t_i;\, K, \tau, \theta) \right]^2$$

代码使用 Levenberg-Marquardt 算法（`curve_fit` 内置）求解。对于 Piezo + µMD2 典型参数范围（K: 10–5000 nm/V，τ: 1ms–60s，θ: 0–10s），该算法收敛可靠。

#### IMC 整定规则（推荐）

内模控制（IMC）将控制器设计为使闭环系统的行为等效于一个时间常数为 λ 的一阶系统：

$$T_{cl}(s) = \frac{e^{-\theta s}}{\lambda s + 1}$$

对应的 IMC 控制器为：

$$Q(s) = \frac{T_{cl}(s)}{G(s)} = \frac{\tau s + 1}{K(\lambda s + 1)}$$

转换为等效标准反馈 PI 形式：

$$C(s) = K_p \left(1 + \frac{1}{T_i s}\right), \quad \text{其中}$$

$$\boxed{K_p = \frac{\tau}{K(\lambda + \theta)}}, \qquad \boxed{K_i = \frac{K_p}{\tau} = \frac{1}{K(\lambda + \theta)}}$$

**λ 的选取建议：** λ = τ（即 `AUTOTUNE_LAMBDA = 1.0`）是良好的起点。增大 λ 可降低响应速度，换取对模型失配（如非线性迟滞）更好的鲁棒性；减小 λ 可加快收敛，但对模型精度要求更高。

**稳定性保证：** 只要 FOPDT 模型是对被控对象的合理近似，IMC 设计在任意 λ > 0 下均能保证闭环稳定，不存在像 ZN 法那样超过稳定边界的风险。

#### Ziegler-Nichols 过程反应曲线法

ZN 法仅使用从阶跃响应中提取的两个标量：

- **反应速率：** $R = K/\tau$（响应曲线拐点处切线斜率，单位 nm V⁻¹ s⁻¹）
- **纯滞后：** L = θ

推荐 PI 整定参数（Ziegler & Nichols, 1942）：

$$K_p = \frac{0.9}{R \cdot L} = \frac{0.9\,\tau}{K\,\theta}, \qquad T_i = \frac{L}{0.3} = 3.33\,\theta, \qquad K_i = \frac{K_p}{T_i} = \frac{0.27\,\tau}{K\,\theta^2}$$

ZN 目标超调约 25%，比 IMC 更激进，适合对收敛速度要求高的场合，但当 θ 相对 τ 较大时容易产生振荡。

#### 单位与符号约定

代码中 `PIDController.update()` 实现的离散时间 PI 更新为：

$$v[k] = v[k-1] + K_p \cdot e[k] + K_i \cdot \Delta t \cdot \sum_{j \leq k} e[j]$$

其中 e[k] = 目标位移 − 测量位移（正值表示执行器需继续伸长）。Kp 单位为 V/nm，Ki 单位为 V/(nm·s)，与上述连续时间推导完全一致。

---

### 方法概述

`--autotune` 通过实测阶跃响应辨识 Piezo 被控对象模型，自动计算 `Kp` 和 `Ki`，无需手动调参。

```
阶跃：AUTOTUNE_V_LOW → AUTOTUNE_V_HIGH
              ↓
采集 AUTOTUNE_COLLECT_S 秒的位移-时间响应
              ↓
拟合一阶加纯滞后模型（FOPDT）：
    G(s) = K · e^(-θs) / (τs + 1)
    K = 静态增益 (nm/V)
    τ = 时间常数 (s)
    θ = 纯滞后 (s)
              ↓
按整定规则（IMC 或 ZN）计算 Kp、Ki
              ↓
应用增益，执行 PID 定位
```

### 整定规则

**IMC（内模控制）—— 推荐：**

$$K_p = \frac{\tau}{K(\lambda + \theta)}, \quad K_i = \frac{K_p}{\tau}$$

其中 λ = `AUTOTUNE_LAMBDA × τ` 为期望的闭环时间常数。λ 越大，响应越慢但越鲁棒。

**Ziegler-Nichols（过程反应曲线法）：**

$$K_p = \frac{0.9\,\tau}{K\,\theta}, \quad K_i = \frac{K_p}{3.33\,\theta}$$

ZN 给出更激进的增益，适合对收敛速度要求高的场合。

### 控制台输出示例

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

### 使用建议

| 场景 | 建议 |
|------|------|
| 首次使用新 Piezo | 务必先运行 `--autotune` 辨识被控对象 |
| 温度发生变化后 | 重新运行 `--autotune`，动态特性可能发生偏移 |
| PID 出现振荡或收敛慢 | 调大 `AUTOTUNE_LAMBDA` 后重新整定 |
| 被控对象已充分表征 | 跳过 `--autotune`，直接使用手动配置增益 |

---

## PID 闭环定位

### 控制策略

```
LUT 反向查询 → 前馈电压（快速接近，消除约 99% 误差）
           ↓
       PI 反馈 → 消除残差，精确定位
           ↓
   连续 PID_CONVERGE_COUNT 次 |误差| < PID_TOLERANCE_NM → 收敛
```

**强烈建议使用 LUT 前馈**。不使用前馈时，控制器从 `V_START` 出发，纯 PI 控制在大步进下积分器易饱和，收敛较慢。有 LUT 前馈时，初始误差通常 < 20 nm，仅需数次迭代即可收敛。

### 控制台输出示例

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

### 调参指南

| 参数 | 作用 | 默认值 |
|------|------|--------|
| `PID_KP` | 比例项：快速接近目标，过大会震荡 | `0.001` V/nm |
| `PID_KI` | 积分项：消除稳态偏差，过大会积分飞车 | `0.0002` V/(nm·s) |
| `PID_KD` | 微分项：抑制震荡，但 µMD2 噪声较大时慎用 | `0.0`（关闭） |
| `PID_INTEGRAL_LIMIT` | 积分项最大贡献，防止积分饱和 | `0.5` V |
| `PID_TOLERANCE_NM` | 收敛判断阈值，传感器噪声大时可适当放宽 | `5.0` nm |

### 在代码中直接调用

```python
from config import Config
from data import PiezoLUT
from hardware import UMD2Reader, MokuController
from control.loop import run_control   # 统一入口，按 mode 分发到 PID 或 ADRC
import logging

cfg = Config()
logger = logging.getLogger("piezo_lut")
lut = PiezoLUT.from_csv("lut_output/lut_20250506_143022.csv")

umd2 = UMD2Reader(cfg, logger)
moku = MokuController(cfg, logger)
umd2.connect()
moku.connect()

# PID 模式（默认）
result = run_control(
    mode="pid",          # 或 "adrc"
    target_nm=1000.0,
    cfg=cfg,
    umd2=umd2,
    moku=moku,
    logger=logger,
    lut=lut,
    temperature_C=25.0,
)

print(f"收敛: {result.converged}")
print(f"最终位移: {result.final_position_nm:.1f} nm")
print(f"最终电压: {result.final_voltage_V:.4f} V")
print(f"迭代次数: {result.iterations}  用时: {result.elapsed_s:.2f} s")

moku.zero_output(cfg.moku_channel)
umd2.close()
moku.close()
```

---

## 异常处理

| 情况 | 处理方式 |
|------|----------|
| 串口未找到（AUTO 模式） | 打印可用端口列表后退出 |
| µMD2 串口断开 | 尝试重连 3 次（间隔 2 s），失败则保存已有数据后退出 |
| Moku:Go 断开 | 尝试重连 3 次，失败则归零电压、保存数据后退出 |
| 采样不足（< 50%） | 打印警告，记录实际采样数，继续执行 |
| `Ctrl+C` 中断 | 立即归零电压，保存已采集数据，正常退出 |

---

## PID / ADRC 仿真 GUI（MATLAB）

`simulate.m` 是一个独立的 MATLAB 交互式图形界面，用于在无需任何硬件的情况下探索压电闭环控制行为。支持两种控制器：**PID**（含滤波微分项）和 **ADRC**（自抗扰控制），并提供实时性能指标面板和可滚动操作日志。

### 启动

在 MATLAB 命令行窗口中运行：

```matlab
simulate()
```

需要 MATLAB R2023b 或更新版本（使用 `uifigure`、`uigridlayout`、`uitable`）。已在 MATLAB 2026a 上测试。

### 文件结构

```
simulate.m          — GUI 入口（调用 +sim 包函数）
+sim/
  defaultParams.m   — 工厂默认参数结构体
  runSim.m          — 离散时间 FOPDT 仿真循环（PID + ADRC）
  makeSetpoint.m    — 目标轨迹波形发生器
  makeDisturbance.m — 干扰波形发生器
  computeMetrics.m  — 阶跃响应性能指标计算
  saveConfig.m      — JSON 配置保存
  loadConfig.m      — JSON 配置加载（回退到默认值）
test_simulate.m     — 单元测试（直接调用 sim.* 包函数，无需打开 GUI）
```

无需打开 GUI，直接运行单元测试：

```matlab
results = runtests('test_simulate');
table(results)
```

### 界面布局

```
┌─ 参数控制（左侧，可滚动）──────────────────────┐
│  植物（Piezo）—— 所有 Piezo 参数集中在此        │
│    K  (nm/V)          [    410 ]               │
│    τ  (ms)            [     80 ]               │
│    θ_piezo (µs)       [  10000 ]               │
│    V dead (V)         [      0 ]               │
│    Hysteresis (nm)    [      0 ]               │
│    Noise RMS (nm)     [      5 ]               │
│  控制器                                         │
│    Mode          [ PID ▼ / ADRC ]              │
│    Kp [0.002]  Ki [0.027]  Kd [0]             │
│    D filter N    [     20 ]                    │
│  ADRC                                          │
│    ω_c (rad/s)   [     20 ]                    │
│    ω₀  (rad/s)   [    100 ]                    │
│    Smith Predictor [ Off ▼ ]                   │
│  反馈延迟                                       │
│    θ_protocol (µs) [      0 ]                  │
│  Setpoint / 干扰 / 仿真设置 …                   │
└────────────────────────────────────────────────┘
┌─ 图表 + 指标（右侧）──────────────────────────────────────────┐
│  ┌───────────────────┐  ┌───────────────────┐                 │
│  │  位移 (nm)        │  │  定位误差 (nm)    │                 │
│  └───────────────────┘  └───────────────────┘                 │
│  ┌───────────────────┐  ┌───────────────────┐                 │
│  │  控制电压 (V)     │  │  干扰信号 (nm)    │                 │
│  └───────────────────┘  └───────────────────┘                 │
│  [▶ 运行] [IMC/ADRC 整定] [整定+运行] [重置] [Load LUT]       │
│  [导出…]  [Save Config] [Dist on Error ☐]                      │
│  ┌── 阶跃响应指标 ──────────────────────────────────────┐     │
│  │  超调: 0.0%  上升: 120ms  调节时间: 250ms             │     │
│  │  稳态 RMS: 0.8nm  IAE: 12.3nm·s  ITAE: 8.4nm·s²     │     │
│  └──────────────────────────────────────────────────────┘     │
│  ┌── 操作日志（可滚动）──────────────────────────────────┐     │
│  │  09:01:02  Ready — press ▶ Run Simulation             │     │
│  │  09:01:15  Running PID simulation  (2.0 s)…           │     │
│  │  09:01:15  Done  |  SS RMS: 0.8 nm  — Converged ✓    │     │
│  └──────────────────────────────────────────────────────┘     │
└───────────────────────────────────────────────────────────────┘
```

### 参数说明

所有参数均通过数字输入框或下拉菜单填写。属于未激活控制器的字段自动变灰禁用。

| 分组 | 参数 | 默认值 | 范围 |
|------|------|--------|------|
| 植物（Piezo） | K — 静态增益 (nm/V) | 410 | 10–2000 |
| 植物（Piezo） | τ — 时间常数 (ms) | 80 | 5–500 |
| 植物（Piezo） | θ_piezo — 机械纯滞后 (µs) | 10000 | 0–200000 |
| 植物（Piezo） | V dead (V) — 死区电压 | 0 | 0–5 |
| 植物（Piezo） | Hysteresis (nm) — 迟滞 | 0 | 0–500 |
| 植物（Piezo） | Noise RMS (nm) — 噪声 | 5 | 0–50 |
| 控制器 | Mode — 控制模式 | PID | PID / ADRC |
| 控制器（PID） | Kp | 0.002 | 0–0.05 |
| 控制器（PID） | Ki | 0.027 | 0–2.00 |
| 控制器（PID） | Kd | 0 | 0–0.10 |
| 控制器（PID） | D filter N — 微分滤波系数 | 20 | 0–200 |
| ADRC | ω_c (rad/s) — 控制器带宽 | 20 | 1–500 |
| ADRC | ω₀ (rad/s) — ESO 带宽 | 100 | 1–2000 |
| ADRC | Smith Predictor — 死时间补偿 | Off | Off / On |
| 反馈延迟 | θ_protocol (µs) — 协议延迟 | 0 | 0–50000 |
| Setpoint | Base DC (nm) | 0 | 0–5000 |
| 仿真 | 仿真时长 (s) | 2.0 | 0.5–3600 |
| 仿真 | V max (V) | 5 | 0–1000 |

### Setpoint（目标轨迹）发生器

**Setpoint** 分组使用波形表格。每行定义一个叠加到 Base DC 上的信号：

| 列 | 说明 |
|----|------|
| En | 启用/禁用本行 |
| Type | `Step` / `Sine` / `Square` / `Sawtooth` / `Triangle` / `Random` / `Noise` |
| Amp (nm) | 信号幅值 |
| Period (s) | 波形周期（`Step` 和 `Noise` 忽略此项） |
| Start (s) | 信号开始时间 |
| Dur (s) | 持续时长（0 表示持续到仿真结束） |

`Random`：每隔一个 Period 随机跳变到新幅值的分段常数信号。`Noise`：每个时间步叠加标准差为 Amp 的白高斯噪声。

多行信号相加后形成最终目标轨迹。使用 **+ Add SP** / **− Remove SP** 管理行数。

### 干扰信号发生器

**干扰** 分组使用相同的波形表格结构（无 `Step` 类型），同样支持 `Noise`。多行信号叠加后作用于植物输出。

| 波形类型 | 公式 |
|---------|------|
| 正弦 | $A\sin(2\pi f t')$ |
| 方波 | $A\,\operatorname{sgn}[\sin(2\pi f t')]$ |
| 锯齿波 | $A(2\{ft'\}-1)$ |
| 三角波 | $A(1-4\lvert\{ft'+0.25\}-0.5\rvert)$ |

其中 $t' = t - t_\text{start}$，$f = 1/\text{period}$。

### 仿真模型

仿真引擎采用 1 ms 植物积分步长（欧拉法）和 50 ms 控制器更新周期。

**植物模型**（带迟滞的一阶加纯滞后 FOPDT）：

$$G(s) = \frac{K\,e^{-\theta s}}{\tau s + 1}$$

纯滞后和反馈延迟均通过循环缓冲区实现。**迟滞**模型支持两种方式：
- **简单方向偏移**（默认）：电压下降时位移偏移 −Hysteresis (nm)，上升时无偏移。
- **Bouc-Wen 模型**（`bw_enable = true`）：物理基础的非线性迟滞 ODE，  
  $\Delta z = A\Delta u - \beta|\Delta u|z - \gamma\Delta u|z|$，输出 $= -D \cdot z$。可准确再现速率相关迟滞回线。参数：A（前屈服斜率）、β、γ（形状）、D_nm（最大迟滞位移贡献）。

#### PID 控制器（微分项作用于测量值）

微分项通过一阶滤波器作用于**测量值**（而非误差），避免目标值阶跃时的微分冲击（setpoint kick）：

$$d_\text{filt}[k] = \frac{d_\text{filt}[k-1]}{1+N\,T} + \frac{K_d\,N}{1+N\,T}\,\bigl(y[k-1] - y[k]\bigr)$$

**积分饱和防护**：积分项被限幅，防止大误差下积分器饱和。N = 0 时完全禁用微分项。

#### ADRC 控制器（自抗扰控制，1阶）

ADRC 将模型误差、迟滞、外部干扰等全部视为"总扰动"，通过扩张状态观测器（ESO）实时估计并主动抵消，无需精确数学模型。

**所需植物参数：** $b_0 = K/\tau$ [nm/(V·s)]

**ESO 更新** — 矩阵指数精确 ZOH 离散化（任意 ω₀ 和 DT 组合均稳定）：

$$\begin{bmatrix}z_1\\z_2\end{bmatrix}_{k+1} = A_d\begin{bmatrix}z_1\\z_2\end{bmatrix}_k + B_d\begin{bmatrix}u\\y\end{bmatrix}_k, \quad A_d,B_d = \text{expm}\!\left(\begin{bmatrix}A_c & B_c\\0&0\end{bmatrix}DT\right)$$

其中 $z_1 \approx y$（输出估计），$z_2 \approx$ 总扰动。

**控制律（含指令微分前馈）**（消除正弦/斜坡跟踪的相位滞后）：

$$u = \frac{\omega_c (r - z_1) + \dot{r} - z_2}{b_0}, \quad \dot{r} = \frac{r[k] - r[k-1]}{DT}$$

加入 $\dot{r}$ 后闭环传递函数从 $\omega_c/(s+\omega_c)$ 变为近似 $1$，相位滞后几乎消除。

**Smith Predictor**（Smith Predictor = On 时启用）：并联运行无死时间内部模型，将 ESO 测量量修正为：

$$y_\text{eso} = y_\text{meas} + (y_\text{model} - y_\text{model,delayed})$$

从 ESO 的有效死时间中去除 θ_plant，从而可以设置更高的 ω_c 而不失稳。开启后 IMC 整定会自动排除 θ_plant 的影响。

**调参建议：**
- 初始推荐：$\omega_c = 1/(\tau + \theta)$，$\omega_0 = 5\,\omega_c$
- 增大 $\omega_0$ 可加快扰动抑制；若噪声被放大则适当减小
- 增大 $\omega_c$ 可加快跟踪；若控制电压频繁饱和则适当减小
- 当 θ_piezo/τ > 0.3 时建议开启 Smith Predictor

### 性能指标面板

每次仿真运行后，指标面板自动显示阶跃响应质量数据：

| 指标 | 定义 |
|------|------|
| 超调 (%) | $(y_\text{峰值} - y_\text{目标}) / \|y_\text{阶跃}\| \times 100$ |
| 上升时间 (ms) | 从阶跃幅值 10% 到 90% 所需的时间 |
| 调节时间 (ms) | 输出最后一次离开 ±2% 误差带的时刻 |
| 稳态 RMS 误差 (nm) | 仿真最后 10% 时段内误差的 RMS 值 |
| IAE (nm·s) | $\int_0^T \|e(t)\|\,dt$，累积绝对误差 |
| ITAE (nm·s²) | $\int_0^T t\,\|e(t)\|\,dt$，对后期误差加权更重 |

IAE/ITAE 越小，整体跟踪性能越好。ITAE 对收敛慢的惩罚力度大于 IAE。

### 可滚动操作日志

仿真运行、自动整定结果、Load LUT 消息、导出路径及错误信息全部追加到右侧底部带时间戳的日志窗口中，保留完整的会话历史记录，方便回顾参数扫描过程。

### 按钮说明

| 按钮 | 功能 |
|------|------|
| ▶ 运行仿真 | 运行仿真并自动计算、显示性能指标 |
| IMC/ADRC 整定 | **PID 模式：** IMC 规则计算 Kp、Ki。**ADRC 模式：** 计算 ω_c = 1/(τ+θ_eff)，ω₀ = 5ω_c；Smith Predictor 开启时自动排除 θ_plant |
| Auto-tune + Run | 先自动整定，然后立即运行仿真 |
| 重置 | 恢复所有参数为出厂默认值 |
| Load LUT… | 加载 `lut_*.csv`；自动查找 `model_*.csv` → 填入 K / τ / θ_piezo / θ_protocol / V_dead / 噪声；自动查找 `summary_*.csv` → 填入迟滞值 |
| 导出… | 将图表保存为 PNG / PDF / SVG / EPS |
| Save Config | 手动保存当前所有参数到 `simulate_config.json` |
| Dist on Error ☐ | 在定位误差图上叠加显示干扰信号，直观观察干扰对误差的影响 |

### 参数配置文件持久化

所有参数会自动保存到与 `simulate.m` 同目录的 `simulate_config.json` 文件中。触发时机：

- 点击 **Save Config** 按钮（手动保存）
- 点击窗口右上角 × 关闭 GUI（自动保存）

下次运行 `simulate()` 时自动加载，无需重新填写参数。

JSON 文件可读性良好，可手动编辑或纳入版本控制：

```json
{
  "K": 410,
  "tau_ms": 80,
  "theta_us": 8500,
  "v_dead": 0.15,
  "hysteresis_nm": 35.0,
  "noise": 5,
  "ctrl_mode": "ADRC",
  "kp": 0.00217,
  "ki": 0.02708,
  "kd": 0.0,
  "d_filter_n": 20,
  "adrc_wc": 20,
  "adrc_w0": 100,
  "smith_adrc": false,
  "delay_us": 3800,
  "dt_pid_us": 50000,
  "sp_dc": 0,
  "v_max": 5,
  "t_total": 2.0,
  "setpoints": [
    {"en": true, "type": "Step", "amp": 1000, "period": 1.0, "t0": 0.1, "dur": 0.0}
  ],
  "signals": []
}
```

> **向后兼容：** 旧版配置文件中的 `theta_ms`（毫秒）和 `dt_pid_ms` 字段在加载时自动乘以 1000 转换为 `theta_us` / `dt_pid_us`（微秒）。

恢复出厂默认值：点击 **重置** 后再点 **Save Config**，或直接删除 `simulate_config.json`。

### 延迟分解与 Load LUT 映射

加载 `lut_*.csv` 时：

- 若同名 `model_*.csv` 存在且包含延迟分解字段，GUI 自动填入：
  - **θ_piezo (µs)** ← `theta_piezo_ms × 1000`（Piezo 机械延迟）
  - **θ_protocol (µs)** ← `theta_protocol_ms × 1000`（Moku 命令 + 串口帧 + USB 延迟）
- 若同名 `summary_*.csv` 存在，GUI 自动读取 `hysteresis_max_nm`（各温度均值）并填入 **Hysteresis (nm)** 字段
- 若模型文件为旧格式（无延迟分解列），则将 `theta_ms × 1000`（转换为 µs）填入 θ_piezo 作为保守回退值

### 自动整定公式

整定逻辑封装在 `+sim/imcTune.m`（Rivera et al. 1986）。

IMC 公式需要回路中**所有延迟之和**作为有效死区时间：

$$\theta_\text{eff} = \underbrace{\theta_\text{plant}}_{\text{p.theta\_us}} + \underbrace{\theta_\text{sensor}}_{\text{p.delay\_us}} + \underbrace{DT/2}_{\text{p.dt\_pid\_us}/2}$$

其中 $DT/2$ 是离散控制器的 ZOH 等效死区——控制器更新越慢、传感器延迟越大，有效死区越大，整定出的增益越保守（越小），系统越稳定。

**Smith Predictor 开启时**，ADRC 的有效死区排除 θ_plant（由预估器补偿），可以整定出更高的带宽：

$$\theta_\text{eff,ADRC} = \theta_\text{sensor} + DT/2 \quad (\text{Smith 开启})$$

**PID — 完整 IMC-PID（含微分项，λ = 2θ_eff）：**

$$K_p = \frac{\tau + \theta_\text{eff}/2}{K(\lambda + \theta_\text{eff}/2)}, \quad K_i = \frac{K_p}{\tau + \theta_\text{eff}/2}, \quad K_d = K_p \cdot \frac{\tau\theta_\text{plant}}{2\tau+\theta_\text{plant}}, \quad N = \left\lfloor\frac{2\tau+\theta_\text{plant}}{\theta_\text{plant}}\right\rceil$$

当 θ_plant = 0 时，K_d 自动为 0。

**ADRC：**

$$\omega_c = \frac{1}{\tau + \theta}, \quad \omega_0 = 5\,\omega_c$$

整定结果同时写入四个 PID 参数字段（Kp、Ki、Kd、N），并记录到操作日志。

### 图表导出

点击 **导出…** 打开保存对话框，支持格式：PNG（300 dpi）、PDF、SVG、EPS。底层调用 MATLAB 的 `exportgraphics` 函数。

---

## 控制台输出示例

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
