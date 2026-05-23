# PID 与 ADRC 自动整定原理详解

> 本文档对应代码库中的以下文件：
> - `+sim/imcTune.m` — MATLAB 仿真 GUI 的整定公式
> - `tune/imc.py` — Python 硬件路径的整定公式（与 MATLAB 数值等价）
> - `tune/system_id.py` — FOPDT 阶跃辨识与协议延迟测量
> - `control/adrc.py` — ADRC 控制器 + Smith Predictor
> - `control/pid.py` — 离散时间 PID 控制器

---

## 1. 植物模型（FOPDT）

整个自动整定流程建立在**一阶加纯滞后**（FOPDT, First-Order Plus Dead Time）模型之上：

$$G(s) = \frac{K \cdot e^{-\theta s}}{\tau s + 1}$$

| 参数 | 物理含义 | 典型范围 |
|------|----------|----------|
| $K$ | 静态增益（nm/V） | 100 — 1000 |
| $\tau$ | 时间常数（µs） | 5 — 200000 |
| $\theta$ | 纯滞后（µs） | 0 — 5000 |

对压电陶瓷执行器而言，$K$ 是施加 1V 时稳定位移，$\tau$ 反映机械惯性，$\theta$ 是从电压改变到位移开始响应的死区时间。

---

## 2. 模型辨识（阶跃响应法）

### 2.1 实验流程

```
硬件路径 (system_id.py → AutoTuner.run)        仿真路径 (simulate.m GUI)
─────────────────────────────────────────────   ────────────────────────────────
1. 稳定至初始电压 v_low，等待 6×settle_time     用界面参数 K/τ/θ 直接输入，
2. 切换至 v_high，采集带时间戳的位移数据         无需实际辨识
3. 对响应曲线做 Levenberg-Marquardt 非线性拟合
4. 重复 step_ident_reps 次取均值
5. 分解延迟：θ_total = θ_piezo + θ_protocol
```

### 2.2 FOPDT 曲线拟合

模型响应的解析式（`AutoTuner._fopdt_model`）：

$$y(t) = \begin{cases} y_0 & t \le \theta \\ y_0 + K \cdot \Delta V \cdot \left(1 - e^{-(t-\theta)/\tau}\right) & t > \theta \end{cases}$$

**初始猜值策略**（防止 L-M 收敛到局部极小）：

| 参数 | 初始猜值 | 搜索边界 |
|------|----------|----------|
| $K_0$ | $(y_\infty - y_0) / \Delta V$ | \[1, 5000\] nm/V |
| $\tau_0$ | $t_{end} / 4$ | \[0.0001, 60\] s |
| $\theta_0$ | $\min(0.02,\ t_{end}/10)$ | \[0, 10\] s |

拟合质量用 $R^2$ 评估；多次重复后对 $K$、$\tau$、$\theta$ 取算术平均值。

### 2.3 延迟分解（`identify_model`）

观测到的总死时间 $\theta_{total}$ 包含两部分：

$$\theta_{total} = \theta_{piezo} + \theta_{protocol}$$

**协议延迟测量**（`measure_protocol_delay`）分两步：

1. **Moku 指令延迟** $t_{moku}$：对 `moku.set_voltage()` 调用计时，取多次均值。
2. **µMD2 帧到达延迟** $t_{frame}$：测量连续两帧位移读数之间的时间间隔。

$$\theta_{protocol} = t_{moku} + t_{frame}$$

$$\theta_{piezo} = \max\bigl(0,\ \theta_{total} - \theta_{protocol}\bigr)$$

物理意义：$\theta_{protocol}$ 是通信链路引入的软件延迟，$\theta_{piezo}$ 才是压电陶瓷本身的机械延迟。将两者分离可以在未来针对性地优化（例如换更快的串口波特率只能减小 $\theta_{protocol}$，而与机械结构无关）。

---

## 3. 等效总纯滞后（IMC 的核心输入）

IMC（内模控制，Internal Model Control）要求输入**闭环中所有延迟来源之和**，而不仅是植物死时间。

$$\boxed{\theta_{eff} = \theta_{plant} + \theta_{sensor} + \frac{DT_{controller}}{2}}$$

| 延迟项 | 来源 | 代码字段 |
|--------|------|----------|
| $\theta_{plant}$ | 压电陶瓷纯滞后 | `p.theta_us` / `theta_plant_s` |
| $\theta_{sensor}$ | 传感器/协议反馈延迟 | `p.delay_us` / `theta_sensor_s` |
| $DT/2$ | 离散控制器的 ZOH 等效延迟 | `p.dt_pid_us / 2` |

