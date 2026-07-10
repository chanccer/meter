# 仿真出图教程：如何修改参数、如何手动复现论文里的全部图表

> 本文档对应论文 `Journal_of_Scientific_Reports_Pizo_Control(_CN)/paper.tex` 里
> "结果"章节从"闭环带宽受四种不同机制制约"往后的全部图表(图5–图10、表2、表3),
> 以及对应的黑白线稿风格 `paper_figures/` 输出。前四节硬件实验图(LUT、FOPDT、
> 点位定位、正弦跟踪)是 tikz/pgfplots 内联数据画的,不需要跑 MATLAB,这里不涉及。

## 〇、30秒快速开始

只想改一个数字、重新出图,不想看长文档?

1. 打开 `+sim/analysisConfig.m`,改你要改的那个数字(见下面"二、参数完全字典"
   找对应字段)。
2. 在仓库根目录依次跑六个脚本(见"五、一键全部生成"):
   ```bash
   cd /Users/nccer/Documents/meter
   matlab -batch "bandwidth_sweep"
   matlab -batch "bandwidth_sweep_nature"
   matlab -batch "bandwidth_sweep_phase_nature"
   matlab -batch "adrc_pole_analysis"
   matlab -batch "waveform_tracking_nature_all"
   matlab -batch "waveform_tracking_nature_split"
   ```
3. 新图在 `paper_figures/` 里,文件名不变,直接覆盖旧的。全部跑完约4分钟。

其余章节是这三步的详细展开,以及参数字典、原理说明和踩坑记录。

## 一、重要:这个仓库里有两套完全独立的参数系统

这是最容易搞混的地方,先讲清楚,否则改错文件会觉得"改了怎么没反应"。

| | **A. 论文出图用** | **B. 交互式仿真器用** |
|---|---|---|
| 谁在用 | 本文档说的六个脚本(`bandwidth_sweep*.m`、`adrc_pole_analysis.m`、`waveform_tracking_nature_*.m`) | `simulate.m`(GUI 界面)、`simulate_headless.m`(命令行单次仿真) |
| 参数存在哪 | `+sim/analysisConfig.m`,一个 MATLAB 函数,里面是四个场景 A/B/C/D 的固定定义 | `simulate_config.json`,一个 JSON 文件,GUI 里改滑块/输入框会自动存回这个文件;程序默认值在 `+sim/defaultParams.m` |
| 改了立刻生效吗 | 不会,要重新跑对应脚本才会重新生成图片 | 会,GUI 里改完点"运行"立刻看到新结果 |
| 对应关系 | 每个场景 = 一组"假想的硬件配置"(比如"如果采样率是2kHz会怎样"),用来做受控的对照实验 | 一份"当前真实/假想的硬件配置",你在 GUI 里手动调,用来探索单一一组参数下系统的行为 |
| 输出 | `paper_figures/` 下的 PDF/PNG/CSV,给论文用 | GUI 窗口里的图,或 `simulate_headless.m` 返回的结构体/保存的文件 |

**判断口诀**:改的是"论文图5–图10里四个场景对比"相关的东西 → 改
`+sim/analysisConfig.m`。改的是"我自己在 GUI 里跑一次仿真看看曲线"相关的东西
→ 改 `simulate_config.json` 或者直接在 GUI 里拖。两者互不影响,`+sim/runSim.m`
这个仿真引擎本身是两边共用的,但"喂给它什么参数"是两条独立的路径。

本文档接下来全部讲 A 路径(`+sim/analysisConfig.m`)。

## 二、`+sim/analysisConfig.m` 参数完全字典

打开这个文件,你会看到 `cfg` 这个结构体,分四块:

### 2.1 `cfg.plant` —— 四个场景共用的被控对象参数

| 字段 | 含义 | 单位 | 当前值 |
|---|---|---|---|
| `K` | 压电执行器静态增益(电压→位移) | nm/V | 410 |
| `v_max` | 执行器电压上限(超过会饱和限幅) | V | 5 |
| `noise` | 传感器噪声均方根,设为0是为了排除噪声干扰、单独看"算法本身"的带宽极限 | nm | 0 |
| `hysteresis_nm` | 迟滞位移量,同样设为0是为了排除迟滞干扰 | nm | 0 |

