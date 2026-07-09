%ADRC_POLE_ANALYSIS  Closed-loop pole analysis explaining why ADRC's
%   achieved -3dB bandwidth is far below its design target omega_c.
%
%   Builds the continuous-time closed-loop state matrix for ADRC+Smith
%   controlling a true first-order plant (dy/dt = -y/tau + b0*u), with
%   states [y, z1, z2] (z1,z2 = ESO states), and:
%     - computes exact eigenvalues (closed-loop poles)
%     - compares to the asymptotic approximation p_slow = -(25/11)*wc^2*tau
%       (derived for the standard w0=5*wc tuning used throughout this work)
%     - computes the continuous-time closed-loop -3dB bandwidth directly
%       from (jw*I-A)^-1*B*C and compares both to the pole-based estimate
%       and to the actual DISCRETE simulated bandwidth from
%       bandwidth_sweep_results.csv (ground truth).
%
%   wc/w0 are COMPUTED here via +sim/tunedADRC.m from the same scenario
%   parameters in +sim/analysisConfig.m that bandwidth_sweep.m uses --
%   not hand-copied from a prior run, so this can never silently go stale
%   if the scenario definitions change. Which scenarios get analysed is
%   controlled by +sim/analysisConfig.m's per-scenario `poleAnalysis` flag.
%
%   Output: adrc_pole_table.csv (for a paper table) and printed comparison.

clear; clc;
here = fileparts(mfilename('fullpath'));

cfg = sim.analysisConfig();
scenarios = cfg.scenarios(logical([cfg.scenarios.poleAnalysis]));

csvPath = fullfile(here, 'bandwidth_sweep_results.csv');
if ~isfile(csvPath)
    error('adrc_pole_analysis:missingCsv', ...
        'Run bandwidth_sweep.m first -- %s not found.', csvPath);
end
T = readtable(csvPath);

rows = {};
for i = 1:numel(scenarios)
    sc  = scenarios(i);
    tau = sc.params.tau_us * 1e-6;
    a   = 1/tau;

    p0 = sim.defaultParams();
    p0.K = cfg.plant.K;
    pf = fieldnames(sc.params);
    for k = 1:numel(pf), p0.(pf{k}) = sc.params.(pf{k}); end
    p0.smith_adrc = 1;
    [wc, w0] = sim.tunedADRC(p0);

    A = [ -a,      -wc,      -1;
           2*w0,  -(wc+2*w0), 0;
           w0^2,   -w0^2,     0 ];
    B = [wc; wc; 0];
    C = [1 0 0];

    poles = eig(A);
    % Sort by REAL PART (least-negative/dominant pole first), not by
    % MATLAB's default complex sort() which orders by magnitude -- for
    % scenarios where the closed-loop poles come out complex (large wc
    % relative to tau), sorting by magnitude can rank a fast, lightly-
    % damped complex pair ahead of the true dominant real pole and mislabel
    % it as "slowest". Does not change anything for the all-real-pole
    % scenarios (A, C) used in the paper, where sort-by-magnitude and
    % sort-by-real-part happen to agree.
    [~, poleOrder] = sort(real(poles), 'descend');
    poles = poles(poleOrder);

    % Asymptotic slow-pole estimate for w0 = 5*wc tuning
    pSlowApprox = -(25/11) * wc^2 * tau;

    % Exact continuous-time closed-loop -3dB bandwidth
    f = logspace(-1, 6, 2000);
    gainDB = zeros(size(f));
    for fi = 1:numel(f)
        w = 2*pi*f(fi);
        G = C * ((1i*w*eye(3) - A) \ B);
        gainDB(fi) = 20*log10(abs(G));
    end
    idx = find(gainDB < -3, 1, 'first');
    frac = (-3 - gainDB(idx-1)) / (gainDB(idx) - gainDB(idx-1));
    bw3dB_continuous = f(idx-1) * (f(idx)/f(idx-1))^frac;

    % Ground truth: actual DISCRETE simulated -3dB from bandwidth_sweep.m
    mask = strcmp(T.scenario, sc.name) & strcmp(T.controller, 'ADRC_Smith');
    sub = sortrows(T(mask,:), 'freqHz');
    idxD = find(sub.gainDB < -3, 1, 'first');
    if ~isempty(idxD) && idxD > 1
        f1 = sub.freqHz(idxD-1); f2 = sub.freqHz(idxD);
        g1 = sub.gainDB(idxD-1); g2 = sub.gainDB(idxD);
        fracD = (-3-g1)/(g2-g1);
        bw3dB_discrete = f1 * (f2/f1)^fracD;
        discreteStr = sprintf('%.2f Hz', bw3dB_discrete);
    elseif ~isempty(idxD)
        bw3dB_discrete = sub.freqHz(1);
        discreteStr = sprintf('< %.2f Hz', bw3dB_discrete);
    else
        bw3dB_discrete = NaN;
        discreteStr = 'n/a (never crossed -3dB in tested range)';
    end

    fprintf('--- Scenario %s (tau=%gus, wc=%.1f rad/s = %.1f Hz, w0=%.1f rad/s) ---\n', ...
        sc.name, sc.params.tau_us, wc, wc/2/pi, w0);
    fprintf('  Poles (rad/s): %s\n', mat2str(poles,5));
    fprintf('  Slowest pole -> Hz: %.2f (exact),  %.2f (asymptotic -25/11*wc^2*tau)\n', ...
        -real(poles(1))/2/pi, -pSlowApprox/2/pi);
    fprintf('  -3dB bandwidth: %.2f Hz (continuous analytic), %s (discrete simulation, ground truth)\n\n', ...
        bw3dB_continuous, discreteStr);

    rows(end+1,:) = {sc.name, sc.params.tau_us, wc, wc/2/pi, w0, ...
        real(poles(1)), real(poles(2)), real(poles(3)), ...
        -pSlowApprox, bw3dB_continuous, bw3dB_discrete}; %#ok<SAGROW>
end

Tout = cell2table(rows, 'VariableNames', ...
    {'scenario','tau_us','wc_rad_s','wc_Hz','w0_rad_s', ...
     'pole1_rad_s','pole2_rad_s','pole3_rad_s', ...
     'pole3_asymptotic_rad_s','bw3dB_continuous_Hz','bw3dB_discrete_Hz'});
writetable(Tout, fullfile(here, 'adrc_pole_table.csv'));
fprintf('Saved %s\n', fullfile(here, 'adrc_pole_table.csv'));
