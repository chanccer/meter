%WAVEFORM_TRACKING_NATURE_ALL  Black-and-white, journal/LaTeX-style
%   sine/square tracking figures (PID vs Preview, each plotted against the
%   reference in its own panel) for ALL FOUR bandwidth-limiting scenarios
%   defined in +sim/analysisConfig.m. Also saves the underlying
%   time-series data as CSV and a parameter manifest, so the figures are
%   reproducible and citable when embedded in a paper.
%
%   Every scenario parameter and the PID tuning formula come from
%   +sim/analysisConfig.m / +sim/tunedPID.m -- nothing here is hardcoded.
%
%   Each figure here combines normal- and limit-bandwidth panels in one
%   8-panel overview. For separate normal-only / limit-only figures (one
%   4-panel PDF each), see waveform_tracking_nature_split.m.
%
%   Output, all under paper_figures/:
%     fig_waveform_<scenario>.pdf   vector figure, 8 panels (a-h), for
%                                   \includegraphics in LaTeX
%     fig_waveform_<scenario>.png   raster preview (400 dpi)
%     data_waveform_<scenario>.csv  long-format (panel,controller,wave,
%                                   band,freq_Hz,t_ms,setpoint_nm,
%                                   displacement_nm) time series, decimated
%                                   to ~2000 points/panel
%     waveform_scenarios_manifest.csv  every scenario's plant/controller
%                                   parameters and chosen test frequencies

clear; clc;
outDir = fullfile(fileparts(mfilename('fullpath')), 'paper_figures');
if ~exist(outDir, 'dir'), mkdir(outDir); end

cfg = sim.analysisConfig();
scenarios = cfg.scenarios;

manifestRows = {};