### 2.2 `cfg.sweep` —— `bandwidth_sweep.m` 扫频用的协议参数

| 字段 | 含义 | 当前值 |
|---|---|---|
| `nCyclesSettle` | 每个测试频率点,先跑几个周期让瞬态衰减掉、再开始记录 | 5 |
| `nCyclesMeasure` | 跑完稳定周期后,再跑几个周期用于最小二乘正弦拟合提取增益/相位 | 5 |

### 2.3 `cfg.waveformCycles` —— 时域波形图(图7–图10)的周期数

| 字段 | 含义 | 当前值 |
|---|---|---|
| `normal.sine` / `normal.square` | "正常带宽"测试频率下,正弦/方波各画几个周期 | 4 / 3 |
| `limit.sine` / `limit.square` | "极限带宽"测试频率下,正弦/方波各画几个周期(通常要多几个周期才能看清瞬态) | 6 / 5 |

### 2.4 `cfg.waveformControllers` —— 图7–图10里对比哪些控制器、顺序如何

这也是一个数组,`waveform_tracking_nature_all.m`/`_split.m` 按 `for i = 1:numel(...)`
渲染成一列一个面板——**不是写死"PID在左、Preview在右"**,加/删/调换这里的元素,
图上的列数和顺序就跟着变。默认三项:

| 字段 | 含义 | 当前值 |
|---|---|---|
| `name` | 面板标题里显示的名字 | `'PID'` / `'ADRC'` / `'Preview'` |
| `ctrl_mode` | 传给 `+sim/runSim.m` 的 `p.ctrl_mode` 字符串 | 同上 |
| `lineStyle` | 该控制器那条曲线的线型 | `'-'` / `'--'` / `'-.'` |

`name`/`ctrl_mode` 为 `'ADRC'` 的那一项,会在 `sc.hasADRC` 为 `false` 的场景(目前
只有场景B)里被 `+sim/buildWaveformCols.m` 自动跳过——不需要手动为每个场景单独
配置列表,已经在共享函数里处理好了。

想加一个新控制器进对比(比如以后真的实现了别的算法):在这个数组里加一个元素,
`ctrl_mode` 要跟 `+sim/runSim.m` 里 `strcmp(p.ctrl_mode, ...)` 认识的字符串一致;
如果这个新控制器也需要额外整定(类似 PID 要算 kp/ki、ADRC 要算 wc/w0),去
`+sim/buildWaveformCols.m` 的 `switch c.ctrl_mode` 里加一个 case。

### 2.5 `cfg.scenarios(i).plotWindowFrac` —— 时域图 x 轴显示区间

每个场景还有一个 `plotWindowFrac = [起始比例, 结束比例]`(默认 `[0 1]`),控制
图7–图10 每个面板 x 轴实际显示仿真时长的哪一段:`[0 1]` 是从头到尾全部显示(和
以前的固定行为一样),`[0.5 1]` 则只显示后一半、放大看细节。仿真本身还是跑
全长(前面的瞬态过程仍然需要仿真出来让系统稳定),只是显示范围变了。改这个值
只影响阶段4(时域图),不用重跑阶段1–3。

### 2.6 `cfg.scenarios` —— 每个场景一个数组元素,按顺序渲染

这是核心部分。`cfg.scenarios` 是一个结构体**数组**(不是固定的4个变量),六个
下游脚本全部用 `for i = 1:numel(cfg.scenarios)` 循环渲染——数组有几个元素,
图上就有几个面板,顺序也按数组顺序来。目前数组里有4个元素(A/B/C/D),但这不是
写死的上限,见"六、如何增删一个场景"。

每个元素(比如 `s(1)`)有这些字段:

| 字段 | 含义 | 单位/类型 |
|---|---|---|
| `name` | 场景内部标识符,决定输出文件名(如 `fig_waveform_A_sampling_rate.pdf`),必须和 CSV 里的 `scenario` 列匹配,同一份配置里不能重复 | 字符串,建议英文+下划线 |
| `label` | 中文场景说明,用在终端打印和图2那种总览表里 | 字符串 |
| `title` | 图上每个面板的英文标题 | 字符串 |
| `params.fs_sample_hz` | 传感器采样率(1/T,每隔多久才有一次新的位置读数) | Hz |
| `params.dt_pid_us` | 控制器更新周期(每隔多久算一次新的控制量) | µs |
| `params.theta_us` | 被控对象本身的机械死区时间(FOPDT模型里的θ) | µs |
| `params.delay_us` | 额外的反馈延迟(比如通信延迟、滤波器群延迟) | µs |
| `params.tau_us` | 被控对象一阶时间常数(FOPDT模型里的τ),决定执行器本征带宽 | µs |
| `ampNm` | 测试信号(正弦/方波/扫频)幅值 | nm |
| `dcNm` | 测试信号的直流偏置(工作点) | nm |
| `t0` | 仿真开始到信号真正启动之间的等待时间,给系统一点时间稳定初值 | s |
| `sweepFreqHz` | 阶段1扫频用的频率点数组,通常是 `logspace(log10(下限), log10(上限), 点数)` | Hz 数组 |
| `normalHz` | 时域波形图"正常工况"的测试频率 | Hz |
| `limitHz` | 时域波形图"极限工况"(接近带宽上限)的测试频率 | Hz |
| `hasADRC` | 这个场景要不要跑 ADRC+Smith 控制器做对比(场景B设为false,原因见下面"已知限制")——同时也决定图7–图10里这个场景要不要出现 ADRC 那一列(见2.4) | true/false |
| `poleAnalysis` | 这个场景要不要出现在表3(ADRC闭环极点分析)里 | true/false |
| `ceilingType` | 图5里那条灰色理论带宽上限竖线怎么算,见下表 | 字符串标签 |
| `plotWindowFrac` | 图7–图10 x 轴显示区间,见2.5 | `[起始比例 结束比例]`,默认 `[0 1]` |

`ceilingType` 的四种取值(在 `bandwidth_sweep_nature.m` 里现算,不是存死的Hz数字):

| 取值 | 公式 | 含义 | 用在哪个场景 |
|---|---|---|---|
| `'nyquist_fs'` | `fs_sample_hz / 2` | 传感器采样率决定的奈奎斯特上限 | A |
| `'nyquist_loop'` | `(1/dt_pid_us[s]) / 2` | 控制器更新率决定的奈奎斯特上限 | B |
| `'actuator_bw'` | `1/(2*pi*tau_us[s])` | 执行器本征一阶带宽(-3dB转折频率) | D |
| `'none'` | 无 | 纯延迟场景没有自然转折频率,不画线 | C |

**当前四个场景的实际取值一览**(方便对照,改的时候照着这个表找对应行):

| 场景 | `fs_sample_hz` | `dt_pid_us` | `delay_us` | `tau_us` | `hasADRC` | `ceilingType` |
|---|---|---|---|---|---|---|
| A 采样率瓶颈 | 1000 | 10 | 0 | 20 | true | `nyquist_fs` |
| B 环路更新率瓶颈 | 1000 | 1000 | 0 | 20 | true | `nyquist_loop` |
| C 反馈延迟瓶颈 | 10000 | 10 | 2000 | 20 | true | `none` |
| D 执行器带宽瓶颈 | 200000 | 1 | 0 | 20 | true | `actuator_bw` |

**2026-07 修正**:场景B的 `dt_pid_us` 之前误设为50000(50ms,对应20Hz),注释里还错误地
声称这"匹配真实硬件"——实际上真实硬件的控制环路更新率是1ms(1kHz),和传感器采样率
`fs_sample_hz` 同一个物理时钟,两者锁在一起,没有独立的"环路变慢"这回事。已改成
`dt_pid_us=1000`。这个修正顺带修好了一个之前记录在案的"已知限制":旧的50ms配置会让
`b0*DT_PID≈1e6`,把 ADRC 的 ESO 离散化算法(`+sim/runSim.m` 里 `expm()` 那部分)推入
数值病态区间导致控制器完全不收敛——`hasADRC` 因此被设成 `false`。换成真实的1ms后
`b0*DT_PID≈2e4`,ADRC 数值上完全正常,`hasADRC` 也改回了 `true`。这个数值病态 bug
本身还在(如果以后哪个场景真的把 `dt_pid_us` 设到比 `tau_us` 慢好几个数量级,还是会
复现),只是当前四个场景都不会再触发它。

