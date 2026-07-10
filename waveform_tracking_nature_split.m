%WAVEFORM_TRACKING_NATURE_SPLIT  Black-and-white, journal/LaTeX-style
%   sine/square tracking figures, SPLIT into a normal-bandwidth-only
%   figure and a limit-bandwidth-only figure per scenario (rather than
%   the 8-panel combined overview from waveform_tracking_nature_all.m),
%   so a paper can cite "typical operating conditions" and "near the
%   bandwidth limit" as two separate figures.
%
%   Every scenario parameter and the PID/ADRC tuning formulas come from
%   +sim/analysisConfig.m / +sim/tunedPID.m / +sim/tunedADRC.m -- nothing
%   here is hardcoded. The controller list (which controllers appear, in
%   what order/column) comes from cfg.waveformControllers -- NOT hardcoded
%   to "PID left, Preview right": add/reorder/remove an entry there and
%   this script follows. An 'ADRC' entry is skipped per-scenario when that
%   scenario's hasADRC is false. The x-axis display window comes from
%   cfg.scenarios(i).plotWindowFrac ([0 1] = full simulated span).
%
%   Each figure is (rows x cols) panels, one row per wave type (Sine,
%   Square) and one column per entry in cfg.waveformControllers.
%
%   Output, all under paper_figures/:
%     fig_waveform_<scenario>_normal.pdf/.png   4 panels, normal bandwidth
%     fig_waveform_<scenario>_limit.pdf/.png    4 panels, limit bandwidth
%     data_waveform_<scenario>_normal.csv       matching time-series data
%     data_waveform_<scenario>_limit.csv

clear; clc;
outDir = fullfile(fileparts(mfilename('fullpath')), 'paper_figures');
if ~exist(outDir, 'dir'), mkdir(outDir); end

cfg = sim.analysisConfig();
scenarios = cfg.scenarios;

regimes = struct('key', {'normal','limit'}, ...
                  'label', {'normal bandwidth','limit bandwidth'}, ...
                  'freqField', {'normalHz','limitHz'}, ...
                  'cycles', {cfg.waveformCycles.normal, cfg.waveformCycles.limit});

for si = 1:numel(scenarios)
    sc = scenarios(si);

    p0 = sim.defaultParams();
    p0.K              = cfg.plant.K;
    p0.noise          = cfg.plant.noise;
    p0.v_max          = cfg.plant.v_max;
    p0.hysteresis_nm  = cfg.plant.hysteresis_nm;
    pf = fieldnames(sc.params);
    for i = 1:numel(pf), p0.(pf{i}) = sc.params.(pf{i}); end

    cols = sim.buildWaveformCols(cfg, sc, p0);

    for gi = 1:numel(regimes)
        rg = regimes(gi);
        freq = sc.(rg.freqField);
        fprintf('=== %s / %s (%g Hz) ===\n', sc.name, rg.key, freq);

        rows = struct([]);
        rows(1).wave = 'Sine';   rows(1).cycles = rg.cycles.sine;
        rows(2).wave = 'Square'; rows(2).cycles = rg.cycles.square;

        % Grid dimensions and figure size derive from numel(rows)/numel(cols)
        % rather than assuming exactly 2 rows x 2 cols.
        fig = figure('Visible','off','Position',[100 100 500*numel(cols) 340*numel(rows)], 'Color','w');
        tl = tiledlayout(fig, numel(rows), numel(cols), 'TileSpacing','loose', 'Padding','normal');

        dataRows = {};
        li = 0;
        for ri = 1:numel(rows)
            rw = rows(ri);
            tTotal = sc.t0 + rw.cycles/freq;

            for ci = 1:numel(cols)
                li = li + 1;
                ax = nexttile(tl);
                hold(ax, 'on');
                set(ax, 'FontName','Times New Roman', 'FontSize', 10, 'LineWidth', 0.75, ...
                    'TickDir','out', 'Box','off', 'TickLength',[0.012 0.012]);

                p = cols(ci).params;
                p.sp_dc = sc.dcNm;
                p.setpoints = {true, rw.wave, sc.ampNm, 1/freq, sc.t0, 0};
                p.t_total = tTotal;
                [t, ~, yTrue, ~, ~, ~, spArr] = sim.runSim(p);

                hSp = plot(ax, t*1000, spArr, ':', 'Color', 'k', 'LineWidth', 0.8);
                hY  = plot(ax, t*1000, yTrue, cols(ci).lineStyle, 'Color', 'k', 'LineWidth', 1.0);

                xlim(ax, sc.plotWindowFrac * tTotal * 1000);
                xlabel(ax, 'Time (ms)', 'FontName','Times New Roman', 'FontSize', 10);
                ylabel(ax, 'Displacement (nm)', 'FontName','Times New Roman', 'FontSize', 10);
                title(ax, sprintf('%s -- %s (%g Hz)', cols(ci).name, rw.wave, freq), ...
                    'FontName','Times New Roman', 'FontSize', 10, 'FontWeight','normal');
                text(ax, -0.15, 1.14, panelLabel(li), 'Units','normalized', 'FontName','Helvetica', ...
                    'FontSize', 13, 'FontWeight','bold', 'VerticalAlignment','top', 'Clipping','off');

                if li == 1, legHandles = [hSp, hY]; end

                strideCSV = max(1, round(numel(t)/2000));
                idxCSV = 1:strideCSV:numel(t);
                for jj = idxCSV
                    dataRows(end+1,:) = {panelLabel(li), cols(ci).name, rw.wave, rg.label, freq, ...
                        t(jj)*1000, spArr(jj), yTrue(jj)}; %#ok<SAGROW>
                end
            end
        end

        lg = legend(legHandles, {'setpoint r(t)','controller output y(t)'}, ...
            'Orientation','horizontal', 'FontName','Times New Roman', 'FontSize', 9, 'Box','off');
        lg.Layout.Tile = 'north';
        title(tl, sprintf('%s -- %s', sc.title, rg.label), ...
            'FontName','Times New Roman', 'FontSize', 11, 'FontWeight','bold', 'Interpreter','tex');

        base = sprintf('fig_waveform_%s_%s', sc.name, rg.key);
        pdfPath = fullfile(outDir, [base '.pdf']);
        pngPath = fullfile(outDir, [base '.png']);
        exportgraphics(fig, pngPath, 'Resolution', 400);
        exportgraphics(fig, pdfPath, 'ContentType', 'vector');
        close(fig);

        csvPath = fullfile(outDir, sprintf('data_waveform_%s_%s.csv', sc.name, rg.key));
        Tdata = cell2table(dataRows, 'VariableNames', ...
            {'panel','controller','wave','band','freq_Hz','t_ms','setpoint_nm','displacement_nm'});
        writetable(Tdata, csvPath);

        fprintf('  Saved %s\n  Saved %s\n  Saved %s\n', pdfPath, pngPath, csvPath);
    end
end

fprintf('\nDone.\n');

function s = panelLabel(idx)
%PANELLABEL  a, b, c, ..., z, aa, ab, ... for panel idx (1-based) -- scales
%   to any number of rows*cols instead of assuming exactly 4 (a-d).
    s = '';
    while idx > 0
        idx = idx - 1;
        s = [char('a' + mod(idx,26)), s]; %#ok<AGROW>
        idx = floor(idx/26);
    end
end
