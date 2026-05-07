"""
simulate.py — Interactive Piezo PID Simulation GUI
Controllable parameters: plant (K, τ, θ), PID gains, feedback delay, disturbance, noise.
Disturbance types: high-freq sine, low-freq sine, periodic square wave.
Charts are exportable via the embedded matplotlib toolbar (PNG/PDF/SVG).
"""
from __future__ import annotations

import math
import tkinter as tk
from dataclasses import dataclass, field
from tkinter import ttk

import matplotlib
matplotlib.use("TkAgg")
import matplotlib.pyplot as plt
import numpy as np
from matplotlib.backends.backend_tkagg import FigureCanvasTkAgg, NavigationToolbar2Tk

# ---------------------------------------------------------------------------
# Simulation parameters dataclass
# ---------------------------------------------------------------------------

@dataclass
class SimParams:
    # Plant (FOPDT)
    K: float = 410.0        # static gain  nm/V
    tau_ms: float = 80.0    # time constant ms
    theta_ms: float = 10.0  # plant dead time ms

    # PID gains
    kp: float = 0.002
    ki: float = 0.027
    kd: float = 0.0

    # Additional feedback sensor delay (ms)
    delay_ms: float = 0.0

    # Target displacement
    target_nm: float = 1000.0

    # Disturbance
    dist_type: str = "none"   # none | high | low | periodic
    dist_amp_nm: float = 50.0
    dist_freq_hz: float = 10.0

    # Sensor noise RMS
    noise_nm: float = 5.0

    # Controller
    v_min: float = 0.0
    v_max: float = 5.0
    int_lim: float = 5.0    # integrator windup limit (V)

    # Simulation duration
    t_total_s: float = 2.0

    # Step-change time
    step_time_s: float = 0.1


# ---------------------------------------------------------------------------
# Simulation engine
# ---------------------------------------------------------------------------

DT_PLANT = 0.001   # 1 ms plant integration step (s)
DT_PID   = 0.050   # 50 ms PID update interval (s)


def make_disturbance(t: np.ndarray, p: SimParams) -> np.ndarray:
    dist = np.zeros_like(t)
    if p.dist_type == "none":
        return dist
    mask = t >= p.step_time_s
    if p.dist_type == "high":
        dist[mask] = p.dist_amp_nm * np.sin(2 * math.pi * p.dist_freq_hz * t[mask])
    elif p.dist_type == "low":
        dist[mask] = p.dist_amp_nm * np.sin(2 * math.pi * (p.dist_freq_hz / 10.0) * t[mask])
    elif p.dist_type == "periodic":
        dist[mask] = p.dist_amp_nm * np.sign(
            np.sin(2 * math.pi * p.dist_freq_hz * t[mask])
        )
    return dist


def run_sim(p: SimParams):
    """
    Discrete-time FOPDT plant + PI controller simulation.
    Returns (t, y_meas, v_out, error_arr, dist_arr) numpy arrays.
    """
    tau   = p.tau_ms / 1000.0
    theta = p.theta_ms / 1000.0
    delay = p.delay_ms / 1000.0

    n_steps = int(p.t_total_s / DT_PLANT) + 1
    t = np.linspace(0.0, p.t_total_s, n_steps)

    # Delay buffers (circular)
    plant_delay_len  = max(1, int(round(theta / DT_PLANT)))
    sensor_delay_len = max(1, int(round(delay / DT_PLANT)))

    plant_buf  = np.zeros(plant_delay_len)
    sensor_buf = np.zeros(sensor_delay_len)

    v_buf_idx = 0   # circular write index
    s_buf_idx = 0

    disturbance = make_disturbance(t, p)

    y      = np.zeros(n_steps)   # plant output (nm)
    y_meas = np.zeros(n_steps)   # measured output (after noise + sensor delay)
    v_arr  = np.zeros(n_steps)   # control voltage
    err_arr = np.zeros(n_steps)

    # PI state
    integral = 0.0
    prev_err = 0.0
    v_ctrl = 0.0

    # FOPDT state (Euler)
    y_state = 0.0

    pid_counter = 0

    for k in range(1, n_steps):
        # Plant input (delayed by theta)
        v_plant = plant_buf[v_buf_idx]
        plant_buf[v_buf_idx] = v_ctrl
        v_buf_idx = (v_buf_idx + 1) % plant_delay_len

        # Euler integration of first-order plant
        dy = (p.K * v_plant - y_state) / tau * DT_PLANT
        y_state += dy
        y[k] = y_state + disturbance[k]

        # Sensor measurement (noise + feedback delay)
        meas_noisy = y[k] + np.random.normal(0.0, p.noise_nm)
        sensor_buf[s_buf_idx] = meas_noisy
        s_buf_idx_read = (s_buf_idx + 1) % sensor_delay_len
        y_meas[k] = sensor_buf[s_buf_idx_read]
        s_buf_idx = (s_buf_idx + 1) % sensor_delay_len

        # Setpoint step
        setpoint = p.target_nm if t[k] >= p.step_time_s else 0.0

        # PID update (every DT_PID)
        pid_counter += 1
        if pid_counter >= int(round(DT_PID / DT_PLANT)):
            pid_counter = 0
            err = setpoint - y_meas[k]
            integral += err * DT_PID
            # Anti-windup clamp
            integral = max(-p.int_lim / max(p.ki, 1e-12),
                           min(p.int_lim / max(p.ki, 1e-12), integral))
            derivative = (err - prev_err) / DT_PID
            prev_err = err

            v_ctrl = p.kp * err + p.ki * integral + p.kd * derivative
            v_ctrl = max(p.v_min, min(p.v_max, v_ctrl))

        v_arr[k] = v_ctrl
        err_arr[k] = setpoint - y[k]

    return t, y_meas, y, v_arr, err_arr, disturbance