## 三、如何修改参数(手把手例子,已实测)

**例子:把场景A的采样率从 1kHz 改成 2kHz,看看带宽上限是不是跟着翻倍。**

1. 打开 `+sim/analysisConfig.m`,找到 `s(1).params`(第54–55行左右):
   ```matlab
   s(1).params = struct('fs_sample_hz',1000, 'dt_pid_us',10, ...
                         'theta_us',0, 'delay_us',0, 'tau_us',20);
   ```
   把 `1000` 改成 `2000`:
   ```matlab
   s(1).params = struct('fs_sample_hz',2000, 'dt_pid_us',10, ...
                         'theta_us',0, 'delay_us',0, 'tau_us',20);
   ```
2. **同时把扫频范围的上限也放宽**,否则会踩到一个不明显的坑:
   `ceilingType='nyquist_fs'` 会自动把理论上限从 500Hz 重算成 1000Hz,但
   `s(1).sweepFreqHz = logspace(log10(5), log10(700), 14)` 这个数组的上限还是
   700Hz——图的 x 轴范围是跟着实际测试到的最高频率走的(`bandwidth_sweep_nature.m`
   里 `xlim` 用的是 `max(fAll)*1.1`),新的 1000Hz 上限线会落在可见范围之外,
   图上完全看不到、也不会报错,很容易误以为"改了没生效"。改成:
   ```matlab
   s(1).sweepFreqHz = logspace(log10(5), log10(1200), 14);
   ```
3. 保存文件,不用改任何其它脚本(`s(1).label` 那行文字里写的"fs=1kHz,
   Nyquist=500Hz"只是给人看的说明字符串,不影响计算,但改完参数最好顺手把它
   也改成"fs=2kHz, Nyquist=1000Hz",否则终端打印和图例文字会跟实际参数对不上)。
4. 在仓库根目录重新跑阶段1+阶段2a(见下面"七、一键全部生成"的命令块,这个
   例子只关心图5,不需要跑全部六个脚本):
   ```bash
   matlab -batch "bandwidth_sweep"
   matlab -batch "bandwidth_sweep_nature"
   ```
5. 打开 `paper_figures/fig_bandwidth_sweep.png`,场景A那个面板(左上,标 a)的
   灰色竖虚线现在应该出现在 1000Hz 处、x 轴也延伸到了 1000多Hz——因为
   `ceilingType='nyquist_fs'` 自动重算了 `fs_sample_hz/2`,不用你去改任何
   Hz 数字。同时 PID/ADRC 的 -3dB 带宽数值也会变,因为 IMC-PID 的整定公式里
   `zoh_fs = 0.5/fs_sample_hz` 这一项也会跟着变(见 `+sim/tunedPID.m`)。

**改测试频率范围**(比如场景A想扫到1kHz而不是700Hz):改
`s(1).sweepFreqHz = logspace(log10(5), log10(1000), 14);` 里的上限。

**改一个只影响时域图的参数**(比如场景A的"极限工况"测试频率想从150Hz改成
200Hz):改 `s(1).limitHz = 200;`,只需要重跑阶段4(两个 `waveform_tracking_nature_*`
脚本),不用重跑阶段1/2/3。

## 四、六个脚本、四个阶段是怎么串起来的

