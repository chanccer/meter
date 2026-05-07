# meter — Piezo 电压-位移 LUT 自动采集系统

自动建立 Piezo 执行器的电压-位移查找表（LUT），并提供**闭环 PID 定位模式**，驱动 Piezo 到达指定位移。通过 **µMD2**（USB 串口位移传感器）采集纳米级位移数据，通过 **Moku:Go** 输出 DC 驱动电压，支持多温度点、迟滞测量和双向插值查询。

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
git clone <repo>
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

---

## 配置参数

所有参数集中在 `main.py` 顶部，修改后直接运行即可。

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
```

**多温度扫描示例：**

```python
TEMPERATURES = [20, 25, 30, 35, 40]
```

每个温度点开始前会暂停并提示操作者调温，然后倒计时等待 `TEMP_STABILIZE_TIME` 秒稳定。仅单温度时（默认）跳过提示，直接测量。

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
| `summary_YYYYMMDD_HHMMSS.csv` | 每温度点统计摘要 |
| `lut_partial_25C.csv` | 单温度中间结果（每温度完成后更新） |
| `lut_YYYYMMDD_HHMMSS.log` | 完整日志（DEBUG 级别） |

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

---

## PiezoLUT 查询接口

采集完成后，脚本末尾自动演示查询。也可以在自己的代码中直接使用：

```python
from main import PiezoLUT

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

## PID 仿真 GUI

`simulate.py` 是一个独立的交互式图形界面，用于在无需任何硬件的情况下探索压电 PID 控制行为。它运行离散时间 FOPDT 仿真，内置 PI 控制器，支持实时调节所有参数。

### 启动

```bash
uv run python simulate.py
```

需要 tkinter 支持（macOS 示例：`brew install python-tk@3.13`）。

### 界面布局

```
┌─ 参数控制（左侧）────────────────────────────────────────────────────────────┐
│  植物 (FOPDT)         K (nm/V)  τ (ms)  θ (ms)                             │
│  PID 增益             Kp  Ki  Kd   [IMC 自动整定]                           │
│  反馈延迟             额外延迟 (ms)                                           │
│  目标位移             目标 (nm)                                               │
│  干扰信号             类型 ▾   幅值 (nm)   频率 (Hz)                         │
│  传感器噪声           RMS (nm)                                                │
│  仿真设置             仿真时长 (s)   阶跃时刻 (s)   最大电压 (V)              │
│  [▶ 运行仿真]  [重置]                                                         │
└──────────────────────────────────────────────────────────────────────────────┘
┌─ 图表（右侧）────────────────────────────────────────────────────────────────┐
│  ┌─────────────────┐  ┌─────────────────┐                                    │
│  │ 位移 (nm)       │  │ 定位误差 (nm)   │                                    │
│  └─────────────────┘  └─────────────────┘                                    │
│  ┌─────────────────┐  ┌─────────────────┐                                    │
│  │ 控制电压 (V)    │  │ 干扰信号 (nm)   │                                    │
│  └─────────────────┘  └─────────────────┘                                    │
│  [matplotlib 工具栏：平移 | 缩放 | 导出 PNG/PDF/SVG]                          │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 参数说明

| 分组 | 参数 | 默认值 | 范围 |
|------|------|--------|------|
| 植物 | K — 静态增益 (nm/V) | 410 | 10–2000 |
| 植物 | τ — 时间常数 (ms) | 80 | 5–500 |
| 植物 | θ — 植物纯滞后 (ms) | 10 | 0–200 |
| PID | Kp | 0.002 | 0–0.05 |
| PID | Ki | 0.027 | 0–2.00 |
| PID | Kd | 0 | 0–0.01 |
| 反馈 | 额外传感器延迟 (ms) | 0 | 0–500 |
| 目标 | 目标位移 (nm) | 1000 | 100–5000 |
| 干扰 | 类型 | 无 | 无 / 高频正弦 / 低频正弦 / 周期方波 |
| 干扰 | 幅值 (nm) | 50 | 0–500 |
| 干扰 | 频率 (Hz) | 10 | 0.1–200 |
| 噪声 | 传感器 RMS (nm) | 5 | 0–50 |
| 仿真 | 仿真时长 (s) | 2.0 | 0.5–10 |

### 仿真模型

仿真引擎采用 1 ms 植物积分步长（欧拉法）和 50 ms PID 更新周期，与实际实时控制节拍一致。

**植物模型**（一阶加纯滞后 FOPDT）：

$$G(s) = \frac{K\,e^{-\theta s}}{\tau s + 1}$$

纯滞后通过长度为 $\lceil \theta / \Delta t_{\rm plant} \rceil$ 的循环缓冲区实现。

**额外反馈延迟**：第二个循环缓冲区在测量值到达 PID 控制器之前引入额外延迟，模拟电缆时延、滤波器滞后或通信延迟。

**干扰类型**（在阶跃时刻后叠加至植物输出）：

| 类型 | 信号公式 |
|------|--------|
| 高频正弦 | $d(t) = A \sin(2\pi f t)$ |
| 低频正弦 | $d(t) = A \sin(2\pi (f/10)\, t)$ |
| 周期方波 | $d(t) = A \operatorname{sgn}[\sin(2\pi f t)]$ |

**积分饱和防护**：积分累积量被限幅，确保积分项单独不会使输出超过电压上下限。

### IMC 自动整定按钮

根据当前 K、τ、θ 滑块值，以 $\lambda = 2\theta$ 直接计算 IMC PI 增益：

$$K_p = \frac{\tau}{K(\lambda + \theta)}, \quad K_i = \frac{K_p}{\tau}$$

结果立即写回 Kp 和 Ki 滑块，再次点击 **运行仿真** 即可查看闭环响应。

### 图表导出

使用图表底部的 matplotlib 导航工具栏：

- **软盘图标** → 保存对话框（支持 PNG、PDF、SVG、EPS）
- **放大镜图标** → 区域缩放
- **平移图标** → 拖拽平移

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
