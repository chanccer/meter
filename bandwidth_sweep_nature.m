%BANDWIDTH_SWEEP_NATURE  Black-and-white, journal/LaTeX-style closed-loop
%   frequency-response (gain vs. frequency) comparison: PID vs ADRC+Smith
%   vs Preview, across whichever bandwidth-limiting scenarios are defined
%   in +sim/analysisConfig.m (currently four: A-D). Reads
%   bandwidth_sweep_results.csv directly --
%   rerun bandwidth_sweep.m first if the underlying tuning/controller
%   code has changed since the CSV was last written.
%
%   Nothing here is hardcoded: scenario titles come from
%   +sim/analysisConfig.m, the theoretical ceiling (Nyquist frequency,
%   loop Nyquist frequency, actuator intrinsic bandwidth) is COMPUTED
%   from each scenario's own physical parameters rather than typed in
%   separately, and the y-axis range auto-fits the actual data in
%   bandwidth_sweep_results.csv rather than being hand-picked per panel.
%
%   The panel grid, figure size, and a-z panel labels are all derived from
%   numel(cfg.scenarios) -- adding, removing, or reordering scenarios in
%   +sim/analysisConfig.m changes the figure automatically, no separate
%   "4-panel" assumption lives here.
%
%   This is the frequency-domain counterpart to the time-domain
%   waveform_tracking_nature_* figures: same scenarios, same line-style
%   convention (solid=PID, dashed=ADRC+Smith, dash-dot=Preview),
%   black-and-white only, Times New Roman.
%
%   Output, under paper_figures/:
%     fig_bandwidth_sweep.pdf/.png   one panel per scenario (a, b, c, ...),
%                                    closed-loop gain vs. frequency, -3dB
%                                    threshold marked, theoretical ceiling
%                                    marked where applicable, saturated
%                                    points ringed
%     data_bandwidth_sweep.csv      copy of the source data actually used

clear; clc;
here = fileparts(mfilename('fullpath'));
outDir = fullfile(here, 'paper_figures');
if ~exist(outDir, 'dir'), mkdir(outDir); end

csvPath = fullfile(here, 'bandwidth_sweep_results.csv');
if ~isfile(csvPath)
    error('bandwidth_sweep_nature:missingCsv', ...
        'Run bandwidth_sweep.m first -- %s not found.', csvPath);
end
T = readtable(csvPath);

cfg = sim.analysisConfig();
scenarios = cfg.scenarios;

ctrlStyles = struct('name', {'PID','ADRC_Smith','Preview'}, ...
                     'label', {'PID (no preview)','ADRC+Smith (no preview)','Preview'}, ...
                     'lineStyle', {'-','--','-.'}, ...
                     'marker', {'o','s','^'}, ...
                     'markerEvery', {2,2,2});

nScen = numel(scenarios);
ncols = min(2, nScen);
nrows = ceil(nScen / ncols);

fig = figure('Visible','off','Position',[100 100 500*ncols 360*nrows+100], 'Color','w');
tl = tiledlayout(fig, nrows, ncols, 'TileSpacing','loose', 'Padding','normal');

legHandles = gobjects(0);
legLabels  = {};
haveSatHandle = false;

