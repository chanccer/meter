function gains = imcTune(p)
%IMCTUNE  IMC-PID / IMC-ADRC auto-tune for FOPDT plant.
%
%   gains = sim.imcTune(p)
%
%   The key insight: the IMC formula requires the TOTAL effective dead time
%   in the closed loop, which is the sum of ALL loop delays:
%
%       θ_eff = θ_plant + θ_sensor + DT_controller/2
%
%   where DT_controller/2 is the ZOH-equivalent delay introduced by a
%   discrete controller that updates every DT_controller seconds
%   (Åström & Hägglund 1995, Ch. 8).
%
%   Each term maps to a field in p:
%       θ_plant      ← p.theta_ms   (ms)   Piezo mechanical dead time
%       θ_sensor     ← p.delay_us   (µs)   Sensor / protocol feedback delay
%       DT/2         ← p.dt_pid_ms  (ms)   Controller update period
%
%   PID formulas (Rivera et al. 1986, λ = 2·θ_eff  → conservative):
%       Kp = (τ + θ_eff/2) / [K·(λ + θ_eff/2)]
%       Ki = Kp / (τ + θ_eff/2)
%       Kd = Kp · τ·θ_plant / (2τ + θ_plant)   [plant θ only — model-based]
%       N  = round((2τ + θ_plant) / θ_plant)
%
%   ADRC:
%       ω_c = 1 / (τ + θ_eff)
%       ω_0 = 5 · ω_c

    tau_s   = p.tau_ms   * 1e-3;    % plant time constant (s)
    theta_s = p.theta_us * 1e-6;    % plant dead time (s)
    delay_s = p.delay_us * 1e-6;    % sensor / protocol delay (s)
    dt_pid  = p.dt_pid_us * 1e-6;   % controller update period (s)

    % Total effective dead time seen by the IMC formula
    theta_eff = theta_s + delay_s + dt_pid / 2;

    % ── PID (IMC, λ = 2·θ_eff) ─────────────────────────────────────
    lam    = 2 * theta_eff;
    denom  = tau_s + theta_eff / 2;
    kp     = denom / (p.K * (lam + theta_eff / 2));
    ki     = kp / denom;
    % Kd uses θ_plant (the model dead time) — not θ_eff — because it
    % compensates the plant's structural zero, not the loop delays.
    kd     = kp * tau_s * theta_s / (2*tau_s + max(theta_s, 1e-9));
    n_filt = round((2*tau_s + theta_s) / max(theta_s, 1e-9));

    gains.PID.kp         = kp;
    gains.PID.ki         = ki;
    gains.PID.kd         = kd;
    gains.PID.d_filter_n = n_filt;

    % ── ADRC ────────────────────────────────────────────────────────
    % Smith predictor removes θ_plant from ESO's effective dead time,
    % enabling a higher bandwidth (predictor compensates plant dead time).
    useSmith = isfield(p, 'smith_adrc') && p.smith_adrc;
    if useSmith
        theta_eff_adrc = delay_s + dt_pid / 2;   % θ_plant predicted away
    else
        theta_eff_adrc = theta_eff;
    end
    wc = 1 / max(tau_s + theta_eff_adrc, 1e-6);
    gains.ADRC.adrc_wc = wc;
    gains.ADRC.adrc_w0 = 5 * wc;
end
