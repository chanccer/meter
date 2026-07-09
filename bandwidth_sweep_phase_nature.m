%BANDWIDTH_SWEEP_PHASE_NATURE  Black-and-white, journal/LaTeX-style
%   closed-loop PHASE response (phase lag vs. frequency) companion to
%   bandwidth_sweep_nature.m's gain plot. Same scenarios, same
%   PID/ADRC+Smith/Preview line-style convention. Uses the phaseLagDeg
%   column already present in bandwidth_sweep_results.csv (computed by
%   the same sine-fit as the gain data, never previously plotted).
%
%   Scenario titles come from +sim/analysisConfig.m (not hardcoded here),
%   the same single source of truth used by bandwidth_sweep_nature.m and
%   the waveform_tracking_nature_* scripts. The panel grid, figure size,
%   and a-z panel labels are all derived from numel(cfg.scenarios) --
%   adding/removing/reordering scenarios changes the figure automatically.
%
%   Output, under paper_figures/:
%     fig_bandwidth_phase.pdf/.png   one panel per scenario (a, b, c, ...),
%                                    phase lag vs. frequency

clear; clc;
here = fileparts(mfilename('fullpath'));
outDir = fullfile(here, 'paper_figures');
if ~exist(outDir, 'dir'), mkdir(outDir); end

csvPath = fullfile(here, 'bandwidth_sweep_results.csv');
if ~isfile(csvPath)
    error('bandwidth_sweep_phase_nature:missingCsv', ...
        'Run bandwidth_sweep.m first -- %s not found.', csvPath);
end
T = readtable(csvPath);

cfg = sim.analysisConfig();
panelInfo = cfg.scenarios;

ctrlStyles = struct('name', {'PID','ADRC_Smith','Preview'}, ...
                     'label', {'PID (no preview)','ADRC+Smith (no preview)','Preview'}, ...
                     'lineStyle', {'-','--','-.'}, ...
                     'marker', {'o','s','^'}, ...
                     'markerEvery', {2,2,2});

nScen = numel(panelInfo);
ncols = min(2, nScen);
nrows = ceil(nScen / ncols);

fig = figure('Visible','off','Position',[100 100 500*ncols 360*nrows+100], 'Color','w');
tl = tiledlayout(fig, nrows, ncols, 'TileSpacing','loose', 'Padding','normal');

legHandles = gobjects(0);
legLabels  = {};

for pk = 1:numel(panelInfo)
    pInfo = panelInfo(pk);
    ax = nexttile(tl);
    hold(ax, 'on');
    set(ax, 'FontName','Times New Roman', 'FontSize', 10, 'LineWidth', 0.75, ...
        'TickDir','out', 'Box','off', 'XScale','log');

    scMask = strcmp(T.scenario, pInfo.name);
    fAll = T.freqHz(scMask);
    xlim(ax, [min(fAll)*0.9, max(fAll)*1.1]);

    yline(ax, 0, ':', 'Color', [0.6 0.6 0.6], 'LineWidth', 0.8);

    for ci = 1:numel(ctrlStyles)
        mask = scMask & strcmp(T.controller, ctrlStyles(ci).name);
        if ~any(mask), continue; end
        sub = sortrows(T(mask,:), 'freqHz');
        % Phase lag convention in the CSV: positive = output LAGS setpoint.
        % Plot as negative-going "phase lag (deg)" so a bigger downward
        % excursion reads as more lag, consistent with the gain panels.
        h = plot(ax, sub.freqHz, -sub.phaseLagDeg, ctrlStyles(ci).lineStyle, ...
            'Color', 'k', 'LineWidth', 1.15, ...
            'Marker', ctrlStyles(ci).marker, 'MarkerIndices', 1:ctrlStyles(ci).markerEvery:height(sub), ...
            'MarkerSize', 5.5, 'MarkerFaceColor', 'k');

        if pk == 1
            legHandles(end+1) = h; %#ok<AGROW>
            legLabels{end+1}  = ctrlStyles(ci).label; %#ok<AGROW>
        end
    end

    xlabel(ax, 'Frequency (Hz)', 'FontName','Times New Roman', 'FontSize', 10);
    ylabel(ax, 'Phase (deg, negative = lag)', 'FontName','Times New Roman', 'FontSize', 10);
    title(ax, pInfo.title, 'FontName','Times New Roman', 'FontSize', 10.5, 'FontWeight','normal');
    text(ax, -0.16, 1.12, panelLabel(pk), 'Units','normalized', 'FontName','Helvetica', ...
        'FontSize', 13, 'FontWeight','bold', 'VerticalAlignment','top', 'Clipping','off');
end

lg = legend(legHandles, legLabels, 'Orientation','horizontal', 'NumColumns', 3, ...
    'FontName','Times New Roman', 'FontSize', 9, 'Box','off');
lg.Layout.Tile = 'north';
title(tl, 'Closed-loop phase response: with vs. without preview', ...
    'FontName','Times New Roman', 'FontSize', 12, 'FontWeight','bold');

pngPath = fullfile(outDir, 'fig_bandwidth_phase.png');
pdfPath = fullfile(outDir, 'fig_bandwidth_phase.pdf');
exportgraphics(fig, pngPath, 'Resolution', 400);
exportgraphics(fig, pdfPath, 'ContentType', 'vector');
close(fig);

fprintf('Saved %s\nSaved %s\n', pngPath, pdfPath);

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