def imc_autotune(p: SimParams) -> tuple[float, float]:
    """Compute IMC PI gains from current plant params. Returns (kp, ki)."""
    K     = p.K
    tau   = p.tau_ms / 1000.0
    theta = p.theta_ms / 1000.0
    lam   = theta * 2.0   # default IMC lambda = 2*theta (balanced)
    kp = tau / (K * (lam + theta))
    ki = kp / tau
    return kp, ki


# ---------------------------------------------------------------------------
# GUI helpers
# ---------------------------------------------------------------------------

class SliderRow:
    """Label + Scale + Entry in a frame."""

    def __init__(self, parent, label: str, from_: float, to: float,
                 init: float, resolution: float, fmt: str = "{:.4g}",
                 on_change=None):
        self._fmt = fmt
        self._cb = on_change
        self.var = tk.DoubleVar(value=init)

        frame = tk.Frame(parent)
        frame.pack(fill=tk.X, padx=4, pady=1)

        tk.Label(frame, text=label, width=20, anchor="w").pack(side=tk.LEFT)
        self._scale = tk.Scale(
            frame, variable=self.var, from_=from_, to=to,
            orient=tk.HORIZONTAL, resolution=resolution,
            showvalue=False, length=160,
            command=self._on_scale,
        )
        self._scale.pack(side=tk.LEFT)
        self._entry = tk.Entry(frame, width=9, textvariable=self.var)
        self._entry.pack(side=tk.LEFT, padx=(4, 0))
        self._entry.bind("<Return>", self._on_entry)

    def _on_scale(self, _):
        if self._cb:
            self._cb()

    def _on_entry(self, _):
        if self._cb:
            self._cb()

    def get(self) -> float:
        return self.var.get()

    def set(self, v: float):
        self.var.set(v)


# ---------------------------------------------------------------------------
# Main Application
# ---------------------------------------------------------------------------