**为什么 $DT/2$？**  
一个周期为 $DT$ 的零阶保持（ZOH）离散控制器，平均在每个采样周期的中点才"反应"到误差，等效于在连续系统中引入了 $DT/2$ 的额外纯滞后（Åström & Hägglund 1995，第 8 章）。

---

## 4. PID 自动整定（IMC-PID，Rivera 1986）

### 4.1 设计闭环带宽

IMC 方法用一个可调参数 $\lambda$（期望闭环时间常数）来控制激进程度。代码中取保守设定：

$$\lambda = 2 \cdot \theta_{eff}$$

$\lambda$ 越大，响应越慢但鲁棒性越好；$\lambda$ 越小，响应越快但对模型误差更敏感。

### 4.2 增益公式

$$d = \tau + \dfrac{\theta_{eff}}{2} \quad \text{（分母公因子）}$$

$$\boxed{K_p = \frac{d}{K \cdot (\lambda + \theta_{eff}/2)}}$$

$$\boxed{K_i = \frac{K_p}{d}}$$

$$\boxed{K_d = K_p \cdot \frac{\tau \cdot \theta_{plant}}{2\tau + \theta_{plant}}}$$

$$\boxed{N = \mathrm{round}\!\left(\frac{2\tau + \theta_{plant}}{\theta_{plant}}\right)} \quad \text{（微分滤波器截止频率倍数）}$$

**注意**：$K_d$ 和 $N$ 只用 $\theta_{plant}$（植物结构性零点），而不是 $\theta_{eff}$，因为微分项补偿的是植物的内在极零点，而非通信延迟。

### 4.3 离散 PID 实现（`control/pid.py`）

```
u[k] = Kp·e[k] + Ki·∑e·dt（积分限幅） + Kd·(e[k]-e[k-1])/dt
```

**积分抗饱和**：积分项被硬限幅至 `±integral_limit`，然后将 `_integral` 反算回来，防止"积分飞车"（integrator windup）在大误差时导致的过冲。

**微分滤波**：在仿真中，微分通道经 $N$ 阶滤波器抑制噪声放大：

$$D(s) = K_d \cdot \frac{Ns}{s + N}$$

### 4.4 Ziegler-Nichols 备选（ZN）

当 `cfg.autotune_method = "ZN"` 时，使用经验公式（仅供比较，不推荐生产使用）：

$$K_p^{ZN} = \frac{0.9\tau}{K\theta}, \quad K_i^{ZN} = \frac{K_p^{ZN}}{3.33\theta}$$

ZN 公式没有考虑离散控制器的 $DT/2$ 延迟，在高速采样系统中会偏于激进。

---

## 5. ADRC 自动整定

### 5.1 ADRC 结构简介

一阶 ADRC 由两部分组成：

**扩展状态观测器（ESO）**：把"所有未建模动态 + 外部扰动"集总为一个可估计的状态 $z_2$（"总扰动"）：

$$\dot{z}_1 = -2\omega_0 z_1 + z_2 + b_0 u + 2\omega_0 y$$
$$\dot{z}_2 = -\omega_0^2 z_1 + \omega_0^2 y$$

**控制律**（主动抵消扰动 + 比例控制）：

$$u_0 = \omega_c \cdot (r - z_1) + \dot{r} \quad \text{（含设定值微分前馈）}$$
$$u = \frac{u_0 - z_2}{b_0} \quad \text{（抵消总扰动）}$$

其中 $b_0 = K / \tau$ 是植物的已知增益参数。

### 5.2 带宽参数化设计

ADRC 只有两个自由参数 $\omega_c$（控制器带宽）和 $\omega_0$（ESO 带宽），消除了 PID 三参数之间的耦合调试。整定规则：

$$\theta_{eff,ADRC} = \begin{cases} \theta_{sensor} + DT/2 & \text{Smith Predictor 开启} \\ \theta_{plant} + \theta_{sensor} + DT/2 & \text{Smith Predictor 关闭} \end{cases}$$

$$\boxed{\omega_c = \frac{1}{\tau + \theta_{eff,ADRC}}}$$

$$\boxed{\omega_0 = 5 \cdot \omega_c}$$

直觉理解：$\omega_c$ 由系统最慢的动态（$\tau + 总延迟$）决定；$\omega_0 = 5\omega_c$ 确保 ESO 收敛速度比控制带宽快 5 倍，在观测精度和噪声放大之间取得平衡。