```
阶段1(必须最先跑,生成基础数据)
  bandwidth_sweep.m
      │  写出 bandwidth_sweep_results.csv
      │  （每个场景×每个控制器×每个测试频率的 gainDB / phaseLagDeg / saturated）
      ▼
  ┌───────────────┬───────────────────┬──────────────────────┐
  │  阶段2：频域图  │  阶段3：极点分析   │  阶段4：时域波形图     │
  │               │  （读阶段1的CSV）  │  （不读阶段1的CSV，   │
  │               │                   │   独立重算，见下方注意）│
  ├───────────────┼───────────────────┼──────────────────────┤
  │ bandwidth_    │ adrc_pole_        │ waveform_tracking_    │
  │  sweep_       │  analysis.m       │  nature_all.m         │
  │  nature.m     │                   │                       │
  │               │                   │ waveform_tracking_    │
  │ bandwidth_    │                   │  nature_split.m       │
  │  sweep_       │                   │                       │
  │  phase_       │                   │                       │
  │  nature.m     │                   │                       │
  └───────────────┴───────────────────┴──────────────────────┘
```

所有脚本共享同一份配置 `+sim/analysisConfig.m`——这是**唯一**的参数来源(见
"二、参数完全字典")。改参数只需要改这一个文件,六个脚本全部自动跟着变,不用
在别的地方同步任何数字。

PID 和 ADRC 的整定公式也各自只有一份实现:`+sim/tunedPID.m`(IMC-PID)、
`+sim/tunedADRC.m`(ADRC 的 `wc`/`w0`)。所有脚本(包括阶段3的极点分析)都是
调用这两个函数**现算**增益,不存在任何脚本里手抄整定公式或手抄计算结果的情况。

## 五、前置条件

- MATLAB(本仓库用 R2026a 测试过;不需要 Control System Toolbox,`adrc_pole_analysis.m`
  里用的是原始矩阵运算 `eig()`,不是 `ss()`/`bode()`)。
- **必须在仓库根目录 `/Users/nccer/Documents/meter` 下执行命令**,因为 `+sim/`
  是 MATLAB 的 package 文件夹(靠文件夹名前的 `+` 识别),只有当前工作目录的
  父目录包含 `+sim/` 时,`sim.analysisConfig()`、`sim.runSim()` 这些调用才能被
  找到。换目录跑会报 `Undefined function 'sim.xxx'`。
- 命令格式统一是 `matlab -batch "脚本名（不带.m）"`,例如:
  ```bash
  cd /Users/nccer/Documents/meter
  /Applications/MATLAB_R2026a.app/bin/matlab -batch "bandwidth_sweep"
  ```
  如果 `matlab` 已经在 PATH 里,直接 `matlab -batch "bandwidth_sweep"` 也行。

## 六、分步操作

### 阶段1 — 生成频域扫描数据(必须最先跑)

```bash
matlab -batch "bandwidth_sweep"
```

做的事:对 `+sim/analysisConfig.m` 里定义的每个场景(目前是四个:A采样率/
B环路更新率/C反馈延迟/D执行器带宽)分别做
IMC-PID、ADRC+Smith(数值有效时)、Preview 三个控制器的正弦扫频——14–16个对数间隔
频率点,每点跑一次时域仿真、做最小二乘正弦拟合提取增益和相位。

输出:`bandwidth_sweep_results.csv`(仓库根目录),终端会打印每个场景每个频率点的
增益/相位,以及最后的 -3dB 带宽小结(对应论文表2的数字来源)。

耗时:约60–80秒(160行数据,大部分时间花在低频场景B,因为要仿真好几个周期的
慢正弦波)。

**这一步的输出被阶段2和阶段3依赖,必须先跑。**

### 阶段2 — 频域图(黑白线稿,对应论文图5、图6)

```bash
matlab -batch "bandwidth_sweep_nature"
matlab -batch "bandwidth_sweep_phase_nature"
```

两个脚本都直接读 `bandwidth_sweep_results.csv`,不用重新仿真,几秒钟就出图。

- `bandwidth_sweep_nature.m` → `paper_figures/fig_bandwidth_sweep.pdf/.png`(图5,
  闭环增益 vs 频率,圆点=PID、方块=ADRC+Smith、三角=Preview、空心菱形=电压饱和点)。
  图中灰色竖虚线(理论带宽上限)是脚本内部根据每个场景的 `ceilingType`
  (`+sim/analysisConfig.m` 里的字符串标签,`nyquist_fs`/`nyquist_loop`/
  `actuator_bw`/`none`)现算出来的,不是写死的 Hz 数字;y 轴范围也是根据
  `bandwidth_sweep_results.csv` 里那个场景的实际增益数据自动适配的,不是每个场景
  手工挑的固定范围。面板的行列数、图幅大小、a/b/c/...标签也都是从
  `numel(cfg.scenarios)` 现算的——不是写死"2×2、4个面板、a-d"——在
  `+sim/analysisConfig.m` 里增删场景,面板布局和标签会自动跟着变,不用改这个脚本。
