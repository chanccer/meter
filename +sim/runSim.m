function [t, yMeas, yTrue, vArr, errArr, distArr, spArr] = runSim(p)
%RUNSIM  Discrete-time FOPDT + PID/ADRC simulation.
%
%   Plant integration : Euler at DT_PLANT = 1 µs.
%   Controller update : every p.dt_pid_us µs  (default 50000 µs).
%   PID  : anti-windup integral, filtered D on measurement (no setpoint kick).
%   ADRC : 1st-order ESO with exact ZOH discretization (via matrix exponential).
%   Delays: circular buffers for plant dead time and sensor feedback delay.

    DT_PLANT = 1e-6;                    % s  plant integration step (1 µs)
    DT_PID   = p.dt_pid_us * 1e-6;     % s  controller update period

    tau_s   = p.tau_us   * 1e-6;
    theta_s = p.theta_us * 1e-6;
    delay_s = p.delay_us * 1e-6;

    nSteps = round(p.t_total / DT_PLANT) + 1;
    t = linspace(0, p.t_total, nSteps)';

    pBufLen = max(1, round(theta_s / DT_PLANT));
    sBufLen = max(1, round(delay_s / DT_PLANT));
    pBuf = zeros(1, pBufLen);
    sBuf = zeros(1, sBufLen);
    pIdx = 1;  sIdx = 1;

    distArr = sim.makeDisturbance(t, p);
    spArr   = sim.makeSetpoint(t, p);

    yTrue  = zeros(nSteps,1);
    yMeas  = zeros(nSteps,1);
    vArr   = zeros(nSteps,1);
    errArr = zeros(nSteps,1);

    % Shared state
    vCtrl    = 0;
    yState   = 0;
    pidCnt   = 0;
    prevVEff = 0;   % for hysteresis direction tracking

    useBW = isfield(p, 'bw_enable') && p.bw_enable;
    z_bw  = 0;   % Bouc-Wen hysteretic state

    % PID state
    integral  = 0;
    prevYMeas = 0;
    dFilt     = 0;

    % ADRC ESO state: z1 ≈ output, z2 ≈ total disturbance
    b0 = p.K / tau_s;   % [nm/(V·s)]
    z1 = 0;  z2 = 0;
    sp_prev = 0;         % previous setpoint for derivative feedforward

    useADRC  = strcmp(p.ctrl_mode, 'ADRC');
    useSmith = useADRC && isfield(p,'smith_adrc') && p.smith_adrc;

    % Precompute exact ZOH matrices for ESO (stable for any ω₀ and DT_PID)
    if useADRC
        w0_eso = p.adrc_w0;
        A_c    = [-2*w0_eso, 1; -w0_eso^2, 0];
        B_c    = [b0, 2*w0_eso; 0, w0_eso^2];
        Maug   = [A_c, B_c; zeros(2, 4)];
        Phi    = expm(Maug * DT_PID);
        Ad_eso = Phi(1:2, 1:2);
        Bd_eso = Phi(1:2, 3:4);
    end

    % Smith predictor state: dead-time-free plant model + delay buffer
    if useSmith
        yModel = 0;
        mBuf   = zeros(1, pBufLen);   % same delay as plant dead-time buffer
        mIdx   = 1;
        yMdel  = 0;                   % delayed model output (θ_plant ago)
    end

    for k = 2:nSteps
        % Plant dead-time buffer
        vPlant     = pBuf(pIdx);
        pBuf(pIdx) = vCtrl;
        pIdx       = mod(pIdx, pBufLen) + 1;

        % Dead-band
        vEff = max(0, vPlant - p.v_dead);

        % Hysteresis
        du = vEff - prevVEff;
        if useBW
            % Bouc-Wen incremental (n=1): dz = A·du - β|du|z - γ·du·|z|
            z_bw = z_bw + p.bw_A*du - p.bw_beta*abs(du)*z_bw - p.bw_gamma*du*abs(z_bw);
            hystComp = -p.bw_D * z_bw;
        else
            hystComp = double(du < 0) * (-p.hysteresis_nm);
        end
        prevVEff = vEff;

        % Euler integration: dy/dt = (K·vEff - y) / τ
        yState   = yState + (p.K * vEff - yState) / tau_s * DT_PLANT;
        yTrue(k) = yState + distArr(k) + hystComp;

        % Smith predictor: run dead-time-free model in parallel
        % (uses current vCtrl before the dead-time buffer, same dead-band)
        if useSmith
            vSmith     = max(0, vCtrl - p.v_dead);
            yModel     = yModel + (p.K * vSmith - yModel) / tau_s * DT_PLANT;
            yMdel      = mBuf(mIdx);
            mBuf(mIdx) = yModel;
            mIdx       = mod(mIdx, pBufLen) + 1;
        end

        % Sensor: noise + feedback delay
        noisy      = yTrue(k) + p.noise * randn();
        sBuf(sIdx) = noisy;
        sIdxRead   = mod(sIdx, sBufLen) + 1;
        yMeas(k)   = sBuf(sIdxRead);
        sIdx       = sIdxRead;

        sp = spArr(k);

        % Controller update every DT_PID
        pidCnt = pidCnt + 1;
        if pidCnt >= round(DT_PID / DT_PLANT)
            pidCnt = 0;
            yM  = yMeas(k);
            err = sp - yM;

            if useADRC
                % Smith correction: y_smith = y_meas + (model_now - model_delayed)
                % removes θ_plant from ESO's effective dead time
                if useSmith
                    yEso = yM + (yModel - yMdel);
                else
                    yEso = yM;
                end
                % Exact ZOH ESO — stable for any ω₀ and DT_PID
                z     = Ad_eso * [z1; z2] + Bd_eso * [vCtrl; yEso];
                z1    = z(1);  z2 = z(2);
                % Setpoint derivative feedforward: cancels first-order tracking lag
                % u0 += ṙ  →  closed-loop ≈ 1 instead of ω_c/(s+ω_c)
                sp_dot = (sp - sp_prev) / DT_PID;   % nm/s
                u0    = p.adrc_wc * (sp - z1) + sp_dot;
                vCtrl = (u0 - z2) / b0;
                sp_prev = sp;
            else
                % PID with anti-windup and filtered D on measurement
                integral = integral + err * DT_PID;
                if p.ki > 0
                    lim      = p.v_max / p.ki;
                    integral = max(-lim, min(lim, integral));
                end
                N = p.d_filter_n;
                if N > 0
                    dFilt = dFilt / (1 + N*DT_PID) + ...
                            p.kd * N / (1 + N*DT_PID) * (prevYMeas - yM);
                else
                    dFilt = 0;
                end
                vCtrl = p.kp*err + p.ki*integral + dFilt;
            end

            prevYMeas = yM;
            vCtrl = max(0, min(p.v_max, vCtrl));
        end

        vArr(k)   = vCtrl;
        errArr(k) = sp - yTrue(k);
    end
end