for si = 1:numel(scenarios)
    sc = scenarios(si);
    fprintf('=== %s ===\n', sc.name);

    p0 = sim.defaultParams();
    p0.K              = cfg.plant.K;
    p0.noise          = cfg.plant.noise;
    p0.v_max          = cfg.plant.v_max;
    p0.hysteresis_nm  = cfg.plant.hysteresis_nm;
    pf = fieldnames(sc.params);
    for i = 1:numel(pf), p0.(pf{i}) = sc.params.(pf{i}); end

    [kp, ki] = sim.tunedPID(p0);
    pPID = p0; pPID.ctrl_mode='PID'; pPID.kp=kp; pPID.ki=ki; pPID.kd=0; pPID.d_filter_n=0;
    pPV  = p0; pPV.ctrl_mode  = 'Preview';

    rows = struct([]);
    rows(1).wave='Sine';   rows(1).band='normal bandwidth'; rows(1).freq=sc.normalHz; rows(1).cycles=cfg.waveformCycles.normal.sine;
    rows(2).wave='Sine';   rows(2).band='limit bandwidth';  rows(2).freq=sc.limitHz;  rows(2).cycles=cfg.waveformCycles.limit.sine;
    rows(3).wave='Square'; rows(3).band='normal bandwidth'; rows(3).freq=sc.normalHz; rows(3).cycles=cfg.waveformCycles.normal.square;
    rows(4).wave='Square'; rows(4).band='limit bandwidth';  rows(4).freq=sc.limitHz;  rows(4).cycles=cfg.waveformCycles.limit.square;

    cols = struct('name', {'PID','Preview'}, 'params', {pPID, pPV}, 'lineStyle', {'-','-.'});

    % Grid dimensions and figure size derive from numel(rows)/numel(cols)
    % rather than assuming exactly 4 rows x 2 cols -- adding a wave type,
    % bandwidth regime, or controller to either array above just works.
    fig = figure('Visible','off','Position',[100 100 500*numel(cols) 330*numel(rows)+100], 'Color','w');
    tl = tiledlayout(fig, numel(rows), numel(cols), 'TileSpacing','loose', 'Padding','normal');

    dataRows = {};
    li = 0;
    for ri = 1:numel(rows)
        rw = rows(ri);
        tTotal = sc.t0 + rw.cycles/rw.freq;

        for ci = 1:numel(cols)
            li = li + 1;
            ax = nexttile(tl);
            hold(ax, 'on');
            set(ax, 'FontName','Times New Roman', 'FontSize', 10, 'LineWidth', 0.75, ...
                'TickDir','out', 'Box','off', 'TickLength',[0.012 0.012]);

            p = cols(ci).params;
            p.sp_dc = sc.dcNm;
            p.setpoints = {true, rw.wave, sc.ampNm, 1/rw.freq, sc.t0, 0};
            p.t_total = tTotal;
            [t, ~, yTrue, ~, ~, ~, spArr] = sim.runSim(p);

            hSp = plot(ax, t*1000, spArr, ':', 'Color', 'k', 'LineWidth', 0.8);
            hY  = plot(ax, t*1000, yTrue, cols(ci).lineStyle, 'Color', 'k', 'LineWidth', 1.0);

            xlim(ax, [0, tTotal*1000]);
            xlabel(ax, 'Time (ms)', 'FontName','Times New Roman', 'FontSize', 10);
            ylabel(ax, 'Displacement (nm)', 'FontName','Times New Roman', 'FontSize', 10);
            title(ax, sprintf('%s -- %s, %s (%g Hz)', cols(ci).name, rw.wave, rw.band, rw.freq), ...
                'FontName','Times New Roman', 'FontSize', 10, 'FontWeight','normal');
            text(ax, -0.13, 1.12, panelLabel(li), 'Units','normalized', 'FontName','Helvetica', ...
                'FontSize', 13, 'FontWeight','bold', 'VerticalAlignment','top', 'Clipping','off');

            if li == 1, legHandles = [hSp, hY]; end

            strideCSV = max(1, round(numel(t)/2000));
            idxCSV = 1:strideCSV:numel(t);
            for jj = idxCSV
                dataRows(end+1,:) = {panelLabel(li), cols(ci).name, rw.wave, rw.band, rw.freq, ...
                    t(jj)*1000, spArr(jj), yTrue(jj)}; %#ok<SAGROW>
            end
        end
    end

    lg = legend(legHandles, {'setpoint r(t)','controller output y(t)'}, ...
        'Orientation','horizontal', 'FontName','Times New Roman', 'FontSize', 9, 'Box','off');
    lg.Layout.Tile = 'north';
    title(tl, sc.title, 'FontName','Times New Roman', 'FontSize', 11, 'FontWeight','bold', 'Interpreter','tex');

    pdfPath = fullfile(outDir, ['fig_waveform_' sc.name '.pdf']);
    pngPath = fullfile(outDir, ['fig_waveform_' sc.name '.png']);
    exportgraphics(fig, pngPath, 'Resolution', 400);
    exportgraphics(fig, pdfPath, 'ContentType', 'vector');
    close(fig);

    csvPath = fullfile(outDir, ['data_waveform_' sc.name '.csv']);
    Tdata = cell2table(dataRows, 'VariableNames', ...
        {'panel','controller','wave','band','freq_Hz','t_ms','setpoint_nm','displacement_nm'});
    writetable(Tdata, csvPath);

    fprintf('  Saved %s\n  Saved %s\n  Saved %s\n', pdfPath, pngPath, csvPath);

    manifestRows(end+1,:) = {sc.name, sc.title, p0.fs_sample_hz, p0.dt_pid_us, p0.theta_us, ...
        p0.delay_us, p0.tau_us, p0.K, p0.v_max, sc.ampNm, sc.dcNm, sc.t0*1000, ...
        sc.normalHz, sc.limitHz, kp, ki}; %#ok<SAGROW>
end

Tman = cell2table(manifestRows, 'VariableNames', ...
    {'scenario','title','fs_sample_hz','dt_pid_us','theta_us','delay_us','tau_us','K_nm_per_V', ...
     'v_max_V','amp_nm','dc_nm','t0_ms','normal_freq_Hz','limit_freq_Hz','PID_kp','PID_ki'});
writetable(Tman, fullfile(outDir, 'waveform_scenarios_manifest.csv'));
fprintf('\nManifest saved: %s\n', fullfile(outDir, 'waveform_scenarios_manifest.csv'));

function s = panelLabel(idx)
%PANELLABEL  a, b, c, ..., z, aa, ab, ... for panel idx (1-based) -- scales
%   to any number of rows*cols instead of assuming exactly 8 (a-h).
    s = '';
    while idx > 0
        idx = idx - 1;
        s = [char('a' + mod(idx,26)), s]; %#ok<AGROW>
        idx = floor(idx/26);
    end
end