- `bandwidth_sweep_phase_nature.m` → `paper_figures/fig_bandwidth_phase.pdf/.png`
  (图6,闭环相位 vs 频率,同样式,场景标题同样来自 `+sim/analysisConfig.m`)

### 阶段3 — ADRC 极点解析分析(对应论文表3)

```bash
matlab -batch "adrc_pole_analysis"
```

做的事:把 ESO 方程和真实一阶被控对象联立,对场景 A、C 求闭环三阶特征多项式的
精确特征值,和渐近估计公式 $p_\text{slow}\approx -(25/11)\omega_c^2\tau$ 做对比,
再和阶段1仿真出来的离散带宽(真值)做对比。分析哪些场景由 `+sim/analysisConfig.m`
里每个场景的 `poleAnalysis` 布尔字段决定(目前是 A、B、C)。

输出:`adrc_pole_table.csv` + 终端打印的极点/带宽对比表(对应论文表3的数字)。

`wc`、`w0` 是脚本内部调用 `sim.tunedADRC()` 现算出来的,用的是
`+sim/analysisConfig.m` 里跟阶段1完全同一份场景参数——不存在手抄数值、不存在
和阶段1脱节的风险。改了场景A/C的参数(比如 `tau_us`、`delay_us`)或整定公式后,
直接重跑这一步就会自动用上新值,不需要额外同步任何东西。

**关于"最慢极点"的排序**:脚本对 `eig(A)` 算出来的三个闭环极点按**实部**从大到小
(最不负→最负,即最慢→最快)排序,取排序后第一个当作"主导/最慢极点"。这里特意没
用 MATLAB 的 `sort(poles,'descend')` 默认排序——默认排序对复数是按**模长**排序,
不是按实部。论文里 A、C 两个场景的极点都是纯实数,两种排序方式结果一样;但如果
以后新加的场景把 `wc` 设得比较大、导致闭环极点变成复数共轭对(ESO和被控对象耦合
出现欠阻尼振荡),按模长排序会把一个模长大但其实是快极点的复数对错误地当成"最慢
极点",算出一个比实际 -3dB 带宽还高的荒谬数字。按实部排序在两种情况下都是对的。

### 阶段4 — 时域波形图(对应论文图7–图10)

```bash
matlab -batch "waveform_tracking_nature_all"
matlab -batch "waveform_tracking_nature_split"
```

两个脚本**互相独立**,都直接从 `+sim/analysisConfig.m` 读场景参数、自己重新
跑时域仿真(正弦+方波、PID+Preview),不依赖阶段1的 CSV,所以哪怕跳过阶段1也能跑。

- `waveform_tracking_nature_all.m`:每个场景一张图(正弦/方波 × PID/Preview ×
  普通/极限带宽全部塞一张里,当前是 8 面板 a–h),输出
  `paper_figures/fig_waveform_<场景>.pdf/.png`——论文里没直接用这个版本,是留作
  总览参考的。
- `waveform_tracking_nature_split.m`:每个场景拆成两张图(普通带宽单独一张、
  极限带宽单独一张,当前各是 4 面板 a–d),输出
  `paper_figures/fig_waveform_<场景>_normal.pdf` 和 `_limit.pdf`。**论文图7–图10
  用的是这里的 `_limit` 版本。**

  这两个脚本的面板行列数、图幅大小、a/b/c/...标签都是从波形类型数组
  (`rows`,正弦/方波等)和控制器数组(`cols`,PID/Preview)的长度现算的,不是
  写死的"8面板"或"4面板"——给 `cols` 加一个控制器,或给 `rows` 加一种波形/
  带宽档位,面板布局会自动跟着变。

