function [kp, ki] = tunedPID(p)
%TUNEDPID  IMC PI auto-tune used by every bandwidth/preview analysis script.
%   Single source of truth for this formula -- previously copy-pasted
%   independently into bandwidth_sweep.m, waveform_tracking_nature_all.m,
%   and waveform_tracking_nature_split.m; now all three call this.
%
%   Same theta_eff = theta_plant + theta_sensor + DT/2 as +sim/imcTune.m,
%   plus a 0.5/fs_sample_hz term for the sensor's own zero-order-hold lag
%   that imcTune() does not model (relevant whenever dt_pid_us is set much
%   faster than 1/fs_sample_hz, e.g. to isolate fs as the bottleneck).
%   lambda = 2*theta_eff, same conservative IMC default as imcTune.m.

    tau_s   = p.tau_us    * 1e-6;
    theta_s = p.theta_us  * 1e-6;
    delay_s = p.delay_us  * 1e-6;
    dt_pid  = p.dt_pid_us * 1e-6;
    zoh_fs  = 0.5 / p.fs_sample_hz;

    theta_eff = theta_s + delay_s + dt_pid/2 + zoh_fs;
    lam    = 2 * theta_eff;
    denom  = tau_s + theta_eff/2;
    kp     = denom / (p.K * (lam + theta_eff/2));
    ki     = kp / denom;
end