class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Piezo PID Simulation")
        self.resizable(True, True)
        self._build_ui()

    # ------------------------------------------------------------------
    # UI construction
    # ------------------------------------------------------------------

    def _build_ui(self):
        # Top-level paned window: controls (left) | plots (right)
        pane = tk.PanedWindow(self, orient=tk.HORIZONTAL, sashwidth=4)
        pane.pack(fill=tk.BOTH, expand=True)

        ctrl_outer = tk.Frame(pane, width=330)
        ctrl_outer.pack_propagate(False)
        pane.add(ctrl_outer, minsize=300)

        plot_frame = tk.Frame(pane)
        pane.add(plot_frame, minsize=500)

        # Scrollable control panel
        canvas = tk.Canvas(ctrl_outer, borderwidth=0)
        scrollbar = ttk.Scrollbar(ctrl_outer, orient=tk.VERTICAL, command=canvas.yview)
        canvas.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        self._ctrl = tk.Frame(canvas)
        ctrl_win = canvas.create_window((0, 0), window=self._ctrl, anchor="nw")

        def _on_frame_configure(e):
            canvas.configure(scrollregion=canvas.bbox("all"))
        self._ctrl.bind("<Configure>", _on_frame_configure)

        def _on_canvas_configure(e):
            canvas.itemconfig(ctrl_win, width=e.width)
        canvas.bind("<Configure>", _on_canvas_configure)

        self._build_controls()
        self._build_plots(plot_frame)
        self._build_statusbar()

    def _section(self, text: str):
        f = tk.LabelFrame(self._ctrl, text=text, padx=4, pady=2)
        f.pack(fill=tk.X, padx=4, pady=3)
        return f

    def _build_controls(self):
        # Plant parameters
        f = self._section("Plant (FOPDT)")
        self.s_K       = SliderRow(f, "K  (nm/V)",     10, 2000, 410,  10)
        self.s_tau     = SliderRow(f, "τ  (ms)",        5, 500,   80,   1)
        self.s_theta   = SliderRow(f, "θ  (ms)",        0, 200,   10,   1)

        # PID gains
        f = self._section("PID Gains")
        self.s_kp = SliderRow(f, "Kp",  0.0, 0.05, 0.002, 0.0001, fmt="{:.6f}")
        self.s_ki = SliderRow(f, "Ki",  0.0, 2.00, 0.027, 0.001,  fmt="{:.4f}")
        self.s_kd = SliderRow(f, "Kd",  0.0, 0.01, 0.000, 0.0001, fmt="{:.6f}")
        tk.Button(f, text="IMC Auto-tune", command=self._do_autotune).pack(pady=3)

        # Feedback delay
        f = self._section("Feedback Delay")
        self.s_delay = SliderRow(f, "Extra delay (ms)", 0, 500, 0, 5)

        # Target
        f = self._section("Setpoint")
        self.s_target = SliderRow(f, "Target (nm)", 100, 5000, 1000, 50)

        # Disturbance
        f = self._section("Disturbance")
        tk.Label(f, text="Type", anchor="w").pack(fill=tk.X)
        self.dist_var = tk.StringVar(value="none")
        combo = ttk.Combobox(
            f, textvariable=self.dist_var,
            values=["none", "high-freq sine", "low-freq sine", "periodic square"],
            state="readonly", width=18,
        )
        combo.pack(padx=4, pady=2)
        self.s_dist_amp  = SliderRow(f, "Amplitude (nm)", 0, 500,  50, 5)
        self.s_dist_freq = SliderRow(f, "Freq (Hz)",      0.1, 200, 10, 0.5)

        # Sensor noise
        f = self._section("Sensor Noise")
        self.s_noise = SliderRow(f, "RMS (nm)", 0, 50, 5, 0.5)

        # Simulation settings
        f = self._section("Simulation")
        self.s_t_total = SliderRow(f, "Duration (s)",  0.5, 10,  2.0, 0.5)
        self.s_step_t  = SliderRow(f, "Step time (s)", 0.0, 5.0, 0.1, 0.05)
        self.s_v_max   = SliderRow(f, "V max (V)",     1,   20,  5.0, 0.5)

        # Buttons
        bf = tk.Frame(self._ctrl)
        bf.pack(fill=tk.X, padx=4, pady=6)
        tk.Button(bf, text="▶  Run Simulation", command=self._run,
                  bg="#2a7ae2", fg="white", font=("", 11, "bold"),
                  padx=10, pady=4).pack(side=tk.LEFT, padx=4)
        tk.Button(bf, text="Reset", command=self._reset).pack(side=tk.LEFT)

    def _build_plots(self, parent):
        self._fig, axes = plt.subplots(2, 2, figsize=(9, 6))
        self._fig.subplots_adjust(hspace=0.4, wspace=0.35)
        self._ax_disp, self._ax_err, self._ax_volt, self._ax_dist = axes.flat

        for ax, title in zip(axes.flat, [
            "Displacement (nm)", "Positioning Error (nm)",
            "Control Voltage (V)", "Disturbance (nm)"
        ]):
            ax.set_title(title, fontsize=9)
            ax.set_xlabel("Time (s)", fontsize=8)
            ax.tick_params(labelsize=7)

        self._canvas = FigureCanvasTkAgg(self._fig, master=parent)
        self._canvas.get_tk_widget().pack(fill=tk.BOTH, expand=True)

        toolbar_frame = tk.Frame(parent)
        toolbar_frame.pack(fill=tk.X)
        self._toolbar = NavigationToolbar2Tk(self._canvas, toolbar_frame)
        self._toolbar.update()

    def _build_statusbar(self):
        self._status_var = tk.StringVar(value="Ready — press ▶ Run Simulation")
        bar = tk.Label(self, textvariable=self._status_var,
                       bd=1, relief=tk.SUNKEN, anchor=tk.W, padx=6)
        bar.pack(side=tk.BOTTOM, fill=tk.X)

    # ------------------------------------------------------------------
    # Actions
    # ------------------------------------------------------------------

    def _read_params(self) -> SimParams:
        dist_map = {
            "none": "none",
            "high-freq sine": "high",
            "low-freq sine": "low",
            "periodic square": "periodic",
        }
        return SimParams(
            K          = self.s_K.get(),
            tau_ms     = self.s_tau.get(),
            theta_ms   = self.s_theta.get(),
            kp         = self.s_kp.get(),
            ki         = self.s_ki.get(),
            kd         = self.s_kd.get(),
            delay_ms   = self.s_delay.get(),
            target_nm  = self.s_target.get(),
            dist_type  = dist_map.get(self.dist_var.get(), "none"),
            dist_amp_nm  = self.s_dist_amp.get(),
            dist_freq_hz = self.s_dist_freq.get(),
            noise_nm   = self.s_noise.get(),
            v_max      = self.s_v_max.get(),
            t_total_s  = self.s_t_total.get(),
            step_time_s = self.s_step_t.get(),
        )

    def _run(self):
        self._status_var.set("Simulating …")
        self.update_idletasks()
        try:
            p = self._read_params()
            t, y_meas, y_true, v_arr, err_arr, dist_arr = run_sim(p)

            # Convergence check: last 10 % of sim
            tail_start = int(0.9 * len(t))
            tail_err = err_arr[tail_start:]
            rms_err = float(np.sqrt(np.mean(tail_err ** 2))) if len(tail_err) else float("nan")
            converged = rms_err < 0.05 * p.target_nm

            self._update_plots(p, t, y_meas, y_true, v_arr, err_arr, dist_arr)
            status = (
                f"Done │ RMS error (last 10%): {rms_err:.1f} nm  "
                f"({'✓ converged' if converged else '✗ not converged — adjust gains'})"
            )
            self._status_var.set(status)
        except Exception as exc:
            self._status_var.set(f"Error: {exc}")

    def _update_plots(self, p, t, y_meas, y_true, v_arr, err_arr, dist_arr):
        for ax in (self._ax_disp, self._ax_err, self._ax_volt, self._ax_dist):
            ax.cla()

        # Displacement
        ax = self._ax_disp
        ax.plot(t, y_true, color="#aaaaaa", linewidth=0.8, label="True")
        ax.plot(t, y_meas, color="#2a7ae2", linewidth=1.0, label="Measured")
        ax.axhline(p.target_nm, color="red", linewidth=0.8, linestyle="--", label="Setpoint")
        ax.set_title("Displacement (nm)", fontsize=9)
        ax.set_xlabel("Time (s)", fontsize=8)
        ax.legend(fontsize=7, loc="lower right")
        ax.tick_params(labelsize=7)

        # Error
        ax = self._ax_err
        ax.plot(t, err_arr, color="#e24a2a", linewidth=1.0)
        ax.axhline(0, color="black", linewidth=0.5)
        ax.set_title("Positioning Error (nm)", fontsize=9)
        ax.set_xlabel("Time (s)", fontsize=8)
        ax.tick_params(labelsize=7)

        # Control voltage
        ax = self._ax_volt
        ax.plot(t, v_arr, color="#2aa42a", linewidth=1.0)
        ax.set_ylim(p.v_min - 0.1, p.v_max + 0.1)
        ax.set_title("Control Voltage (V)", fontsize=9)
        ax.set_xlabel("Time (s)", fontsize=8)
        ax.tick_params(labelsize=7)

        # Disturbance
        ax = self._ax_dist
        ax.plot(t, dist_arr, color="#aa2aaa", linewidth=1.0)
        ax.set_title("Disturbance (nm)", fontsize=9)
        ax.set_xlabel("Time (s)", fontsize=8)
        ax.tick_params(labelsize=7)

        self._fig.tight_layout(pad=2.0)
        self._canvas.draw()

    def _do_autotune(self):
        p = self._read_params()
        kp, ki = imc_autotune(p)
        self.s_kp.set(round(kp, 6))
        self.s_ki.set(round(ki, 4))
        self._status_var.set(
            f"IMC auto-tune: Kp={kp:.6f}  Ki={ki:.6f}  "
            f"(λ=2θ={2*p.theta_ms:.0f} ms)"
        )

    def _reset(self):
        defaults = SimParams()
        self.s_K.set(defaults.K)
        self.s_tau.set(defaults.tau_ms)
        self.s_theta.set(defaults.theta_ms)
        self.s_kp.set(defaults.kp)
        self.s_ki.set(defaults.ki)
        self.s_kd.set(defaults.kd)
        self.s_delay.set(defaults.delay_ms)
        self.s_target.set(defaults.target_nm)
        self.dist_var.set("none")
        self.s_dist_amp.set(defaults.dist_amp_nm)
        self.s_dist_freq.set(defaults.dist_freq_hz)
        self.s_noise.set(defaults.noise_nm)
        self.s_t_total.set(defaults.t_total_s)
        self.s_step_t.set(defaults.step_time_s)
        self.s_v_max.set(defaults.v_max)
        self._status_var.set("Parameters reset to defaults.")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    app = App()
    app.mainloop()