耗时:两个脚本各约45–50秒(4场景×2带宽×2波形×2控制器=32次独立仿真)。

## 七、一键全部生成

按依赖顺序,一次性把 `paper_figures/` 全部重新生成:

```bash
cd /Users/nccer/Documents/meter
matlab -batch "bandwidth_sweep"                  # 阶段1，约70s
matlab -batch "bandwidth_sweep_nature"           # 阶段2a，几秒
matlab -batch "bandwidth_sweep_phase_nature"     # 阶段2b，几秒
matlab -batch "adrc_pole_analysis"               # 阶段3，几秒
matlab -batch "waveform_tracking_nature_all"     # 阶段4a，约45s
matlab -batch "waveform_tracking_nature_split"   # 阶段4b，约50s
```

全部跑完约4分钟。之后如果要同步进论文的 Overleaf 项目,把 `paper_figures/`
里对应的 PDF 拖进 Overleaf 的 `bw_figures/` 文件夹替换即可(参照之前发你的
手动同步步骤)。

## 八、输出文件 → 论文图表对照表

| 论文里的编号 | 文件 | 生成脚本 |
|---|---|---|
| 表2(带宽小结) | 终端输出 / `bandwidth_sweep_results.csv` | `bandwidth_sweep.m` |
| 图5(增益 vs 频率) | `fig_bandwidth_sweep.pdf` | `bandwidth_sweep_nature.m` |
| 表3(极点分析) | 终端输出 / `adrc_pole_table.csv` | `adrc_pole_analysis.m` |
| 图6(相位 vs 频率) | `fig_bandwidth_phase.pdf` | `bandwidth_sweep_phase_nature.m` |
| 图7(场景A时域) | `fig_waveform_A_sampling_rate_limit.pdf` | `waveform_tracking_nature_split.m` |
| 图8(场景B时域) | `fig_waveform_B_loop_rate_limit.pdf` | `waveform_tracking_nature_split.m` |
| 图9(场景C时域) | `fig_waveform_C_feedback_delay_limit.pdf` | `waveform_tracking_nature_split.m` |
| 图10(场景D时域) | `fig_waveform_D_actuator_bandwidth_limit.pdf` | `waveform_tracking_nature_split.m` |

## 九、常见问题 / 踩坑记录

- **报错 `Undefined function 'sim.analysisConfig'`**:没有在仓库根目录下跑,
  或者 `cd` 到了别的地方。`+sim/` 是 MATLAB package,必须让它的父目录(仓库
  根目录)在当前工作目录或 MATLAB path 上。回到 `/Users/nccer/Documents/meter`
  重跑。
- **报错 `Run bandwidth_sweep.m first -- ... not found`**:阶段2/3依赖阶段1的
  `bandwidth_sweep_results.csv`,还没生成或被删了,先跑 `bandwidth_sweep`。
- **某个场景的 ADRC 曲线完全不动、或长时间不收敛**:大概率是 `+sim/runSim.m`
  里 ESO 精确 ZOH 离散化(`expm()`)的数值病态——当 `b0*DT_PID = (K/tau_us)*
  dt_pid_us` 接近 `1e6` 量级时会出现,`tau_us` 比 `dt_pid_us` 快太多个数量级
  就容易触发(2026-07之前场景B误配成 `dt_pid_us=50000` 时就是这样,已修正为
  真实的1000,现在四个场景都不会触发)。这不是"调参数能修好"的问题,是当前
  ADRC 实现本身在极端参数比例下的数值局限,论文 Limitations 章节也说明了这
  一点。如果新加的场景又把 `dt_pid_us` 设得比 `tau_us` 慢好几个数量级,记得
  把该场景的 `hasADRC` 设成 `false` 规避,而不是让仿真跑出一堆无意义的数字。
- **改了 `fs_sample_hz`/`dt_pid_us`/`tau_us`,理论上限竖线却在图上消失了**:
  不是没生效,是竖线的新位置超出了图的 x 轴范围。`bandwidth_sweep_nature.m` 的
  x 轴范围跟着 `sweepFreqHz` 里实际测试到的最高频率走,理论上限一旦超过这个
  范围就画不出来(也不会报错)。改了会让上限变高的参数后,记得同时把
  `sweepFreqHz` 的上限也相应放宽,见"三、如何修改参数"的实测例子。