---

## 6. Smith Predictor 对带宽的影响

### 6.1 原理

Smith Predictor 并联运行一个**无纯滞后**的 FOPDT 模型（Euler 积分，步长 1 ms），并维护一段延迟缓冲区：

```
Smith 修正量 = y_model_now − y_model_{θ_plant 步前}
ESO 输入 = y_meas + Smith 修正量
```

通过这个修正，ESO "看到"的输出仿佛没有 $\theta_{plant}$ 的延迟，因此可以使用更高的 $\omega_0$。

### 6.2 对带宽的量化影响

以典型参数为例（$\tau = 20\ \mu s,\ \theta_{plant} = 5\ \mu s,\ \theta_{sensor} = 0,\ DT = 1\ \mu s$）：

|  | $\theta_{eff,ADRC}$ | $\omega_c$ |
|--|---------------------|------------|
| Smith 关闭 | $5 + 0 + 0.5 = 5.5\ \mu s$ | $\approx 48{,}000$ rad/s |
| Smith 开启 | $0 + 0.5 = 0.5\ \mu s$ | $\approx 484{,}000$ rad/s |

Smith Predictor 消除 $\theta_{plant}$ 后，可用带宽大幅提升（约 10×），但代价是依赖模型精度——若 $K$、$\tau$、$\theta_{plant}$ 估计偏差大，修正量会引入误差。

### 6.3 自动联动（MATLAB GUI）

在 GUI 中切换 Smith 开关时，会**自动触发重新整定**（`sSmith.ValueChangedFcn → onSmithToggle → onAutotune`），用户无需手动点击 Auto-tune 按钮即可看到带宽变化。

---

## 7. ESO 精确 ZOH 离散化

连续 ESO 方程写成矩阵形式：

$$\dot{\mathbf{z}} = A_c \mathbf{z} + B_c \begin{bmatrix} u \\ y \end{bmatrix}$$

$$A_c = \begin{bmatrix} -2\omega_0 & 1 \\ -\omega_0^2 & 0 \end{bmatrix}, \quad B_c = \begin{bmatrix} b_0 & 2\omega_0 \\ 0 & \omega_0^2 \end{bmatrix}$$

对输入 $[u,\ y]^T$ 做零阶保持（ZOH）精确离散化，需要构造增广矩阵：

$$M_{aug} = \begin{bmatrix} A_c & B_c \\ 0_{2\times2} & 0_{2\times2} \end{bmatrix} \in \mathbb{R}^{4\times4}$$

$$\Phi = e^{M_{aug} \cdot DT} \quad \text{（矩阵指数，scipy.linalg.expm）}$$

$$A_d = \Phi_{[0:2,\ 0:2]}, \quad B_d = \Phi_{[0:2,\ 2:4]}$$

离散递推（`ADRCController.update`）：

$$\mathbf{z}[k+1] = A_d \mathbf{z}[k] + B_d \begin{bmatrix} v[k] \\ y[k] \end{bmatrix}$$

使用矩阵指数而非欧拉近似的原因：当 $\omega_0 \cdot DT$ 较大时（高带宽、慢采样），欧拉法会产生数值不稳定；`expm` 保证精确匹配连续时间极点，与 MATLAB 的 `expm(Maug*DT_PID)` 数值逐比特等价。

---

## 8. 整定流程总览

### 8.1 MATLAB 仿真 GUI 路径

```
用户在界面输入 K / τ(µs) / θ(µs) / delay(µs) / DT(µs)
                    ↓
        点击 [Auto-tune] 或切换 Smith 开关
                    ↓
          sim.imcTune(p)   (+sim/imcTune.m)
          ┌─────────────────────────────────┐
          │  θ_eff = θ_plant + delay + DT/2 │
          │  ── PID ─────────────────────── │
          │  λ = 2·θ_eff                    │
          │  d = τ + θ_eff/2                │
          │  Kp = d / (K·(λ + θ_eff/2))    │
          │  Ki = Kp / d                    │
          │  Kd = Kp·τ·θ_plant/(2τ+θ_plant)│
          │  N  = round((2τ+θ_plant)/θ_plant│
          │  ── ADRC ────────────────────── │
          │  θ_eff_adrc = delay+DT/2 (Smith)│
          │           或 = θ_eff   (无Smith) │
          │  ωc = 1/(τ + θ_eff_adrc)        │
          │  ω0 = 5·ωc                      │
          └─────────────────────────────────┘
                    ↓
          增益回写 GUI 参数面板
                    ↓
          点击 [Run] 启动仿真
```

