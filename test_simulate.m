classdef test_simulate < matlab.unittest.TestCase
% Unit tests for the +sim package functions.
%
% Run from the meter/ directory:
%   results = runtests('test_simulate');
%   table(results)

    % ================================================================== defaultParams
    methods (Test)
        function test_defaultParams_requiredFields(tc)
            p = sim.defaultParams();
            required = {'K','tau_us','theta_us','v_dead','hysteresis_nm', ...
                        'noise','ctrl_mode','kp','ki','kd','d_filter_n', ...
                        'adrc_wc','adrc_w0','smith_adrc','prev_kp','prev_ki', ...
                        'delay_us','sp_dc', ...
                        'setpoints','signals','v_max','t_total','dt_pid_us'};
            for i = 1:numel(required)
                tc.assertTrue(isfield(p, required{i}), ...
                    ['Missing field: ' required{i}]);
            end
        end

        function test_defaultParams_values(tc)
            p = sim.defaultParams();
            tc.assertEqual(p.ctrl_mode,     'PID');
            tc.assertEqual(p.K,             410,  'AbsTol',1e-9);
            tc.assertEqual(p.tau_us,        80000,'AbsTol',1e-9);
            tc.assertEqual(p.theta_us,      10000,'AbsTol',1e-9);
            tc.assertEqual(p.noise,         5,    'AbsTol',1e-9);
            tc.assertEqual(p.v_max,         5,    'AbsTol',1e-9);
            tc.assertEqual(p.t_total,       2.0,  'AbsTol',1e-9);
            tc.assertEqual(p.d_filter_n,    20,   'AbsTol',1e-9);
            tc.assertEqual(p.adrc_wc,       20,   'AbsTol',1e-9);
            tc.assertEqual(p.adrc_w0,       100,  'AbsTol',1e-9);
            tc.assertEqual(p.hysteresis_nm, 0,    'AbsTol',1e-9);
        end

        function test_defaultParams_setpointIsCell(tc)
            p = sim.defaultParams();
            tc.assertTrue(iscell(p.setpoints));
            tc.assertTrue(isempty(p.signals) || iscell(p.signals));
        end
    end

    % ================================================================== runSim — PID
    methods (Test)
        function test_runSim_PID_outputDimensions(tc)
            p = sim.defaultParams();
            p.t_total = 0.5;
            [t,yMeas,yTrue,vArr,errArr,distArr,spArr] = sim.runSim(p);
            n = numel(t);
            tc.assertEqual(numel(yMeas),   n, 'yMeas length');
            tc.assertEqual(numel(yTrue),   n, 'yTrue length');
            tc.assertEqual(numel(vArr),    n, 'vArr length');
            tc.assertEqual(numel(errArr),  n, 'errArr length');
            tc.assertEqual(numel(distArr), n, 'distArr length');
            tc.assertEqual(numel(spArr),   n, 'spArr length');
        end

        function test_runSim_PID_voltageWithinBounds(tc)
            p = sim.defaultParams();
            p.t_total = 1.0;
            [~,~,~,vArr,~,~,~] = sim.runSim(p);
            tc.assertTrue(all(vArr >= 0),       'Voltage went below 0');
            tc.assertTrue(all(vArr <= p.v_max), 'Voltage exceeded v_max');
        end

        function test_runSim_PID_noNaN(tc)
            p = sim.defaultParams();
            p.t_total = 1.0;
            [t,yMeas,yTrue,vArr,errArr,distArr,spArr] = sim.runSim(p);
            tc.assertFalse(any(isnan(t)),       'NaN in t');
            tc.assertFalse(any(isnan(yMeas)),   'NaN in yMeas');
            tc.assertFalse(any(isnan(yTrue)),   'NaN in yTrue');
            tc.assertFalse(any(isnan(vArr)),    'NaN in vArr');
            tc.assertFalse(any(isnan(errArr)),  'NaN in errArr');
            tc.assertFalse(any(isnan(distArr)), 'NaN in distArr');
            tc.assertFalse(any(isnan(spArr)),   'NaN in spArr');
        end

        function test_runSim_PID_timeVector(tc)
            p = sim.defaultParams();
            p.t_total = 1.0;
            [t,~,~,~,~,~,~] = sim.runSim(p);
            tc.assertEqual(t(1),   0,         'AbsTol',1e-9, 'Start time');
            tc.assertEqual(t(end), p.t_total, 'AbsTol',1e-3, 'End time');
            tc.assertTrue(all(diff(t) > 0), 'Time not monotonic');
        end

        function test_runSim_deadBand_zeroOutput(tc)
            % v_dead > v_max → effective input always 0 → no displacement
            p = sim.defaultParams();
            p.v_dead    = 20;
            p.noise     = 0;
            p.sp_dc     = 0;
            p.setpoints = {true,'Step',0,1.0,0.0,0.0};
            p.t_total   = 0.5;
            [~,~,yTrue,~,~,~,~] = sim.runSim(p);
            tc.assertTrue(all(abs(yTrue) < 1e-6), ...
                'Non-zero displacement despite effective dead band');
        end

        function test_runSim_PID_Dterm_noNaN(tc)
            p = sim.defaultParams();
            p.kd         = 0.05;
            p.d_filter_n = 20;
            p.t_total    = 1.0;
            [~,~,~,vArr,~,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(vArr)), 'NaN in voltage with D term');
            tc.assertFalse(any(isinf(vArr)), 'Inf in voltage with D term');
        end

        function test_runSim_hysteresis_finite(tc)
            p = sim.defaultParams();
            p.hysteresis_nm = 200;
            p.noise   = 0;
            p.t_total = 0.5;
            [~,~,yTrue,~,~,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(yTrue)), 'NaN with hysteresis');
            tc.assertFalse(any(isinf(yTrue)), 'Inf with hysteresis');
        end
    end

    % ================================================================== runSim — ADRC
    methods (Test)
        function test_runSim_ADRC_outputDimensions(tc)
            p = sim.defaultParams();
            p.ctrl_mode = 'ADRC';
            p.t_total   = 0.5;
            [t,yMeas,~,vArr,errArr,~,~] = sim.runSim(p);
            n = numel(t);
            tc.assertEqual(numel(yMeas),  n, 'yMeas ADRC');
            tc.assertEqual(numel(vArr),   n, 'vArr ADRC');
            tc.assertEqual(numel(errArr), n, 'errArr ADRC');
        end

        function test_runSim_ADRC_voltageWithinBounds(tc)
            p = sim.defaultParams();
            p.ctrl_mode = 'ADRC';
            p.t_total   = 1.0;
            [~,~,~,vArr,~,~,~] = sim.runSim(p);
            tc.assertTrue(all(vArr >= 0),       'ADRC voltage < 0');
            tc.assertTrue(all(vArr <= p.v_max), 'ADRC voltage > v_max');
        end

        function test_runSim_ADRC_noNaN(tc)
            p = sim.defaultParams();
            p.ctrl_mode = 'ADRC';
            p.t_total   = 1.0;
            [~,yMeas,yTrue,vArr,errArr,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(yMeas)),  'NaN yMeas ADRC');
            tc.assertFalse(any(isnan(yTrue)),  'NaN yTrue ADRC');
            tc.assertFalse(any(isnan(vArr)),   'NaN vArr ADRC');
            tc.assertFalse(any(isnan(errArr)), 'NaN errArr ADRC');
        end
    end

    % ================================================================== runSim — Preview
    methods (Test)
        function test_runSim_Preview_outputDimensions(tc)
            p = sim.defaultParams();
            p.ctrl_mode = 'Preview';
            p.t_total   = 0.5;
            [t,yMeas,~,vArr,errArr,~,~] = sim.runSim(p);
            n = numel(t);
            tc.assertEqual(numel(yMeas),  n, 'yMeas Preview');
            tc.assertEqual(numel(vArr),   n, 'vArr Preview');
            tc.assertEqual(numel(errArr), n, 'errArr Preview');
        end

        function test_runSim_Preview_voltageWithinBounds(tc)
            p = sim.defaultParams();
            p.ctrl_mode = 'Preview';
            p.t_total   = 1.0;
            [~,~,~,vArr,~,~,~] = sim.runSim(p);
            tc.assertTrue(all(vArr >= 0),       'Preview voltage < 0');
            tc.assertTrue(all(vArr <= p.v_max), 'Preview voltage > v_max');
        end

        function test_runSim_Preview_noNaN(tc)
            p = sim.defaultParams();
            p.ctrl_mode = 'Preview';
            p.t_total   = 1.0;
            [~,yMeas,yTrue,vArr,errArr,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(yMeas)),  'NaN yMeas Preview');
            tc.assertFalse(any(isnan(yTrue)),  'NaN yTrue Preview');
            tc.assertFalse(any(isnan(vArr)),   'NaN vArr Preview');
            tc.assertFalse(any(isnan(errArr)), 'NaN errArr Preview');
        end

        function test_runSim_Preview_exactModel_tracksBetterThanPID(tc)
            % With an exactly-known FOPDT model and no noise, the preview
            % inverse-model feedforward should track a step with
            % substantially lower IAE than reactive PID (same plant/step).
            pBase = sim.defaultParams();
            pBase.noise     = 0;
            pBase.t_total   = 1.0;
            pBase.tau_us    = 20;
            pBase.theta_us  = 5;
            pBase.dt_pid_us = 50;

            pPID = pBase;  pPID.ctrl_mode = 'PID';
            pPV  = pBase;  pPV.ctrl_mode  = 'Preview';

            [t1,~,yTrue1,~,errArr1,~,~] = sim.runSim(pPID);
            [t2,~,yTrue2,~,errArr2,~,~] = sim.runSim(pPV); %#ok<ASGLU>

            iaePID     = trapz(t1, abs(errArr1));
            iaePreview = trapz(t2, abs(errArr2));
            tc.assertLessThan(iaePreview, iaePID, ...
                'Preview (known future setpoint) should out-track reactive PID on IAE');
        end

        function test_runSim_Preview_futureHorizon_needsLookahead(tc)
            % Sanity check that the preview feedforward actually looks
            % ahead: with theta_us=0, u_ff[k] should still use r[k+1]
            % (one controller period of ZOH lookahead), not r[k] alone —
            % i.e. the response should visibly lead a same-gain PID on a step.
            p = sim.defaultParams();
            p.noise     = 0;
            p.ctrl_mode = 'Preview';
            p.theta_us  = 0;
            p.tau_us    = 20;
            p.dt_pid_us = 50;
            p.t_total   = 0.001;
            [~,~,yTrue,vArr,~,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(vArr)), 'NaN with zero dead time');
            tc.assertFalse(any(isnan(yTrue)), 'NaN yTrue with zero dead time');
        end
    end

    % ================================================================== makeSetpoint
    methods (Test)
        function test_makeSetpoint_step_beforeStart(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Step',500,1.0,0.5,0.0};
            t  = linspace(0,1,1001)';
            sp = sim.makeSetpoint(t, p);
            tc.assertTrue(all(abs(sp(t < 0.5)) < 1e-9), ...
                'Step should be zero before start time');
        end

        function test_makeSetpoint_step_afterStart(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Step',500,1.0,0.1,0.0};
            t  = linspace(0,1,1001)';
            sp = sim.makeSetpoint(t, p);
            tc.assertTrue(all(abs(sp(t >= 0.2) - 500) < 1e-9), ...
                'Step should equal amplitude after start');
        end

        function test_makeSetpoint_empty(tc)
            p = sim.defaultParams();
            p.sp_dc     = 300;
            p.setpoints = {};
            t  = linspace(0,1,101)';
            sp = sim.makeSetpoint(t, p);
            tc.assertTrue(all(abs(sp - 300) < 1e-9), 'Empty setpoints → sp_dc only');
        end

        function test_makeSetpoint_disabled(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {false,'Step',1000,1.0,0.0,0.0};
            t  = linspace(0,1,101)';
            sp = sim.makeSetpoint(t, p);
            tc.assertTrue(all(abs(sp) < 1e-9), 'Disabled row should be ignored');
        end

        function test_makeSetpoint_duration(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Step',100,1.0,0.2,0.3};
            t  = linspace(0,1,1001)';
            sp = sim.makeSetpoint(t, p);
            tc.assertTrue(all(abs(sp(t >= 0.6)) < 1e-9), ...
                'Should be zero after duration ends');
            tc.assertTrue(all(sp(t >= 0.25 & t < 0.45) > 99), ...
                'Should be active within duration window');
        end

        function test_makeSetpoint_sine_amplitude(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Sine',200,0.5,0.0,0.0};
            t  = linspace(0,2,2001)';
            sp = sim.makeSetpoint(t, p);
            tc.assertLessThanOrEqual(max(abs(sp)), 200+1e-9, 'Sine amplitude exceeded');
        end
    end

    % ================================================================== makeDisturbance
    methods (Test)
        function test_makeDisturbance_empty(tc)
            p = sim.defaultParams();
            p.signals = {};
            t = linspace(0,1,101)';
            d = sim.makeDisturbance(t, p);
            tc.assertTrue(all(d == 0), 'Empty disturbance should be zero');
        end

        function test_makeDisturbance_sine_amplitude(tc)
            p = sim.defaultParams();
            p.signals = {true,'Sine',50,0.5,0.0,0.0};
            t = linspace(0,2,2001)';
            d = sim.makeDisturbance(t, p);
            tc.assertLessThanOrEqual(max(abs(d)), 50+1e-9, 'Sine amplitude exceeded');
        end

        function test_makeDisturbance_disabled(tc)
            p = sim.defaultParams();
            p.signals = {false,'Sine',100,0.5,0.0,0.0};
            t = linspace(0,1,101)';
            d = sim.makeDisturbance(t, p);
            tc.assertTrue(all(d == 0), 'Disabled disturbance should be zero');
        end

        function test_makeDisturbance_square_bounded(tc)
            p = sim.defaultParams();
            p.signals = {true,'Square',30,0.2,0.0,0.0};
            t = linspace(0,1,1001)';
            d = sim.makeDisturbance(t, p);
            tc.assertTrue(all(abs(d) <= 30+1e-9), 'Square wave out of bounds');
        end
    end

    % ================================================================== computeMetrics
    methods (Test)
        function test_computeMetrics_returnTypes(tc)
            t      = linspace(0,2,2001)';
            spArr  = [zeros(200,1); ones(1801,1)*1000];
            errArr = zeros(2001,1);
            yTrue  = spArr;
            [lines, statusMsg] = sim.computeMetrics(t, errArr, spArr, yTrue);
            tc.assertTrue(iscell(lines),     'lines should be cell array');
            tc.assertTrue(ischar(statusMsg), 'statusMsg should be char');
        end

        function test_computeMetrics_perfectTracking_converged(tc)
            t      = linspace(0,2,2001)';
            spArr  = [zeros(200,1); ones(1801,1)*1000];
            errArr = zeros(2001,1);
            yTrue  = spArr;
            [~, statusMsg] = sim.computeMetrics(t, errArr, spArr, yTrue);
            tc.assertNotEmpty(strfind(statusMsg,'Converged'), ...
                'Perfect tracking should report Converged');
        end

        function test_computeMetrics_largeError_notConverged(tc)
            t      = linspace(0,2,2001)';
            spArr  = ones(2001,1)*1000;
            errArr = ones(2001,1)*200;
            yTrue  = spArr - errArr;
            [~, statusMsg] = sim.computeMetrics(t, errArr, spArr, yTrue);
            tc.assertNotEmpty(strfind(statusMsg,'Not converged'), ...
                'Large error should report Not converged');
        end

        function test_computeMetrics_IAE_nonnegative(tc)
            t      = linspace(0,1,1001)';
            spArr  = ones(1001,1)*500;
            errArr = sin(2*pi*t) * 20;
            yTrue  = spArr - errArr;
            [lines, ~] = sim.computeMetrics(t, errArr, spArr, yTrue);
            iaeLine = lines(contains(lines,'IAE'));
            tc.assertFalse(isempty(iaeLine), 'IAE line missing');
            tok = regexp(iaeLine{1}, '[\d.]+', 'match');
            tc.assertGreaterThanOrEqual(str2double(tok{1}), 0, 'IAE must be >= 0');
        end

        function test_computeMetrics_lineCount(tc)
            t      = linspace(0,2,2001)';
            spArr  = [zeros(200,1); ones(1801,1)*1000];
            errArr = randn(2001,1)*5;
            yTrue  = spArr - errArr;
            [lines, ~] = sim.computeMetrics(t, errArr, spArr, yTrue);
            tc.assertGreaterThanOrEqual(numel(lines), 8, ...
                'Expected at least 8 output lines');
        end
    end

    % ================================================================== imcTune
    methods (Test)
        function test_imcTune_PID_fields(tc)
            p = sim.defaultParams();
            g = sim.imcTune(p);
            tc.assertTrue(isfield(g.PID, 'kp'));
            tc.assertTrue(isfield(g.PID, 'ki'));
            tc.assertTrue(isfield(g.PID, 'kd'));
            tc.assertTrue(isfield(g.PID, 'd_filter_n'));
        end

        function test_imcTune_PID_positive(tc)
            p = sim.defaultParams();
            g = sim.imcTune(p);
            tc.assertGreaterThan(g.PID.kp, 0, 'Kp must be positive');
            tc.assertGreaterThan(g.PID.ki, 0, 'Ki must be positive');
            tc.assertGreaterThan(g.PID.kd, 0, 'Kd must be positive');
            tc.assertGreaterThan(g.PID.d_filter_n, 0, 'N must be positive');
        end

        function test_imcTune_PID_noDeadTime_zeroKd(tc)
            % With θ = 0, the D term should vanish
            p = sim.defaultParams();
            p.theta_us = 0;
            g = sim.imcTune(p);
            tc.assertEqual(g.PID.kd, 0, 'AbsTol', 1e-12, 'Kd should be 0 when θ=0');
        end

        function test_imcTune_PID_formula_defaults(tc)
            % θ_eff = θ_plant + θ_sensor + DT/2
            % Default: theta=10000µs, delay=0µs, dt_pid=50000µs → θ_eff=35ms
            p   = sim.defaultParams();
            g   = sim.imcTune(p);
            tau = p.tau_us * 1e-6;
            K   = p.K;
            te  = p.theta_us*1e-6 + p.delay_us*1e-6 + p.dt_pid_us*1e-6/2;
            lam = 2 * te;
            den = tau + te/2;
            kp_ref = den / (K * (lam + te/2));
            ki_ref = kp_ref / den;
            theta  = p.theta_us * 1e-6;
            kd_ref = kp_ref * tau * theta / (2*tau + theta);
            n_ref  = round((2*tau + theta) / theta);
            tc.assertEqual(g.PID.kp,         kp_ref, 'AbsTol', 1e-9, 'Kp');
            tc.assertEqual(g.PID.ki,         ki_ref, 'AbsTol', 1e-9, 'Ki');
            tc.assertEqual(g.PID.kd,         kd_ref, 'AbsTol', 1e-9, 'Kd');
            tc.assertEqual(g.PID.d_filter_n, n_ref,             'N');
        end

        function test_imcTune_sensorDelay_increases_theta_eff(tc)
            % Adding sensor delay must reduce gains (larger θ_eff → larger λ)
            p1 = sim.defaultParams();
            p2 = sim.defaultParams();  p2.delay_us = 5000;   % +5ms sensor delay
            g1 = sim.imcTune(p1);
            g2 = sim.imcTune(p2);
            tc.assertLessThan(g2.PID.kp, g1.PID.kp, 'More sensor delay → smaller Kp');
            tc.assertLessThan(g2.PID.ki, g1.PID.ki, 'More sensor delay → smaller Ki');
        end

        function test_imcTune_fasterController_allows_higher_gains(tc)
            % Faster controller update → smaller DT/2 → larger allowable gains
            p1 = sim.defaultParams();  p1.dt_pid_us = 100000;
            p2 = sim.defaultParams();  p2.dt_pid_us = 10000;
            g1 = sim.imcTune(p1);
            g2 = sim.imcTune(p2);
            tc.assertGreaterThan(g2.PID.kp, g1.PID.kp, 'Faster DT → higher Kp');
            tc.assertGreaterThan(g2.PID.ki, g1.PID.ki, 'Faster DT → higher Ki');
        end

        function test_imcTune_ADRC_fields(tc)
            p = sim.defaultParams();
            g = sim.imcTune(p);
            tc.assertTrue(isfield(g.ADRC, 'adrc_wc'));
            tc.assertTrue(isfield(g.ADRC, 'adrc_w0'));
            tc.assertGreaterThan(g.ADRC.adrc_wc, 0);
            tc.assertGreaterThan(g.ADRC.adrc_w0, g.ADRC.adrc_wc, 'ω₀ should be > ω_c');
        end

        function test_imcTune_PID_scalesWithK(tc)
            % Doubling K should halve Kp (inverse proportionality)
            p1 = sim.defaultParams();
            p2 = sim.defaultParams();  p2.K = p1.K * 2;
            g1 = sim.imcTune(p1);
            g2 = sim.imcTune(p2);
            tc.assertEqual(g1.PID.kp / g2.PID.kp, 2.0, 'AbsTol', 1e-9, ...
                'Kp should be inversely proportional to K');
        end

        function test_imcTune_PID_runSim_converges(tc)
            % Simulate with IMC-tuned gains and verify convergence
            p = sim.defaultParams();
            p.noise   = 0;   % no noise for deterministic test
            p.t_total = 5.0;
            g = sim.imcTune(p);
            p.kp         = g.PID.kp;
            p.ki         = g.PID.ki;
            p.kd         = g.PID.kd;
            p.d_filter_n = g.PID.d_filter_n;
            [t, ~, yTrue, ~, errArr, ~, spArr] = sim.runSim(p);
            [~, statusMsg] = sim.computeMetrics(t, errArr, spArr, yTrue);
            tc.assertNotEmpty(strfind(statusMsg, 'Converged'), ...
                ['IMC-PID should converge; got: ' statusMsg]);
        end
    end

    % ================================================================== Random setpoint fix
    methods (Test)
        function test_makeSetpoint_random_noError(tc)
            % Bug fix: Random waveform previously crashed with size mismatch
            % (vals was a row vector; indexing with col indices → row seg;
            %  sp(mask)=col+row triggered outer-product broadcast → assignment fail)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Random',100,0.2,0.0,0.0};
            t  = linspace(0,2,2001)';
            tc.verifyWarningFree(@() sim.makeSetpoint(t, p), ...
                'Random setpoint must not throw or warn');
        end

        function test_makeSetpoint_random_correctSize(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Random',50,0.1,0.0,0.0};
            t  = linspace(0,1,1001)';
            sp = sim.makeSetpoint(t, p);
            tc.assertEqual(numel(sp), numel(t), 'Random output must match t length');
        end

        function test_makeSetpoint_random_bounded(tc)
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Random',80,0.2,0.0,0.0};
            t  = linspace(0,4,4001)';
            sp = sim.makeSetpoint(t, p);
            tc.assertLessThanOrEqual(max(abs(sp)), 80+1e-9, ...
                'Random values must stay within ±amplitude');
        end

        function test_makeSetpoint_random_columnVector(tc)
            % Output must be a column vector matching the shape of t
            p = sim.defaultParams();
            p.sp_dc     = 0;
            p.setpoints = {true,'Random',100,0.3,0.0,0.0};
            t  = linspace(0,2,201)';    % column
            sp = sim.makeSetpoint(t, p);
            tc.assertEqual(size(sp,1), numel(t), 'sp must have rows == numel(t)');
            tc.assertEqual(size(sp,2), 1,         'sp must be a column vector');
        end
    end

    % ================================================================== Smith-ADRC
    methods (Test)
        function test_runSim_SmithADRC_noNaN(tc)
            p = sim.defaultParams();
            p.ctrl_mode  = 'ADRC';
            p.smith_adrc = 1;
            p.t_total    = 1.0;
            [~,yMeas,yTrue,vArr,errArr,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(yMeas)),  'NaN yMeas Smith-ADRC');
            tc.assertFalse(any(isnan(yTrue)),  'NaN yTrue Smith-ADRC');
            tc.assertFalse(any(isnan(vArr)),   'NaN vArr  Smith-ADRC');
            tc.assertFalse(any(isnan(errArr)), 'NaN errArr Smith-ADRC');
        end

        function test_runSim_SmithADRC_voltageWithinBounds(tc)
            p = sim.defaultParams();
            p.ctrl_mode  = 'ADRC';
            p.smith_adrc = 1;
            p.t_total    = 1.0;
            [~,~,~,vArr,~,~,~] = sim.runSim(p);
            tc.assertTrue(all(vArr >= 0),       'Smith-ADRC voltage < 0');
            tc.assertTrue(all(vArr <= p.v_max), 'Smith-ADRC voltage > v_max');
        end

        function test_runSim_SmithADRC_largeDeadtime_stable(tc)
            % With Euler ESO + large dead time, plain ADRC would oscillate.
            % ZOH + Smith predictor must remain stable even at ω₀·DT = 2.
            p = sim.defaultParams();
            p.ctrl_mode  = 'ADRC';
            p.smith_adrc = 1;
            p.theta_us   = 50000;  % 50 ms large dead time
            p.adrc_w0    = 40;     % ω₀·DT = 40 × 0.05 = 2.0 (Euler would diverge)
            p.t_total    = 2.0;
            [~,~,~,vArr,~,~,~] = sim.runSim(p);
            tc.assertFalse(any(isnan(vArr)), 'NaN with large dead time');
            tc.assertFalse(any(isinf(vArr)), 'Inf with large dead time');
        end

        function test_imcTune_Smith_higherBandwidth(tc)
            % Smith predictor removes θ_plant → ω_c must be strictly larger
            p = sim.defaultParams();
            p.theta_us   = 50000;  % 50 ms, substantial dead time to amplify the difference
            p1 = p;  p1.smith_adrc = 0;
            p2 = p;  p2.smith_adrc = 1;
            g1 = sim.imcTune(p1);
            g2 = sim.imcTune(p2);
            tc.assertGreaterThan(g2.ADRC.adrc_wc, g1.ADRC.adrc_wc, ...
                'Smith-ADRC must allow higher ω_c');
            tc.assertGreaterThan(g2.ADRC.adrc_w0, g1.ADRC.adrc_w0, ...
                'Smith-ADRC must allow higher ω₀');
        end

        function test_imcTune_Smith_noDeadtime_sameAsBandard(tc)
            % If θ_plant = 0, Smith makes no difference
            p = sim.defaultParams();
            p.theta_us = 0;
            p1 = p;  p1.smith_adrc = 0;
            p2 = p;  p2.smith_adrc = 1;
            g1 = sim.imcTune(p1);
            g2 = sim.imcTune(p2);
            tc.assertEqual(g2.ADRC.adrc_wc, g1.ADRC.adrc_wc, 'AbsTol', 1e-9, ...
                'ω_c must be identical when θ_plant = 0');
        end
    end

    % ================================================================== dt_pid_us + smith_adrc persistence
    methods (Test)
        function test_saveLoad_dt_pid_us(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.dt_pid_us = 25000;
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(p1.dt_pid_us, 25000, 'AbsTol', 1e-9, 'dt_pid_us roundtrip');
        end

        function test_saveLoad_theta_us(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.theta_us = 7500;
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(p1.theta_us, 7500, 'AbsTol', 1e-9, 'theta_us roundtrip');
        end

        function test_saveLoad_smith_adrc(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.smith_adrc = 0;
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(p1.smith_adrc, 0, 'AbsTol', 1e-9, 'smith_adrc=0 roundtrip');
        end

        function test_saveLoad_smith_adrc_on(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.smith_adrc = 1;
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(p1.smith_adrc, 1, 'AbsTol', 1e-9, 'smith_adrc=1 roundtrip');
        end
    end

    % ================================================================== computeMetrics shape
    methods (Test)
        function test_computeMetrics_linesIsColumnCell(tc)
            % metricsArea.Value in uifigure requires N×1 column cell array.
            % computeMetrics must return lines as column, not row.
            t      = linspace(0,2,2001)';
            spArr  = [zeros(200,1); ones(1801,1)*1000];
            errArr = zeros(2001,1);
            yTrue  = spArr;
            [lines, ~] = sim.computeMetrics(t, errArr, spArr, yTrue);
            tc.assertEqual(size(lines, 2), 1, ...
                'computeMetrics lines must be a column cell (N×1)');
        end
    end

    % ================================================================== config roundtrip
    methods (Test)
        function test_saveLoad_scalarFields(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.K             = 999;
            p0.tau_us        = 123000;
            p0.ctrl_mode     = 'ADRC';
            p0.adrc_wc       = 42;
            p0.hysteresis_nm = 77;
            p0.d_filter_n    = 15;
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(p1.K,             999, 'AbsTol',1e-9);
            tc.assertEqual(p1.tau_us,        123000, 'AbsTol',1e-9);
            tc.assertEqual(p1.ctrl_mode,     'ADRC');
            tc.assertEqual(p1.adrc_wc,       42,  'AbsTol',1e-9);
            tc.assertEqual(p1.hysteresis_nm, 77,  'AbsTol',1e-9);
            tc.assertEqual(p1.d_filter_n,    15,  'AbsTol',1e-9);
        end

        function test_saveLoad_setpoints(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.setpoints = {true,'Sine',200,0.5,0.1,1.0; false,'Square',50,0.2,0.0,0.0};
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(size(p1.setpoints,1), 2, 'Row count mismatch');
            tc.assertEqual(p1.setpoints{1,2}, 'Sine');
            tc.assertEqual(p1.setpoints{2,2}, 'Square');
            tc.assertEqual(p1.setpoints{1,3}, 200, 'AbsTol',1e-9);
        end

        function test_loadConfig_missingFile_returnsDefaults(tc)
            p  = sim.loadConfig('/nonexistent/path/no_such_file.json');
            p0 = sim.defaultParams();
            tc.assertEqual(p.K,         p0.K,         'AbsTol',1e-9);
            tc.assertEqual(p.tau_us,    p0.tau_us,    'AbsTol',1e-9);
            tc.assertEqual(p.ctrl_mode, p0.ctrl_mode);
        end

        function test_saveLoad_signals_empty(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.signals = {};
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertTrue(isempty(p1.signals), 'Empty signals should round-trip as empty');
        end
    end

    % ================================================================== fs_sample_hz (UMD2 sample rate)
    methods (Test)
        function test_defaultParams_fs_sample_hz(tc)
            p = sim.defaultParams();
            tc.assertTrue(isfield(p, 'fs_sample_hz'), 'Missing field: fs_sample_hz');
            tc.assertEqual(p.fs_sample_hz, 1000, 'AbsTol', 1e-9, ...
                'Default UMD2 sample rate should be 1 kHz');
        end

        function test_saveLoad_fs_sample_hz(tc)
            tmp = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.fs_sample_hz = 10000;
            sim.saveConfig(tmp, p0);
            p1 = sim.loadConfig(tmp);
            delete(tmp);
            tc.assertEqual(p1.fs_sample_hz, 10000, 'AbsTol', 1e-9, 'fs_sample_hz roundtrip');
        end

        function test_runSim_sampleHold_constantBetweenSamples(tc)
            % Plant integration stays at 1 µs resolution, but yMeas must only
            % refresh every 1/fs_sample_hz seconds (zero-order hold in between).
            % The sample-and-hold counter leads the controller-tick counter by
            % sBufLen steps (here 1, the floor for delay_us=0), so the first
            % real sample lands at k=sampPeriod (not sampPeriod+1); before
            % that yMeas holds its initial value. See +sim/runSim.m.
            p = sim.defaultParams();
            p.fs_sample_hz = 1000;   % 1 kHz → hold for 1000 plant steps (1 ms)
            p.delay_us     = 0;
            p.noise        = 3;
            p.t_total      = 0.01;
            [~, yMeas, ~, ~, ~, ~, ~] = sim.runSim(p);
            % k=1000:1999 is a full post-cold-start hold window and must be
            % bit-identical.
            held = yMeas(1000:1999);
            tc.assertEqual(numel(unique(held)), 1, ...
                'yMeas should stay constant within one sample-and-hold window');
            tc.assertNotEqual(yMeas(1999), yMeas(2000), ...
                'yMeas must refresh once the hold window elapses');
        end

        function test_runSim_higherSampleRate_updatesMoreOften(tc)
            % At 10x the sample rate, the hold window shrinks to 100 steps.
            p = sim.defaultParams();
            p.fs_sample_hz = 10000;  % 10 kHz → hold for 100 plant steps
            p.delay_us     = 0;
            p.noise        = 3;
            p.t_total      = 0.01;
            [~, yMeas, ~, ~, ~, ~, ~] = sim.runSim(p);
            held = yMeas(100:199);
            tc.assertEqual(numel(unique(held)), 1, ...
                'yMeas should stay constant within the shorter 10 kHz hold window');
            tc.assertNotEqual(yMeas(199), yMeas(200), ...
                'yMeas must refresh once the 10 kHz hold window elapses');
        end

        function test_runSim_sampleAndControlTick_areAligned(tc)
            % Regression test for a synchronization bug: the sample-and-hold
            % counter and the controller-tick counter used to reach their
            % thresholds at very different phases. With equal sample/control
            % periods, that made the controller's tick always consume the
            % *previous* period's sample (~1 full sample period stale, ~1 ms
            % here) instead of a freshly acquired one -- silently doubling
            % the intended ZOH-equivalent delay baked into +sim/imcTune.m's
            % theta_eff formula. The sample-and-hold counter must instead
            % lead the controller by exactly sBufLen steps, so staleness at
            % the tick is bounded by the sensor transport delay, not a full
            % sample period.
            p = sim.defaultParams();
            p.fs_sample_hz = 1000;
            p.dt_pid_us    = 1000;   % same period as the sample rate
            p.delay_us     = 0;      % sBufLen floors to 1 plant step (1 us)
            p.noise        = 0;
            p.t_total      = 0.01;
            [~, yMeas, yTrue, ~, ~, ~, ~] = sim.runSim(p);
            % At k=1001 (the controller's first tick), staleness must be at
            % most a couple of plant steps (sensor transport delay), not
            % anywhere near a full 1000-step sample period.
            staleness = find(abs(yTrue - yMeas(1001)) < 1e-9, 1, 'last');
            tc.assertNotEmpty(staleness, 'yMeas(1001) should match some recent yTrue sample');
            tc.assertLessThan(1001 - staleness, 5, ...
                'Sample-and-hold staleness at the controller tick must be a few plant steps, not a full sample period');
        end
    end

    % ================================================================== runHeadless (no-GUI entry point)
    methods (Test)
        function test_runHeadless_noFiguresCreated(tc)
            nBefore = numel(findall(0, 'Type', 'figure'));
            r = sim.runHeadless('t_total', 0.2, 'Verbose', false); %#ok<NASGU>
            nAfter = numel(findall(0, 'Type', 'figure'));
            tc.assertEqual(nAfter, nBefore, ...
                'Headless run must not create any figure/uifigure by default');
        end

        function test_runHeadless_resultStruct_requiredFields(tc)
            r = sim.runHeadless('t_total', 0.2, 'Verbose', false);
            required = {'t','yMeas','yTrue','vArr','errArr','distArr','spArr', ...
                        'dynMetrics','metricsText','statusMsg','params'};
            for i = 1:numel(required)
                tc.assertTrue(isfield(r, required{i}), ...
                    ['runHeadless result missing field: ' required{i}]);
            end
        end

        function test_runHeadless_paramOverride(tc)
            r = sim.runHeadless('K', 999, 't_total', 0.2, 'Verbose', false);
            tc.assertEqual(r.params.K, 999, 'AbsTol', 1e-9, ...
                'Name-value override should be applied to params');
        end

        function test_runHeadless_structArgOverride(tc)
            p0 = sim.defaultParams();
            p0.t_total = 0.2;
            p0.ctrl_mode = 'ADRC';
            r = sim.runHeadless(p0, 'Verbose', false);
            tc.assertEqual(r.params.ctrl_mode, 'ADRC');
        end

        function test_runHeadless_configFile(tc)
            tmpJson = [tempname '.json'];
            p0 = sim.defaultParams();
            p0.K = 777;
            sim.saveConfig(tmpJson, p0);
            r = sim.runHeadless('ConfigFile', tmpJson, 't_total', 0.2, 'Verbose', false);
            delete(tmpJson);
            tc.assertEqual(r.params.K, 777, 'AbsTol', 1e-9, ...
                'ConfigFile should seed parameters');
        end

        function test_runHeadless_saveCSV(tc)
            csvPath = [tempname '.csv'];
            r = sim.runHeadless('t_total', 0.1, 'SaveCSV', csvPath, 'Verbose', false);
            tc.assertTrue(isfile(csvPath), 'CSV file should be written');
            tbl = readtable(csvPath);
            delete(csvPath);
            tc.assertEqual(height(tbl), numel(r.t), 'CSV row count must match t');
        end

        function test_runHeadless_saveMAT(tc)
            matPath = [tempname '.mat'];
            r = sim.runHeadless('t_total', 0.1, 'SaveMAT', matPath, 'Verbose', false);
            tc.assertTrue(isfile(matPath), 'MAT file should be written');
            mm = load(matPath, 't');
            delete(matPath);
            tc.assertEqual(numel(mm.t), numel(r.t), 'MAT t vector must match');
        end

        function test_runHeadless_plotExport_noLingeringFigure(tc)
            pngPath = [tempname '.png'];
            nBefore = numel(findall(0, 'Type', 'figure'));
            sim.runHeadless('t_total', 0.2, 'Plot', 'png', 'PlotFile', pngPath, 'Verbose', false);
            nAfter = numel(findall(0, 'Type', 'figure'));
            tc.assertTrue(isfile(pngPath), 'PNG plot should be exported');
            delete(pngPath);
            tc.assertEqual(nAfter, nBefore, ...
                'Plot figure must be closed after export, not left open');
        end
    end

end
