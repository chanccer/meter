function results = runHeadless(varargin)
%RUNHEADLESS  Run the Piezo PID/ADRC simulation with no GUI whatsoever.
%
%   results = sim.runHeadless()
%   results = sim.runHeadless('K', 500, 't_total', 1.0)
%   results = sim.runHeadless('ConfigFile', 'simulate_config.json', 'ctrl_mode', 'ADRC')
%   results = sim.runHeadless(paramsStruct)
%
%   Creates no uifigure/figure by default — safe to call under
%   `matlab -batch` on machines with no display server. Options
%   (name-value):
%
%     ConfigFile  - JSON config path to seed parameters (via sim.loadConfig).
%                   Default: '' (start from sim.defaultParams()).
%     SaveCSV     - file path; writes a time-series CSV
%                   (t, yMeas, yTrue, vArr, errArr, distArr, spArr).
%     SaveMAT     - file path; saves the full results struct via `save`.
%     Plot        - '' (default, no figure created) | 'png' | 'pdf' | 'svg' | 'eps'.
%     PlotFile    - output path for the plot. If set (with or without Plot),
%                   a figure is rendered off-screen ('Visible','off') and
%                   exported — no window is ever shown. Default when Plot is
%                   set but PlotFile isn't: 'sim_headless.<Plot>'.
%     Verbose     - true/false, print metrics/status text to console.
%                   Default: true.
%
%   Any other name matching a sim.defaultParams() field is applied as a
%   parameter override on top of the defaults/loaded config.
%
%   Returns a struct with fields:
%     t, yMeas, yTrue, vArr, errArr, distArr, spArr, dynMetrics,
%     metricsText, statusMsg, params

    % ---- base parameters: struct arg, ConfigFile, or defaults -------------
    if ~isempty(varargin) && isstruct(varargin{1})
        p = varargin{1};
        varargin(1) = [];
    else
        p = [];
    end

    opts = struct('ConfigFile','', 'SaveCSV','', 'SaveMAT','', ...
                  'Plot','', 'PlotFile','', 'Verbose', true);
    optNames = fieldnames(opts);

    if mod(numel(varargin), 2) ~= 0
        error('sim:runHeadless:badArgs', 'Name-value arguments must come in pairs.');
    end

    overrides = struct();
    for i = 1:2:numel(varargin)
        name = varargin{i};
        val  = varargin{i+1};
        if ~(ischar(name) || isstring(name))
            error('sim:runHeadless:badArgs', 'Argument names must be char/string.');
        end
        name = char(name);
        idx = find(strcmpi(optNames, name), 1);
        if ~isempty(idx)
            opts.(optNames{idx}) = val;
        else
            overrides.(name) = val;
        end
    end

    if isempty(p)
        if ~isempty(opts.ConfigFile)
            p = sim.loadConfig(opts.ConfigFile);
        else
            p = sim.defaultParams();
        end
    end

    ovNames = fieldnames(overrides);
    for i = 1:numel(ovNames)
        p.(ovNames{i}) = overrides.(ovNames{i});
    end

    % ---- run ---------------------------------------------------------------
    [t, yMeas, yTrue, vArr, errArr, distArr, spArr] = sim.runSim(p);
    [metricsText, statusMsg, dynMetrics] = sim.computeMetrics(t, errArr, spArr, yTrue);

    results = struct('t',t, 'yMeas',yMeas, 'yTrue',yTrue, 'vArr',vArr, ...
                      'errArr',errArr, 'distArr',distArr, 'spArr',spArr, ...
                      'dynMetrics',dynMetrics, 'metricsText',{metricsText}, ...
                      'statusMsg',statusMsg, 'params',p);

    if opts.Verbose
        fprintf('%s\n', statusMsg);
        for i = 1:numel(metricsText)
            fprintf('%s\n', metricsText{i});
        end
    end

    if ~isempty(opts.SaveCSV)
        tbl = table(t, yMeas, yTrue, vArr, errArr, distArr, spArr);
        writetable(tbl, opts.SaveCSV);
    end

    if ~isempty(opts.SaveMAT)
        save(opts.SaveMAT, '-struct', 'results');
    end

    if ~isempty(opts.Plot) || ~isempty(opts.PlotFile)
        if isempty(opts.PlotFile)
            ext = opts.Plot;
            if isempty(ext), ext = 'png'; end
            opts.PlotFile = ['sim_headless.' ext];
        end
        fig = figure('Visible','off');
        cleanupFig = onCleanup(@() close(fig));
        tl = tiledlayout(fig, 2, 2);

        ax1 = nexttile(tl);
        plot(ax1, t, yTrue, t, yMeas, t, spArr);
        title(ax1,'Displacement (nm)'); grid(ax1,'on');
        legend(ax1, {'True','Measured','Setpoint'}, 'Location','southeast');

        ax2 = nexttile(tl);
        plot(ax2, t, errArr);
        title(ax2,'Positioning Error (nm)'); grid(ax2,'on');

        ax3 = nexttile(tl);
        plot(ax3, t, vArr);
        title(ax3,'Control Voltage (V)'); grid(ax3,'on');

        ax4 = nexttile(tl);
        plot(ax4, t, distArr);
        title(ax4,'Disturbance (nm)'); grid(ax4,'on');

        exportgraphics(fig, opts.PlotFile, 'Resolution',300);
    end
end
