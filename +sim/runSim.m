function [t, yMeas, yTrue, vArr, errArr, distArr, spArr] = runSim(p)
%RUNSIM  Discrete-time FOPDT + PID/ADRC/Preview simulation.
%
%   Plant integration : Euler at DT_PLANT = 1 µs.
%   Sensor sampling   : UMD2 samples position every 1/p.fs_sample_hz s
%                       (zero-order hold between samples; default 1 kHz).
%   Controller update : every p.dt_pid_us µs  (default 50000 µs).
%   PID     : anti-windup integral, filtered D on measurement (no setpoint kick).
%   ADRC    : 1st-order ESO with exact ZOH discretization (via matrix exponential).
%   Preview : exact FOPDT-inversion feedforward using the known future
%             setpoint (valid only because the whole trajectory is
%             precomputed) + a small PI trim. Unlike PID/ADRC it is not a
%             reactive controller — see p.prev_kp / p.prev_ki. The trim's
%             error is measurement minus a delay-matched internal-model
%             prediction (not minus the raw setpoint) — see the "Preview
%             trim reference model" block below for why.
%   Delays: circular buffers for plant dead time and sensor feedback delay.

    DT_PLANT = 1e-6;                    % s  plant integration step (1 µs)
    DT_PID   = p.dt_pid_us * 1e-6;     % s  controller update period
    DT_SAMPLE = 1 / p.fs_sample_hz;    % s  UMD2 sensor sampling period

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

    sampPeriod = max(1, round(DT_SAMPLE / DT_PLANT));  % plant steps per ADC sample
    sampCnt    = sBufLen;   % lead the controller tick by exactly sBufLen steps, so a
                            % fresh acquisition finishes transiting the sensor-delay
                            % buffer (sBuf) right as the controller reads it. Aligning
                            % the two counters' phase any other way (e.g. both starting
                            % at 0) makes the controller always consume the *previous*
                            % period's sample instead of the current one whenever
                            % fs_sample_hz's period equals dt_pid_us — silently adding
                            % up to a full extra sample period of staleness on top of
                            % the intended (tiny) sensor transport delay.
    sampleHold = 0;         % last acquired (noisy) sample

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

    useADRC    = strcmp(p.ctrl_mode, 'ADRC');
    useSmith   = useADRC && isfield(p,'smith_adrc') && p.smith_adrc;
    usePreview = strcmp(p.ctrl_mode, 'Preview');

    % Preview controller: exact FOPDT inversion using the already-known
    % future setpoint, valid because the whole trajectory (spArr) is
    % precomputed above — unlike PID/ADRC, which only ever see r[k] and
    % r[k-1] as they arrive. Discrete plant at the controller's own rate:
    %   y[n] = a·y[n-1] + b·u[n-1-d],  a = e^{-DT_PID/τ}, b = K(1-a),
    %   d = round(θ/DT_PID)
    % Forcing y[n] ≡ r[n] and solving for u gives
    %   u[m] = (r[m+1+d] - a·r[m+d]) / b
    % i.e. the voltage needed "now" depends on the setpoint d+1 controller
    % periods into the future — the preview horizon is exactly θ + DT_PID.
    if usePreview
        a_prev   = exp(-DT_PID / tau_s);
        b_prev   = p.K * (1 - a_prev);
        d_prev   = max(0, round(theta_s / DT_PID));
        nPidStep = max(1, round(DT_PID / DT_PLANT));
    end

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

    % Preview trim reference model: a parallel "exact" simulation of the
    % same discrete plant the feedforward inverts, driven by the actual
    % applied voltage and delayed through a buffer the same length as the
    % sensor-delay buffer (sBufLen). The trim compares yMeas against THIS
    % delay-matched prediction instead of against the raw setpoint —
    % otherwise it "double-corrects" the transient gap the feedforward is
    % already closing on its own (most visible right after a step/edge:
    % naive r-yMeas trim overshoots ~19%, this drops it to ~2%, the rest
    % being unavoidable voltage saturation on the sharpest edges).
    if usePreview
        yModelPV    = 0;
        mBufPV      = zeros(1, sBufLen);
        mIdxPV      = 1;
        modelHoldPV = 0;
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

        % Preview trim reference model (same discretization the
        % feedforward inversion assumes; no dead-band compensation,
        % matching the feedforward, so the trim still catches dead-band
        % mismatch as a genuine model error rather than hiding it)
        if usePreview
            yModelPV = yModelPV + (p.K * vCtrl - yModelPV) / tau_s * DT_PLANT;
        end

        % Sensor: UMD2 samples (+noise) at fs_sample_hz, held (ZOH) between
        % samples, then delayed through the feedback dead-time buffer.
        sampCnt = sampCnt + 1;
        if sampCnt >= sampPeriod
            sampCnt    = 0;
            sampleHold = yTrue(k) + p.noise * randn();
            if usePreview
                modelHoldPV = yModelPV;   % refresh in lockstep with sampleHold
            end
        end
        sBuf(sIdx) = sampleHold;
        sIdxRead   = mod(sIdx, sBufLen) + 1;
        yMeas(k)   = sBuf(sIdxRead);
        sIdx       = sIdxRead;

        if usePreview
            mBufPV(mIdxPV)  = modelHoldPV;
            mIdxReadPV      = mod(mIdxPV, sBufLen) + 1;
            yModelDelayedPV = mBufPV(mIdxReadPV);
            mIdxPV          = mIdxReadPV;
        end

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
            elseif usePreview
                % Exact inverse-model feedforward using r[k+d+1], r[k+d]
                % (known future setpoint) + small PI trim for whatever the
                % FOPDT model doesn't capture (hysteresis, creep, noise).
                % The trim's error is yModelDelayedPV - yM, NOT sp - yM:
                % comparing against the reference model (delayed the same
                % way yMeas is) means the trim only reacts to genuine
                % model mismatch, not to the transient the feedforward is
                % already resolving on its own — see the reference-model
                % block above.
                kD  = min(k + d_prev*nPidStep,     nSteps);
                kD1 = min(k + (d_prev+1)*nPidStep, nSteps);
                uFF = (spArr(kD1) - a_prev*spArr(kD)) / b_prev;

                errTrim = yModelDelayedPV - yM;
                integral = integral + errTrim * DT_PID;
                if p.prev_ki > 0
                    lim      = p.v_max / p.prev_ki;
                    integral = max(-lim, min(lim, integral));
                end
                vCtrl = uFF + p.prev_kp*errTrim + p.prev_ki*integral;
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
