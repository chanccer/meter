function cfg = analysisConfig()
%ANALYSISCONFIG  Single source of truth for every tunable parameter used by
%   the bandwidth/preview analysis scripts (bandwidth_sweep.m,
%   bandwidth_sweep_nature.m, bandwidth_sweep_phase_nature.m,
%   adrc_pole_analysis.m, waveform_tracking_nature_all.m,
%   waveform_tracking_nature_split.m) and the simulated hardware-style demo
%   figures (lut_sweep_nature.m, step_response_nature.m,
%   convergence_nature.m). Nothing in those scripts should hardcode a
%   scenario's fs/dt/theta/delay/tau, the plant gain/voltage limit/noise,
%   the sweep frequencies, or an ADRC/PID gain — everything is either read
%   from here, or computed at runtime from what's read from here (see
%   +sim/tunedPID.m, +sim/tunedADRC.m).
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

    % ---- controllers compared in the time-domain waveform figures ----
    % (waveform_tracking_nature_all.m / _split.m). This is the ONLY place
    % that lists which controllers appear and in what order -- the scripts
    % render one column per entry here, so this is not hardcoded to
    % "PID on the left, Preview on the right": reorder, add, or remove an
    % entry and the figure follows. An entry whose ctrl_mode is 'ADRC' is
    % automatically skipped for any scenario with hasADRC=false (see the
    % per-scenario ADRC numerical-limitation note below).
    cfg.waveformControllers = struct( ...
        'name',      {'PID',  'ADRC', 'Preview'}, ...
        'ctrl_mode', {'PID',  'ADRC', 'Preview'}, ...
        'lineStyle', {'-',    '--',   '-.'});

    % ---- LUT hysteresis sweep (lut_sweep_nature.m) ----
    % Simulated bidirectional quasi-static voltage sweep through the
    % Bouc-Wen hysteresis model in +sim/runSim.m (bw_enable branch).
    % bw_D is chosen (not fit to any measured dataset) to produce a
    % visually clear loop at this K/voltage-range scale -- this is
    % simulated demonstration data, not a measurement, and is captioned
    % as such.
    cfg.lutSweep = struct( ...
        'vStep',        0.1, ...   % V, sweep step size
        'vMax',         5,   ...   % V, sweep upper bound (sweep runs 0->vMax->0)
        'bw_A',         1.0, ...
        'bw_beta',      0.5, ...
        'bw_gamma',     0.5, ...
        'bw_D',         100, ...   % nm, hysteresis loop-width scale
        'settleCycles', 20);       % plant time constants to settle after each voltage step

    % ---- step-response identification demo (step_response_nature.m) ----
    % Simulates a voltage step through the (hysteresis-free) FOPDT plant,
    % adds sensor noise, then fits K/tau/theta back out via fminsearch
    % (no Optimization/Curve Fitting Toolbox required) to demonstrate that
    % the identification procedure recovers the ground-truth parameters
    % used elsewhere in this config, rather than claiming to identify an
    % unknown real system.
    cfg.stepResponse = struct( ...
        'deltaV_V',    2,     ...  % V, step size
        'noise_nm',    5,     ...  % nm RMS, simulated sensor noise
        'tTotal_s',    1.5e-4, ... % s, total simulated duration (>> tau+theta)
        'dt_s',        1e-6);      % s, sample period of the simulated step response

    % ---- point-to-point convergence (convergence_nature.m) ----
    % Simulates closed-loop PID and ADRC step responses to each target
    % using the real dt_pid_us=1000 loop rate (matching scenario B) and
    % the same Bouc-Wen hysteresis model as cfg.lutSweep, then counts
    % controller ticks until the response enters and stays within bandNm
    % of the target.
    %
    % Unlike the real-hardware Table 1, ADRC converges SLOWER than PID
    % here (maxIter is set generously to actually capture its settling
    % rather than clip it): ADRC's closed-loop bandwidth is lower than
    % PID's at this loop rate under the shared theta_eff-based
    % sim.tunedADRC() tuning (the same fact Tables 2/3 document from the
    % frequency-domain side), whereas on the real hardware ADRC's
    % advantage came from its Extended State Observer compensating actual
    % hysteresis in real time -- a real-time disturbance-rejection benefit
    % that a fixed, non-adaptive Bouc-Wen hysteresis model in simulation
    % does not reproduce. Both figure and paper text report this
    % difference honestly rather than re-tuning ADRC just to match the
    % real-hardware ranking.
    cfg.convergence = struct( ...
        'targets_nm',  [500 1000 1500], ...
        'bandNm',      5,     ...  % nm, convergence band (matches "SS RMS" band in Table 1)
        'dt_pid_us',   1000,  ...  % matches the real hardware loop rate (scenario B)
        'tau_us',      20,    ...
        'theta_us',    5,     ...
        'bw_enable',   true,  ...  % use the same Bouc-Wen hysteresis as cfg.lutSweep
        'maxIter',     500,   ...  % ticks to allow before giving up (ADRC needs several hundred here)
        'rmsCycles',   20);        % ticks used for the post-convergence steady-state RMS

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
    % plotWindowFrac = [startFrac endFrac] sets which portion of each
    % panel's simulated duration (0 = start of that row's simulation,
    % 1 = tTotal for that row) is actually shown on the x-axis in the
    % time-domain waveform figures -- e.g. [0.5 1] would zoom into just
    % the second half instead of the whole simulated span. [0 1] (the
    % default below) shows the full simulated range, matching the
    % previous hardcoded behaviour.

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
    s(1).plotWindowFrac = [0 1];

    s(2).name        = 'B_loop_rate';
    s(2).label       = 'B. 环路更新率瓶颈 (真实硬件 dt=1ms -> 1kHz)';
    s(2).title       = 'Scenario B: loop-rate bound';
    % Corrected 2026-07: the real hardware control loop actually runs at
    % dt_pid_us=1000 (1kHz), matching fs_sample_hz -- NOT the 50ms/20Hz
    % previously assumed here. At dt_pid_us=1000, ADRC+Smith is numerically
    % well-conditioned (b0*DT_PID ~ 2e4, nowhere near the ~1e6 threshold
    % that broke the ESO's exact-ZOH discretisation at the old 50ms value),
    % so hasADRC is now true. Because dt_pid_us now equals fs_sample_hz's
    % period, this scenario's loop-update-rate ceiling coincides with
    % scenario A's sampling-rate ceiling -- see the paper's Results for the
    % implication (the loop-update-rate is not an independent bottleneck on
    % this hardware, only a hypothetical one if the loop were slower).
    s(2).params      = struct('fs_sample_hz',1000, 'dt_pid_us',1000, ...
                               'theta_us',0, 'delay_us',0, 'tau_us',20);
    s(2).ampNm        = 300;   s(2).dcNm = 1000;   s(2).t0 = 0.02;
    s(2).sweepFreqHz  = logspace(log10(5),   log10(700), 14);
    s(2).normalHz     = 20;    s(2).limitHz = 150;
    s(2).hasADRC      = true;
    s(2).poleAnalysis = true;
    s(2).ceilingType  = 'nyquist_loop';
    s(2).plotWindowFrac = [0 1];

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
    s(3).plotWindowFrac = [0 1];

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
    s(4).plotWindowFrac = [0 1];

    cfg.scenarios = s;
end