- **改了 `+sim/analysisConfig.m`,图片却没变**:六个脚本各自独立生成对应的
  PDF/PNG,改完参数后要重新跑**所有**受影响的阶段(参考"十、想改点什么"里
  每种改动对应重跑哪几个阶段),不会自动触发。也检查一下是不是改错了文件——
  `simulate_config.json`/`+sim/defaultParams.m` 是给 GUI 用的,跟这六个脚本
  无关(见"一、两套参数系统")。
- **想确认某次修改后数值到底变没变、变了多少**:直接对比新旧
  `bandwidth_sweep_results.csv`(比如 `diff` 或者用 Excel/Numbers 打开对比),
  或者看终端里阶段1打印的"-3dB 闭环带宽小结",改动前后跑一次记录一下数字最直观。
- **`matlab` 命令找不到**:没加入 PATH,用完整路径
  `/Applications/MATLAB_R2026a.app/bin/matlab -batch "..."`(路径按你本机的
  MATLAB 版本文件夹名调整)。

## 十、想改点什么?常见修改点

`+sim/analysisConfig.m` 是**唯一**需要改的地方,改完从阶段1开始重跑一遍全部
四个阶段即可,不需要在任何其它脚本里同步任何数字:

- **改某个场景的参数**(采样率/延迟/τ等):改 `cfg.scenarios(i).params` 那一行。
  影响阶段1234全部,要全部重跑。
- **改测试频率范围/点数**:改 `cfg.scenarios(i).sweepFreqHz`(`logspace(...)`)。
  只影响阶段1、2,重跑那两个即可。
- **改公共被控对象参数**(增益K/电压上限/噪声):改 `cfg.plant`。影响阶段1234
  全部。
- **改时域波形的周期数、普通/极限测试频率**:改 `cfg.waveformCycles` 或
  `cfg.scenarios(i).normalHz`/`.limitHz`。只影响阶段4。
- **改图7–图10对比哪些控制器、顺序**:改 `cfg.waveformControllers`(见2.4)——
  不是写死"PID左、Preview右",加/删/调换数组元素,列数和顺序就跟着变;新控制器
  如果需要额外整定逻辑,要去 `+sim/buildWaveformCols.m` 里加一个 `case`。只影响
  阶段4。
- **改图7–图10每个面板 x 轴显示的时间范围**:改 `cfg.scenarios(i).plotWindowFrac`
  (见2.5),默认 `[0 1]`(全部显示)。只影响阶段4。
- **加/删场景**(不限于四个):在 `cfg.scenarios` 里加/删一个元素,记得设置
  `hasADRC`/`poleAnalysis`/`ceilingType` 三个标志。下游全部脚本(扫频、极点分析、
  两张频域图、两张时域图)都是按 `numel(cfg.scenarios)` 循环渲染的,面板行列数、
  图幅大小、a/b/c/...标签会自动跟着场景数量变化,不需要改任何画图脚本本身。
  新场景如果要出现在表3(极点分析),记得也把它的 `tau_us`/`dt_pid_us` 差距
  控制在合理范围,避免"常见问题"里说的数值病态。
- **改 Preview 微调增益**(`prev_kp`/`prev_ki`):`+sim/defaultParams.m` 里,
  改完阶段1–4全部要重跑(影响所有图)。
- **改 PID/ADRC 整定公式本身**:`+sim/tunedPID.m` / `+sim/tunedADRC.m`,同样
  全部脚本会自动用上新公式,不需要手动同步。
- **只想看某一张图效果、不想等4分钟**:阶段2、3、4彼此独立,除了阶段3依赖
  阶段1的 CSV 之外,可以只跑你关心的那一两个脚本。
- **验证核心仿真引擎本身没被改坏**:`matlab -batch "r=runtests('test_simulate'); disp(table(r))"`,
  73个单元测试,几秒钟跑完,改 `+sim/runSim.m` 之后建议先跑这个再出图。
