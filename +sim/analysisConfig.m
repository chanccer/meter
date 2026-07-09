function cfg = analysisConfig()
%ANALYSISCONFIG  Single source of truth for every tunable parameter used by
%   the bandwidth/preview analysis scripts (bandwidth_sweep.m,
%   bandwidth_sweep_nature.m, bandwidth_sweep_phase_nature.m,
%   adrc_pole_analysis.m, waveform_tracking_nature_all.m,
%   waveform_tracking_nature_split.m). Nothing in those scripts should
%   hardcode a scenario's fs/dt/theta/delay/tau, the plant gain/voltage
%   limit/noise, the sweep frequencies, or an ADRC/PID gain — everything
%   is either read from here, or computed at runtime from what's read
%   from here (see +sim/tunedPID.m, +sim/tunedADRC.m).
%
%   To change how a scenario is defined, or add a fifth scenario, this is
%   the only file that needs editing — every downstream script (and every
%   figure/table in the paper) picks the change up automatically the next
%   time it's rerun.

    % ---- shared plant / simulation parameters (same for every scenario) ----
    cfg.plant = struct( ...
        'K',             410, ...   % nm/V, identified static gain
        'v_max',         5,   ...   % V, actuator voltage limit
        'noise',         0,   ...   % nm RMS, 0 = isolate the algorithmic bandwidth
        'hysteresis_nm', 0);        % nm, 0 = isolate the algorithmic bandwidth

    % ---- frequency-sweep protocol (bandwidth_sweep.m) ----
    cfg.sweep = struct( ...
        'nCyclesSettle',  5, ...   % periods discarded as transient before fitting
        'nCyclesMeasure', 5);      % periods used for the sine-fit

    % ---- time-domain waveform cycle counts (shared across all 4 scenarios) ----
    cfg.waveformCycles.normal = struct('sine', 4, 'square', 3);
    cfg.waveformCycles.limit  = struct('sine', 6, 'square', 5);

    % ---- per-scenario definitions ----
    % ceilingType selects which formula computes the theoretical ceiling
    % plotted in the gain-vs-frequency figure:
    %   'nyquist_fs'   -> params.fs_sample_hz / 2
    %   'nyquist_loop' -> (1 / (params.dt_pid_us*1e-6)) / 2
    %   'actuator_bw'  -> 1 / (2*pi*params.tau_us*1e-6)
    %   'none'         -> no natural corner frequency (pure delay case)
    % poleAnalysis flags the scenarios discussed in the ADRC closed-loop
    % pole-analysis section of the paper (adrc_pole_analysis.m); it is a
    % scientific choice (which scenarios exhibit the "ADRC underperforms
    % PID" phenomenon worth explaining), not something to infer automatically.

    s = struct([]);

    s(1).name        = 'A_sampling_rate';
    s(1).label       = 'A. 采样率瓶颈 (fs=1kHz, Nyquist=500Hz)';
    s(1).title       = 'Scenario A: sampling-rate bound';
    % dt_pid_us is deliberately fast (10us, NOT tied to the 1ms sensor
    % period): the controller itself must be a non-issue so that
    % fs_sample_hz's own zero-order-hold (a fresh position value only
    % every 1/fs) is the only thing being isolated.
    s(1).params      = struct('fs_sample_hz',1000, 'dt_pid_us',10, ...
                               'theta_us',0, 'delay_us',0, 'tau_us',20);
    s(1).ampNm        = 300;   s(1).dcNm = 1000;   s(1).t0 = 0.02;
    s(1).sweepFreqHz  = logspace(log10(5),   log10(700), 14);
    s(1).normalHz     = 20;    s(1).limitHz = 150;
    s(1).hasADRC      = true;
    s(1).poleAnalysis = true;
    s(1).ceilingType  = 'nyquist_fs';

    s(2).name        = 'B_loop_rate';
    s(2).label       = 'B. 环路更新率瓶颈 (真实硬件 dt=50ms -> 20Hz)';
    s(2).title       = 'Scenario B: loop-rate bound';
    s(2).params      = struct('fs_sample_hz',1000, 'dt_pid_us',50000, ...
                               'theta_us',0, 'delay_us',0, 'tau_us',20);
    s(2).ampNm        = 300;   s(2).dcNm = 1000;   s(2).t0 = 0.2;
    s(2).sweepFreqHz  = logspace(log10(0.5), log10(15), 14);
    s(2).normalHz     = 2;     s(2).limitHz = 11;
    % ADRC+Smith is numerically invalid here: at tau_us=20 & dt_pid_us=50000,
    % b0*DT_PID = (K/tau)*DT_PID ~ 1e6, which pushes the ESO's exact-ZOH
    % discretisation (expm(Maug*DT_PID) in +sim/runSim.m) into numerical
    % ill-conditioning and the controller fails to converge. This is a
    % genuine limitation of the current ADRC implementation, not a config
    % mistake -- see FIGURE_REPRODUCTION_GUIDE.md / the paper's Limitations.
    s(2).hasADRC      = false;
    s(2).poleAnalysis = false;
    s(2).ceilingType  = 'nyquist_loop';

    s(3).name        = 'C_feedback_delay';
    s(3).label       = 'C. 反馈延迟瓶颈 (delay\_us=2ms, theta\_protocol 式的传感器延迟)';
    s(3).title       = 'Scenario C: feedback-delay bound';
    s(3).params      = struct('fs_sample_hz',10000, 'dt_pid_us',10, ...
                               'theta_us',0, 'delay_us',2000, 'tau_us',20);
    s(3).ampNm        = 300;   s(3).dcNm = 1000;   s(3).t0 = 0.02;
    s(3).sweepFreqHz  = logspace(log10(3),   log10(400), 14);
    s(3).normalHz     = 8;     s(3).limitHz = 45;
    s(3).hasADRC      = true;
    s(3).poleAnalysis = true;
    s(3).ceilingType  = 'none';

    s(4).name        = 'D_actuator_bandwidth';
    s(4).label       = 'D. 执行器本征带宽瓶颈 (tau=20us -> ~8kHz)';
    s(4).title       = 'Scenario D: actuator-bandwidth bound';
    s(4).params      = struct('fs_sample_hz',200000, 'dt_pid_us',1, ...
                               'theta_us',0, 'delay_us',0, 'tau_us',20);
    s(4).ampNm        = 800;   s(4).dcNm = 1000;   s(4).t0 = 0.001;
    s(4).sweepFreqHz  = logspace(log10(100), log10(25000), 16);
    s(4).normalHz     = 1000;  s(4).limitHz = 17000;
    s(4).hasADRC      = true;
    s(4).poleAnalysis = false;
    s(4).ceilingType  = 'actuator_bw';

    cfg.scenarios = s;
end
