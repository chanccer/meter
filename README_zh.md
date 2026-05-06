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