### 8.2 Python 硬件路径

```
主程序启动  →  identify_model()
                ├── measure_protocol_delay()
                │     ├── t_moku = 平均 set_voltage() 调用耗时
                │     └── t_frame = 平均 µMD2 帧间隔
                └── AutoTuner._fit_fopdt()  ×reps 次，取均值
                      └── K, τ, θ_total → θ_piezo, θ_protocol
                              ↓
                    imc_tune_from_model()   (tune/imc.py)
                    ┌────────────────────────────────────┐
                    │  与 MATLAB imcTune.m 数值完全等价   │
                    └────────────────────────────────────┘
                              ↓
              PID: Kp/Ki/Kd → PIDController (control/pid.py)
              ADRC: ωc/ω0  → ADRCController + SmithPredictor
                                             (control/adrc.py)
```

---

## 9. 参数敏感性与实用指南

### 9.1 模型误差的影响

| 误差来源 | 对 PID 的影响 | 对 ADRC 的影响 |
|----------|--------------|----------------|
| $K$ 估计偏大 | $K_p$ 偏小，响应变慢 | $b_0$ 偏大，ESO 补偿过度 |
| $\tau$ 估计偏大 | $K_p$ 偏大，易振荡 | $\omega_c$ 偏小，响应变慢 |
| $\theta$ 估计偏大 | $\lambda$ 偏大，保守 | Smith ON 时修正量增大 |

### 9.2 稳定性边界（经验规则）

- **PID**：$\lambda = 2\theta_{eff}$ 对应约 3 倍增益裕度。若需更快响应，可将 $\lambda$ 减小至 $\theta_{eff}$，但需验证阶跃响应无振荡。
- **ADRC**：$\omega_0 = 5\omega_c$ 是典型下限；若 ESO 噪声过大可增大至 $8\omega_c \sim 10\omega_c$，若发散则减小 $\omega_c$。
- **Smith Predictor**：仅在 $\theta_{plant} / \tau > 0.1$ 时收益显著；若 $\theta_{plant}$ 估计误差超过 30%，修正量误差可能抵消收益。

### 9.3 逐步调试建议

1. 先运行仿真 GUI 验证参数合理性（Rise time、Overshoot 是否符合预期）。
2. 确认 $R^2 > 0.95$ 后再使用拟合参数；若 $R^2$ 较低，增大阶跃幅度或延长采集时间。
3. 先用 PID 模式建立基线，再切换 ADRC 对比。
4. Smith Predictor 开启前，先在仿真中确认 $\theta_{plant}$ 估计精度。
5. 微调时优先调整 $\lambda$（PID）或直接调整 $\omega_c$（ADRC），而非手动修改 $K_p$/$K_i$，以保持整定逻辑一致性。

---

## 10. 公式速查表

### PID（IMC，Rivera 1986）

$$\theta_{eff} = \theta_{plant} + \theta_{sensor} + \frac{DT}{2}$$

$$\lambda = 2\theta_{eff}, \quad d = \tau + \frac{\theta_{eff}}{2}$$

$$K_p = \frac{d}{K(\lambda + \theta_{eff}/2)}, \quad K_i = \frac{K_p}{d}, \quad K_d = K_p \frac{\tau\theta_{plant}}{2\tau + \theta_{plant}}$$

### ADRC（带宽参数化）

$$\theta_{eff,ADRC} = \begin{cases} \theta_{sensor} + DT/2 & \text{Smith ON} \\ \theta_{plant} + \theta_{sensor} + DT/2 & \text{Smith OFF} \end{cases}$$

$$\omega_c = \frac{1}{\tau + \theta_{eff,ADRC}}, \quad \omega_0 = 5\omega_c, \quad b_0 = \frac{K}{\tau}$$

### ESO 离散化

$$\Phi = \exp\!\left(\begin{bmatrix} A_c & B_c \\ 0 & 0 \end{bmatrix} DT\right), \quad A_d = \Phi_{[0:2,0:2]}, \quad B_d = \Phi_{[0:2,2:4]}$$

### ZN 备选（仅 PID）

$$K_p^{ZN} = \frac{0.9\tau}{K\theta}, \quad K_i^{ZN} = \frac{K_p^{ZN}}{3.33\theta}$$

---

*文档生成时间：2026-05-23*