for pk = 1:numel(scenarios)
    sc = scenarios(pk);
    ax = nexttile(tl);
    hold(ax, 'on');
    set(ax, 'FontName','Times New Roman', 'FontSize', 10, 'LineWidth', 0.75, ...
        'TickDir','out', 'Box','off', 'XScale','log');

    scMask = strcmp(T.scenario, sc.name);
    fAll  = T.freqHz(scMask);
    gAll  = T.gainDB(scMask);
    xlim(ax, [min(fAll)*0.9, max(fAll)*1.1]);

    % Auto-fit the y-range to the actual data instead of a hand-picked
    % per-scenario constant: always show the -3dB threshold with some
    % headroom, and pad the observed min/max by ~20%.
    yLo = min([gAll; -3]); yHi = max([gAll; 0]);
    pad = 0.2 * max(yHi - yLo, 1);
    ylim(ax, [floor(yLo - pad), ceil(yHi + pad)]);

    yline(ax, -3, ':', 'Color', 'k', 'LineWidth', 1.0);

    ceilingHz = computeCeiling(sc.ceilingType, sc.params);
    if ~isnan(ceilingHz)
        xline(ax, ceilingHz, '--', 'Color', [0.5 0.5 0.5], 'LineWidth', 0.9);
    end

    for ci = 1:numel(ctrlStyles)
        mask = scMask & strcmp(T.controller, ctrlStyles(ci).name);
        if ~any(mask), continue; end
        sub = sortrows(T(mask,:), 'freqHz');
        h = plot(ax, sub.freqHz, sub.gainDB, ctrlStyles(ci).lineStyle, ...
            'Color', 'k', 'LineWidth', 1.15, ...
            'Marker', ctrlStyles(ci).marker, 'MarkerIndices', 1:ctrlStyles(ci).markerEvery:height(sub), ...
            'MarkerSize', 5.5, 'MarkerFaceColor', 'k');

        satIdx = sub.saturated == 1;
        if any(satIdx)
            hSat = plot(ax, sub.freqHz(satIdx), sub.gainDB(satIdx), 'd', ...
                'MarkerEdgeColor', 'k', 'MarkerFaceColor', 'w', 'MarkerSize', 8, 'LineWidth', 1.0, 'LineStyle','none');
            if ~haveSatHandle
                legHandles(end+1) = hSat; %#ok<AGROW>
                legLabels{end+1}  = 'saturated'; %#ok<AGROW>
                haveSatHandle = true;
            end
        end

        if pk == 1
            legHandles(end+1) = h; %#ok<AGROW>
            legLabels{end+1}  = ctrlStyles(ci).label; %#ok<AGROW>
        end
    end

    xlabel(ax, 'Frequency (Hz)', 'FontName','Times New Roman', 'FontSize', 10);
    ylabel(ax, 'Closed-loop gain (dB)', 'FontName','Times New Roman', 'FontSize', 10);
    title(ax, sc.title, 'FontName','Times New Roman', 'FontSize', 10.5, 'FontWeight','normal');
    text(ax, -0.16, 1.12, panelLabel(pk), 'Units','normalized', 'FontName','Helvetica', ...
        'FontSize', 13, 'FontWeight','bold', 'VerticalAlignment','top', 'Clipping','off');
end

lg = legend(legHandles, legLabels, 'Orientation','horizontal', 'NumColumns', 2, ...
    'FontName','Times New Roman', 'FontSize', 9, 'Box','off');
lg.Layout.Tile = 'north';
title(tl, 'Closed-loop frequency response: with vs. without preview', ...
    'FontName','Times New Roman', 'FontSize', 12, 'FontWeight','bold');

pngPath = fullfile(outDir, 'fig_bandwidth_sweep.png');
pdfPath = fullfile(outDir, 'fig_bandwidth_sweep.pdf');
exportgraphics(fig, pngPath, 'Resolution', 400);
exportgraphics(fig, pdfPath, 'ContentType', 'vector');
close(fig);

copyfile(csvPath, fullfile(outDir, 'data_bandwidth_sweep.csv'));

fprintf('Saved %s\nSaved %s\nSaved %s\n', pngPath, pdfPath, fullfile(outDir, 'data_bandwidth_sweep.csv'));

function s = panelLabel(idx)
%PANELLABEL  a, b, c, ..., z, aa, ab, ... for panel idx (1-based) -- scales
%   to any number of scenarios instead of assuming exactly 4 (a-d).
    s = '';
    while idx > 0
        idx = idx - 1;
        s = [char('a' + mod(idx,26)), s]; %#ok<AGROW>
        idx = floor(idx/26);
    end
end

function hz = computeCeiling(ceilingType, params)
%COMPUTECEILING  Theoretical bandwidth ceiling, derived from the
%   scenario's own physical parameters rather than a separate hardcoded
%   number (see +sim/analysisConfig.m's ceilingType documentation).
    switch ceilingType
        case 'nyquist_fs'
            hz = params.fs_sample_hz / 2;
        case 'nyquist_loop'
            hz = (1 / (params.dt_pid_us*1e-6)) / 2;
        case 'actuator_bw'
            hz = 1 / (2*pi*params.tau_us*1e-6);
        otherwise
            hz = NaN;
    end
end
