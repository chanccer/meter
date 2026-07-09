function p = defaultParams()
%DEFAULTPARAMS  Factory-default simulation parameters.
    p.K              = 410;    % nm/V  static gain
    p.tau_us         = 80000;  % µs    time constant
    p.theta_us       = 10000;  % µs    piezo mechanical dead time
    p.v_dead         = 0;      % V     dead-band voltage
    p.hysteresis_nm  = 0;      % nm    hysteresis offset
    p.noise          = 5;      % nm    sensor noise RMS
    p.ctrl_mode      = 'PID';
    p.kp             = 0.002;
    p.ki             = 0.027;
    p.kd             = 0.000;
    p.d_filter_n     = 20;     % D-term filter coefficient
    p.adrc_wc        = 20;     % rad/s controller bandwidth
    p.adrc_w0        = 100;    % rad/s ESO bandwidth
    p.smith_adrc     = 1;      % 1=Smith predictor ON, 0=standard ADRC
    p.prev_kp        = 0.001;  % V/nm      Preview-mode PI trim (feedforward does the heavy lifting)
    p.prev_ki        = 0.010;  % V/(nm·s)  Preview-mode PI trim integral gain
    p.delay_us       = 0;      % µs    sensor feedback delay
    p.fs_sample_hz   = 1000;   % Hz    UMD2 sensor sampling rate (default 1kHz, adjustable e.g. 10kHz)
    p.sp_dc          = 0;      % nm    base DC setpoint
    % Nx6 cell {Enable, Type, Amp(nm), Period(s), Start(s), Dur(s)}
    % Dur = 0 → active from Start until end of simulation
    p.setpoints      = {true, 'Step', 1000, 1.0, 0.1, 0.0};
    p.signals        = {};     % no disturbance by default
    p.v_max          = 5;      % V
    p.t_total        = 2.0;   % s
    p.dt_pid_us      = 50000; % µs  controller update period
    % Bouc-Wen hysteresis model (replaces simple offset when enabled)
    p.bw_enable      = false; % off by default
    p.bw_A           = 1.0;   % pre-yield slope
    p.bw_beta        = 0.5;   % energy dissipation shape
    p.bw_gamma       = 0.5;   % restoring shape
    p.bw_D           = 30;    % nm  max hysteretic displacement
end
