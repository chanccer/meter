function [wc, w0] = tunedADRC(p)
%TUNEDADRC  IMC-style ADRC+Smith auto-tune used by every bandwidth/preview
%   analysis script (bandwidth_sweep.m, adrc_pole_analysis.m). Single
%   source of truth: adrc_pole_analysis.m used to have these numbers
%   hand-copied from a prior bandwidth_sweep.m run, which silently went
%   stale if the scenario parameters ever changed. It now calls this
%   function directly instead.
%
%   Extends +sim/imcTune.m's theta_eff formula with a 0.5/fs_sample_hz
%   term for the sensor's own zero-order-hold lag (see tunedPID.m for the
%   same extension on the PID side).

    tau_s   = p.tau_us    * 1e-6;
    delay_s = p.delay_us  * 1e-6;
    dt_pid  = p.dt_pid_us * 1e-6;
    zoh_fs  = 0.5 / p.fs_sample_hz;

    theta_eff = delay_s + dt_pid/2 + zoh_fs;   % theta_plant predicted away by Smith
    wc = 1 / max(tau_s + theta_eff, 1e-9);
    w0 = 5 * wc;
end
