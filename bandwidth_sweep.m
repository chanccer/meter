%BANDWIDTH_SWEEP  Compare closed-loop bandwidth: Preview vs. reactive PID/ADRC.
%
%   For each bandwidth-limiting scenario defined in +sim/analysisConfig.m
%   (currently four: A-D), sweeps a sine-reference frequency and fits the
%   steady-state closed-loop gain/phase at each frequency for up to three
%   controllers:
%
%     - IMC-tuned 'PID'        (reactive — only ever sees r[k], r[k-1])
%     - 'ADRC'+Smith Predictor (reactive, codebase's normal best choice —
%        skipped where +sim/analysisConfig.m marks hasADRC=false)
%     - 'Preview'              (exact FOPDT-inversion feedforward using
%        the already-known future setpoint + small PI trim)
%
%   Every scenario parameter (fs/dt/theta/delay/tau, test amplitude,
%   sweep frequencies, sweep protocol) and both gain-tuning formulas
%   (+sim/tunedPID.m, +sim/tunedADRC.m) live in +sim/analysisConfig.m —
%   nothing here is hardcoded; rerun after editing that file.
%
%   Output: bandwidth_sweep_results.csv (scenario, controller, freqHz,
%   gainDB, phaseLagDeg, saturated) for downstream plotting.

clear; clc;
outCsv = fullfile(fileparts(mfilename('fullpath')), 'bandwidth_sweep_results.csv');

cfg = sim.analysisConfig();
scenarios = cfg.scenarios;

rows = {};
for si = 1:numel(scenarios)
    sc = scenarios(si);
    fprintf('=== Scenario %s: %s ===\n', sc.name, sc.label);

    p0 = sim.defaultParams();
    p0.K              = cfg.plant.K;
    p0.noise          = cfg.plant.noise;
    p0.v_max          = cfg.plant.v_max;
    p0.hysteresis_nm  = cfg.plant.hysteresis_nm;
    pf = fieldnames(sc.params);
    for i = 1:numel(pf)
        p0.(pf{i}) = sc.params.(pf{i});
    end

    % Reactive baselines: IMC-tuned PID (always) + ADRC+Smith (where numerically valid)
    [kp, ki] = sim.tunedPID(p0);
    pPID = p0;
    pPID.ctrl_mode = 'PID';
    pPID.kp = kp;  pPID.ki = ki;  pPID.kd = 0;  pPID.d_filter_n = 0;

    pPV = p0;
    pPV.ctrl_mode = 'Preview';

    if sc.hasADRC
        p0.smith_adrc = 1;
        [wc, w0] = sim.tunedADRC(p0);
        pADRC = p0;
        pADRC.ctrl_mode = 'ADRC';
        pADRC.adrc_wc   = wc;
        pADRC.adrc_w0   = w0;
    end

    for fi = 1:numel(sc.sweepFreqHz)
        f = sc.sweepFreqHz(fi);
        rR = sim.freqResponsePoint(pPID, f, sc.ampNm, sc.dcNm, cfg.sweep.nCyclesSettle, cfg.sweep.nCyclesMeasure);
        rP = sim.freqResponsePoint(pPV,  f, sc.ampNm, sc.dcNm, cfg.sweep.nCyclesSettle, cfg.sweep.nCyclesMeasure);

        rows(end+1,:) = {sc.name, 'PID',     f, rR.gainDB, rR.phaseLagDeg, double(rR.saturated)}; %#ok<SAGROW>
        rows(end+1,:) = {sc.name, 'Preview', f, rP.gainDB, rP.phaseLagDeg, double(rP.saturated)}; %#ok<SAGROW>

        line = sprintf('  f=%9.2f Hz | PID: %7.2f dB, %7.1f deg%s | Preview: %7.2f dB, %7.1f deg%s', ...
            f, rR.gainDB, rR.phaseLagDeg, ternary(rR.saturated,' [SAT]',''), ...
               rP.gainDB, rP.phaseLagDeg, ternary(rP.saturated,' [SAT]',''));

        if sc.hasADRC
            rA = sim.freqResponsePoint(pADRC, f, sc.ampNm, sc.dcNm, cfg.sweep.nCyclesSettle, cfg.sweep.nCyclesMeasure);
            rows(end+1,:) = {sc.name, 'ADRC_Smith', f, rA.gainDB, rA.phaseLagDeg, double(rA.saturated)}; %#ok<SAGROW>
            line = [line, sprintf(' | ADRC+Smith: %7.2f dB, %7.1f deg%s', ...
                rA.gainDB, rA.phaseLagDeg, ternary(rA.saturated,' [SAT]',''))]; %#ok<AGROW>
        end
        fprintf('%s\n', line);
    end
end

T = cell2table(rows, 'VariableNames', {'scenario','controller','freqHz','gainDB','phaseLagDeg','saturated'});
writetable(T, outCsv);
fprintf('\nSaved: %s\n', outCsv);

% ---- -3dB bandwidth summary (linear interpolation of the first downward crossing) ----
fprintf('\n=== -3dB closed-loop bandwidth summary ===\n');
for si = 1:numel(scenarios)
    sc = scenarios(si);
    ctrls = {'PID','Preview'};
    if sc.hasADRC, ctrls = {'PID','ADRC_Smith','Preview'}; end
    fprintf('%s:\n', sc.label);
    for ci = 1:numel(ctrls)
        mask = strcmp(T.scenario, sc.name) & strcmp(T.controller, ctrls{ci});
        f  = T.freqHz(mask);
        gd = T.gainDB(mask);
        [f, ord] = sort(f); gd = gd(ord);
        bw = find3dB(f, gd);
        if isnan(bw)
            if gd(1) < -3
                bwStr = sprintf('< %.2f Hz (第一个测试点已跌破 -3dB)', f(1));
            else
                bwStr = sprintf('> %.0f Hz (未在扫描范围内跌破 -3dB)', f(end));
            end
        else
            bwStr = sprintf('%.1f Hz', bw);
        end
        fprintf('  %-11s : %s\n', ctrls{ci}, bwStr);
    end
end

function bw = find3dB(f, gainDB)
    idx = find(gainDB < -3, 1, 'first');
    if isempty(idx) || idx == 1
        bw = NaN;
        return;
    end
    f1 = f(idx-1); f2 = f(idx);
    g1 = gainDB(idx-1); g2 = gainDB(idx);
    frac = (-3 - g1) / (g2 - g1);
    bw = f1 + frac*(f2 - f1);
end

function s = ternary(cond, a, b)
    if cond, s = a; else, s = b; end
end
