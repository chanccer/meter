function simulate()
%SIMULATE  Interactive Piezo PID Simulation GUI  (MATLAB 2026a)
%
%   Launch from MATLAB Command Window:
%       simulate()
%
%   Unit tests (no GUI required — uses +sim package functions directly):
%       results = runtests('test_simulate');  table(results)
%
%   Layout
%   ------
%   Left panel  : numeric input fields for plant / PID / delay /
%                 setpoint / disturbance / noise / simulation parameters
%   Right panel : 4 live subplots + axis-limit controls + status bar
%   Buttons     : Run | IMC Auto-tune | Auto-tune+Run | Reset | Export
%
%   Simulation model
%   ----------------
%   Plant      : FOPDT  G(s) = K·exp(-θs) / (τs+1)
%   Controller : Discrete-time PI with anti-windup
%   Time steps : 1 µs plant integration (Euler), configurable controller DT
%   Delays     : Circular buffers for plant dead time and feedback delay
%   Setpoint   : Configurable waveform generator (Step/Sine/Square/…)
%   Disturbance: Stackable waveform generator (Sine/Square/Sawtooth/…)

% ------------------------------------------------------------------ config file
CONFIG_FILE = fullfile(fileparts(mfilename('fullpath')), 'simulate_config.json');

% ------------------------------------------------------------------ defaults / load persisted config
p = sim.loadConfig(CONFIG_FILE);

% ------------------------------------------------------------------ figure
fig = uifigure('Name','Piezo PID Simulation', ...
               'Position',[60 60 1340 810]);
fig.CloseRequestFcn = @(~,~) onClose();

mainGL = uigridlayout(fig, [1 2]);
mainGL.ColumnWidth   = {300 '1x'};
mainGL.Padding       = [4 4 4 4];
mainGL.ColumnSpacing = 6;

% ------------------------------------------------------------------ LEFT panel
leftPanel = uipanel(mainGL, 'Title','Parameters');
NROWS = 36;
rh = repmat({22}, 1, NROWS);
rh{22} = 120;   % setpoint table
rh{23} = 24;    % setpoint add/remove buttons
rh{25} = 120;   % disturbance table
rh{26} = 24;    % disturbance add/remove buttons
innerGL = uigridlayout(leftPanel, [NROWS 2]);
innerGL.Scrollable   = 'on';    % grid layout owns the scroll, not the panel
innerGL.ColumnWidth  = {140 110};
innerGL.RowHeight    = rh;
innerGL.Padding      = [6 6 6 6];
innerGL.RowSpacing   = 3;
innerGL.ColumnSpacing = 4;

% ------------------------------------------------------------------ RIGHT panel
rightPanel = uipanel(mainGL);
rightGL = uigridlayout(rightPanel, [5 2]);
rightGL.RowHeight    = {'1x','1x',38,24,72,130};
rightGL.ColumnWidth  = {'1x','1x'};
rightGL.Padding      = [4 4 4 4];
rightGL.RowSpacing   = 6;
rightGL.ColumnSpacing = 6;

axDisp = uiaxes(rightGL);  axDisp.Layout.Row=1; axDisp.Layout.Column=1;
axErr  = uiaxes(rightGL);  axErr.Layout.Row=1;  axErr.Layout.Column=2;
axVolt = uiaxes(rightGL);  axVolt.Layout.Row=2; axVolt.Layout.Column=1;
axDist = uiaxes(rightGL);  axDist.Layout.Row=2; axDist.Layout.Column=2;

for ax = [axDisp axErr axVolt axDist]
    grid(ax,'on');  xlabel(ax,'Time (s)');  box(ax,'on');
end
title(axDisp,'Displacement (nm)');      ylabel(axDisp,'nm');
title(axErr, 'Positioning Error (nm)'); ylabel(axErr,'nm');
title(axVolt,'Control Voltage (V)');    ylabel(axVolt,'V');
title(axDist,'Disturbance (nm)');       ylabel(axDist,'nm');

% Link X axes: scrolling time-axis zooms all 4 plots in sync
linkaxes([axDisp, axErr, axVolt, axDist], 'x');

% Keep only export + data-cursor in each axes toolbar; scroll+drag handle zoom/pan
for ax = [axDisp, axErr, axVolt, axDist]
    axtoolbar(ax, {'export', 'datacursor'});
end

% Button row (rightGL row 3)
btnGL = uigridlayout(rightGL, [1 8]);
btnGL.Layout.Row = 3;  btnGL.Layout.Column = [1 2];
btnGL.ColumnWidth  = {138, 148, 140, 82, 90, 100, 90, 115};
btnGL.Padding      = [2 2 2 2];
btnGL.ColumnSpacing = 6;

uibutton(btnGL,'Text','▶  Run Simulation','FontWeight','bold', ...
    'BackgroundColor',[0.18 0.46 0.82],'FontColor','white', ...
    'ButtonPushedFcn',@(~,~) onRun());                              %#ok<NASGU>
uibutton(btnGL,'Text','IMC Auto-tune', ...
    'ButtonPushedFcn',@(~,~) onAutotune());                         %#ok<NASGU>
uibutton(btnGL,'Text','Auto-tune + Run', ...
    'BackgroundColor',[0.20 0.58 0.30],'FontColor','white', ...
    'ButtonPushedFcn',@(~,~) onAutotuneRun());                      %#ok<NASGU>
uibutton(btnGL,'Text','Reset', ...
    'ButtonPushedFcn',@(~,~) onReset());                            %#ok<NASGU>
uibutton(btnGL,'Text','Load LUT…', ...
    'ButtonPushedFcn',@(~,~) onLoadLUT());                          %#ok<NASGU>
uibutton(btnGL,'Text','Export…', ...
    'ButtonPushedFcn',@(~,~) onExport());                           %#ok<NASGU>
uibutton(btnGL,'Text','Save Config', ...
    'ButtonPushedFcn',@(~,~) onSaveConfig());                       %#ok<NASGU>
cbDistErr = uicheckbox(btnGL, 'Text', 'Dist on Error', 'Value', false, ...
    'FontSize', 9, 'ValueChangedFcn', @(~,~) onDistErrToggle());    %#ok<NASGU>

% Row 4: dynamic tracking overlay checkboxes
trackGL = uigridlayout(rightGL, [1 5]);
trackGL.Layout.Row = 4;  trackGL.Layout.Column = [1 2];
trackGL.ColumnWidth  = {120, 110, 100, 105, '1x'};
trackGL.Padding      = [6 2 6 2];
trackGL.ColumnSpacing = 10;
uilabel(trackGL, 'Text', 'Error overlay:', 'FontSize', 9, ...
    'HorizontalAlignment', 'right', 'FontColor', [0.35 0.35 0.35]);
cbNormRMS  = uicheckbox(trackGL, 'Text', 'Norm RMS %',  'Value', false, ...
    'FontSize', 9, 'ValueChangedFcn', @(~,~) onTrackOverlay());
cbPhaseLag = uicheckbox(trackGL, 'Text', 'Phase lag',   'Value', false, ...
    'FontSize', 9, 'ValueChangedFcn', @(~,~) onTrackOverlay());
cbAmpRatio = uicheckbox(trackGL, 'Text', 'Amp ratio',   'Value', false, ...
    'FontSize', 9, 'ValueChangedFcn', @(~,~) onTrackOverlay());
cbMinApp   = uicheckbox(trackGL, 'Text', 'Min approach','Value', false, ...
    'FontSize', 9, 'ValueChangedFcn', @(~,~) onTrackOverlay());

% Row 5: performance metrics panel
metricsArea = uitextarea(rightGL, ...
    'Value', {'Run a simulation to see step-response metrics.'}, ...
    'Editable', false, 'FontSize', 9, 'FontColor', [0.15 0.15 0.15], ...
    'BackgroundColor', [0.97 0.97 0.97]);
metricsArea.Layout.Row = 5;  metricsArea.Layout.Column = [1 2];

% Row 6: scrollable log — retains full message history
logArea = uitextarea(rightGL, ...
    'Value', {[datestr(now,'HH:MM:SS') '  Ready — press ▶ Run Simulation']}, ...
    'Editable', false, 'FontSize', 8.5, 'FontColor', [0.2 0.2 0.2], ...
    'BackgroundColor', [0.95 0.98 1.00]);
logArea.Layout.Row = 6;  logArea.Layout.Column = [1 2];

% ================================================================== LEFT: fields
R = 0;   % row counter (shared by nested helpers below)

    function sectionLabel(name)
        R = R + 1;
        lbl = uilabel(innerGL,'Text',name,'FontWeight','bold', ...
                      'FontColor',[0.1 0.35 0.75]);
        lbl.Layout.Row = R;  lbl.Layout.Column = [1 2];
    end

    function ef = mkField(label, lo, hi, val)
        R = R + 1;
        ll = uilabel(innerGL,'Text',label,'HorizontalAlignment','right','FontSize',10);
        ll.Layout.Row = R;  ll.Layout.Column = 1;
        ef = uieditfield(innerGL,'numeric','Value',val,'FontSize',10, ...
                         'HorizontalAlignment','center', ...
                         'Limits',[lo hi],'LowerLimitInclusive','on', ...
                         'UpperLimitInclusive','on');
        ef.Layout.Row = R;  ef.Layout.Column = 2;
    end

    function dd = mkDropdown(label, items, val)
        R = R + 1;
        ll = uilabel(innerGL,'Text',label,'HorizontalAlignment','right','FontSize',10);
        ll.Layout.Row = R;  ll.Layout.Column = 1;
        dd = uidropdown(innerGL,'Items',items,'Value',val,'FontSize',10);
        dd.Layout.Row = R;  dd.Layout.Column = 2;
    end

% ── Rows 1-7: Plant (Piezo) — all piezo parameters in one place ─────────────
sectionLabel('Plant (Piezo)');
sK      = mkField('K  (nm/V)',         0,   1e7,  p.K);
sTau    = mkField('τ  (µs)',            0,   1e9,  p.tau_us);
sTh     = mkField('θ_piezo (µs)',       0,   1e9,  p.theta_us);
sVdead  = mkField('V dead (V)',         0,   1000, p.v_dead);
sHyst   = mkField('Hysteresis (nm)',    0,   1e7,  p.hysteresis_nm);
sNoise  = mkField('Noise RMS (nm)',     0,   1e7,  p.noise);

% ── Rows 8-13: Controller ───────────────────────────────────────────────────
sectionLabel('Controller');
sCtrl = mkDropdown('Mode', {'PID','ADRC'}, p.ctrl_mode);
sKp   = mkField('Kp',          0,   1e6,  p.kp);
sKi   = mkField('Ki',          0,   1e6,  p.ki);
sKd   = mkField('Kd',          0,   1e6,  p.kd);
sDN   = mkField('D filter N',  0,   1e6,  p.d_filter_n);

% ── Rows 14-17: ADRC ────────────────────────────────────────────────────────
sectionLabel('ADRC');
sWc    = mkField('ω_c  (rad/s)',  0,   1e9,  p.adrc_wc);
sW0    = mkField('ω₀   (rad/s)', 0,   1e9,  p.adrc_w0);
smithItems = {'On','Off'};
sSmith = mkDropdown('Smith Predictor', smithItems, smithItems{2 - p.smith_adrc});
sSmith.ValueChangedFcn = @(~,~) onSmithToggle();

% ── Row 18-19: Feedback delay ───────────────────────────────────────────────
sectionLabel('Feedback Delay');
sDel = mkField('θ_protocol (µs)', 0,   1e9,  p.delay_us);

% ── Rows 20-23: Setpoint generator ─────────────────────────────────────────
sectionLabel('Setpoint');
sSPdc = mkField('Base DC (nm)', -1e9, 1e9,  p.sp_dc);

selectedSPRow = 0;
R = R + 1;   % R=22: setpoint table
tblSP = uitable(innerGL, ...
    'Data',           p.setpoints, ...
    'ColumnName',     {'En','Type','Amp (nm)','Period (s)','Start (s)','Dur (s)'}, ...
    'ColumnEditable', [true true true true true true], ...
    'ColumnFormat',   {'logical',{'Step','Sine','Square','Sawtooth','Triangle','Random','Noise'}, ...
                       'numeric','numeric','numeric','numeric'}, ...
    'ColumnWidth',    {28,72,58,64,58,52}, ...
    'RowName',        [], ...
    'Tooltip',        'Step: constant Amp. Random: ±Amp steps every Period s. Noise: Gaussian RMS=Amp. Dur=0→until end', ...
    'SelectionChangedFcn', @(~,evt) onSelectSPRow(evt));
tblSP.Layout.Row = R;  tblSP.Layout.Column = [1 2];

R = R + 1;   % R=23: SP buttons
spbGL = uigridlayout(innerGL,[1 2]);
spbGL.Layout.Row = R;  spbGL.Layout.Column = [1 2];
spbGL.Padding = [0 0 0 0];  spbGL.ColumnSpacing = 4;
uibutton(spbGL,'Text','+ Add SP',    'FontSize',8,'ButtonPushedFcn',@(~,~) onAddSP());    %#ok<NASGU>
uibutton(spbGL,'Text','− Remove SP', 'FontSize',8,'ButtonPushedFcn',@(~,~) onRemoveSP()); %#ok<NASGU>

% ── Rows 24-26: Disturbance generator ──────────────────────────────────────
sectionLabel('Disturbance');
selectedRow = 0;

R = R + 1;   % R=25: disturbance table
tblSig = uitable(innerGL, ...
    'Data',           p.signals, ...
    'ColumnName',     {'En','Type','Amp (nm)','Period (s)','Start (s)','Dur (s)'}, ...
    'ColumnEditable', [true true true true true true], ...
    'ColumnFormat',   {'logical',{'Sine','Square','Sawtooth','Triangle','Noise'}, ...
                       'numeric','numeric','numeric','numeric'}, ...
    'ColumnWidth',    {28,72,58,64,58,52}, ...
    'RowName',        [], ...
    'Tooltip',        'Noise: Gaussian white noise, Amp=RMS (Period ignored). Dur=0→until end', ...
    'SelectionChangedFcn', @(~,evt) onSelectRow(evt));
tblSig.Layout.Row = R;  tblSig.Layout.Column = [1 2];

R = R + 1;   % R=26: dist buttons
bgGL = uigridlayout(innerGL,[1 2]);
bgGL.Layout.Row = R;  bgGL.Layout.Column = [1 2];
bgGL.Padding = [0 0 0 0];  bgGL.ColumnSpacing = 4;
uibutton(bgGL,'Text','+ Add',    'FontSize',8,'ButtonPushedFcn',@(~,~) onAddSignal());    %#ok<NASGU>
uibutton(bgGL,'Text','− Remove', 'FontSize',8,'ButtonPushedFcn',@(~,~) onRemoveSignal()); %#ok<NASGU>

% ── Rows 27-30: Simulation ──────────────────────────────────────────────────
sectionLabel('Simulation');
sTot  = mkField('Duration (s)',        0,    1e6,  p.t_total);
sVmax = mkField('V max (V)',           0,    1e6,  p.v_max);
sDT   = mkField('Controller DT (µs)', 0,    1e9,  p.dt_pid_us);

% ── Rows 31-36: Bouc-Wen Hysteresis ────────────────────────────────────────
sectionLabel('Bouc-Wen Hysteresis');
bwItems = {'Off','On'};
sBWen   = mkDropdown('Enable', bwItems, bwItems{1 + p.bw_enable});
sBWA    = mkField('A  (pre-yield)',   0,    1e6,  p.bw_A);
sBWbeta = mkField('β  (dissipat.)',   0,    1e6,  p.bw_beta);
sBWgam  = mkField('γ  (restoring)',   0,    1e6,  p.bw_gamma);
sBWD    = mkField('D  (nm)',          0,    1e9,  p.bw_D);

% Apply initial controller mode state (enable/disable relevant fields)
% Inline the initial state — avoids calling a nested function before its
% definition is encountered in the sequential parse (MATLAB restriction).
if strcmp(p.ctrl_mode, 'ADRC')
    sKp.Enable='off'; sKi.Enable='off'; sKd.Enable='off'; sDN.Enable='off';
    sWc.Enable='on';  sW0.Enable='on';  sSmith.Enable='on';
else
    sKp.Enable='on';  sKi.Enable='on';  sKd.Enable='on';  sDN.Enable='on';
    sWc.Enable='off'; sW0.Enable='off'; sSmith.Enable='off';
end
sCtrl.ValueChangedFcn = @(dd,~) onCtrlModeChange(dd.Value);

% Last simulation output — lets overlay toggle redraw without re-running
simData = [];

% Independent axis zoom via scroll wheel:
%   Scroll        → X zoom on ALL plots (time axis, synchronized)
%   Shift+Scroll  → Y zoom on the hovered plot only
fig.WindowScrollWheelFcn = @onScroll;

% Pan via left-click drag:
%   Drag          → pan X (all linked) + Y (hovered plot only)
dragAx       = [];
dragInitXLim = [0, 1];
dragInitYLim = [0, 1];
dragInitPt   = [0, 0];
fig.WindowButtonDownFcn   = @onMouseDown;
fig.WindowButtonMotionFcn = @onMouseMove;
fig.WindowButtonUpFcn     = @onMouseUp;

% ================================================================== callbacks

    function readP()
        p.K              = sK.Value;
        p.tau_us         = sTau.Value;
        p.theta_us       = sTh.Value;
        p.v_dead         = sVdead.Value;
        p.hysteresis_nm  = sHyst.Value;
        p.noise          = sNoise.Value;
        p.ctrl_mode      = sCtrl.Value;
        p.kp             = sKp.Value;
        p.ki             = sKi.Value;
        p.kd             = sKd.Value;
        p.d_filter_n     = sDN.Value;
        p.adrc_wc        = sWc.Value;
        p.adrc_w0        = sW0.Value;
        p.smith_adrc     = strcmp(sSmith.Value, 'On');
        p.delay_us       = sDel.Value;
        p.sp_dc          = sSPdc.Value;
        p.setpoints      = tblSP.Data;
        p.signals        = tblSig.Data;
        p.v_max          = sVmax.Value;
        p.t_total        = sTot.Value;
        p.dt_pid_us      = sDT.Value;
        p.bw_enable      = strcmp(sBWen.Value, 'On');
        p.bw_A           = sBWA.Value;
        p.bw_beta        = sBWbeta.Value;
        p.bw_gamma       = sBWgam.Value;
        p.bw_D           = sBWD.Value;
    end

    function onRun()
        readP();
        smithNote = '';
        if strcmp(p.ctrl_mode,'ADRC') && p.smith_adrc, smithNote = ' [Smith ON]'; end
        appendLog(sprintf('Running %s%s simulation  (%.1f s)…', p.ctrl_mode, smithNote, p.t_total));
        try
            [t, yMeas, yTrue, vArr, errArr, distArr, spArr] = sim.runSim(p);
            [mStr, statusMsg, dynM] = sim.computeMetrics(t, errArr, spArr, yTrue);
            simData = struct('t',t,'yMeas',yMeas,'yTrue',yTrue,'vArr',vArr, ...
                             'errArr',errArr,'distArr',distArr,'spArr',spArr, ...
                             'dynMetrics',dynM);
            drawPlots(t, yMeas, yTrue, vArr, errArr, distArr, spArr);
            metricsArea.Value = mStr;
            appendLog(statusMsg);
        catch ME
            loc = '';
            if ~isempty(ME.stack)
                loc = sprintf(' [%s:%d]', ME.stack(1).name, ME.stack(1).line);
            end
            appendLog(['Error: ' ME.message loc]);
        end
    end

    function onDistErrToggle()
        if ~isempty(simData)
            drawPlots(simData.t, simData.yMeas, simData.yTrue, simData.vArr, ...
                      simData.errArr, simData.distArr, simData.spArr);
        end
    end

    function onTrackOverlay()
        if ~isempty(simData)
            drawErrOverlays();
        end
    end

    function onAutotune()
        readP();
        if strcmp(p.ctrl_mode, 'ADRC')
            g = sim.imcTune(p);
            sWc.Value = clampV(g.ADRC.adrc_wc, sWc.Limits);
            sW0.Value = clampV(g.ADRC.adrc_w0, sW0.Limits);
            smithTag = '';
            if p.smith_adrc, smithTag = ' [Smith]'; end
            appendLog(sprintf('ADRC%s auto-tune: ω_c=%.1f rad/s  ω₀=%.1f rad/s', ...
                smithTag, g.ADRC.adrc_wc, g.ADRC.adrc_w0));
        else
            g = sim.imcTune(p);
            sKp.Value = clampV(g.PID.kp,         sKp.Limits);
            sKi.Value = clampV(g.PID.ki,         sKi.Limits);
            sKd.Value = clampV(g.PID.kd,         sKd.Limits);
            sDN.Value = clampV(g.PID.d_filter_n, sDN.Limits);
            appendLog(sprintf('IMC-PID: Kp=%.5f  Ki=%.4f  Kd=%.5f  N=%d  (λ=2θ=%.0f µs)', ...
                g.PID.kp, g.PID.ki, g.PID.kd, g.PID.d_filter_n, ...
                2 * p.theta_us));
        end
    end

    function onSmithToggle()
        % When Smith is toggled, immediately re-tune so the gain change is visible.
        if strcmp(sCtrl.Value, 'ADRC')
            onAutotune();
        end
    end

    function onAutotuneRun()
        appendLog('── Auto-tune + Test ─────────────────────────────────');
        onAutotune();
        onRun();
    end

    function onReset()
        p0 = sim.defaultParams();
        sK.Value         = p0.K;
        sTau.Value       = p0.tau_us;
        sTh.Value        = p0.theta_us;
        sVdead.Value     = p0.v_dead;
        sHyst.Value      = p0.hysteresis_nm;
        sNoise.Value     = p0.noise;
        sCtrl.Value      = p0.ctrl_mode;
        sKp.Value        = p0.kp;
        sKi.Value        = p0.ki;
        sKd.Value        = p0.kd;
        sDN.Value        = p0.d_filter_n;
        sWc.Value        = p0.adrc_wc;
        sW0.Value        = p0.adrc_w0;
        sSmith.Value     = smithItems{2 - p0.smith_adrc};
        sDel.Value       = p0.delay_us;
        sSPdc.Value      = p0.sp_dc;
        tblSP.Data       = p0.setpoints;  selectedSPRow = 0;
        tblSig.Data      = p0.signals;    selectedRow   = 0;
        sTot.Value       = p0.t_total;
        sVmax.Value      = p0.v_max;
        sDT.Value        = p0.dt_pid_us;
        sBWen.Value      = bwItems{1 + p0.bw_enable};
        sBWA.Value       = p0.bw_A;
        sBWbeta.Value    = p0.bw_beta;
        sBWgam.Value     = p0.bw_gamma;
        sBWD.Value       = p0.bw_D;
        onCtrlModeChange(p0.ctrl_mode);
        appendLog('Parameters reset to defaults.');
    end

    function onLoadLUT()
        scriptDir = fileparts(mfilename('fullpath'));
        lutDir = fullfile(scriptDir, 'lut_output');
        if ~isfolder(lutDir), lutDir = scriptDir; end
        [fname, fpath] = uigetfile('*.csv', 'Load LUT CSV', lutDir);
        if isequal(fname, 0), return; end
        try
            tbl = readtable(fullfile(fpath, fname), 'TextType','string');
            upMask = strcmpi(tbl.direction, 'up');
            if ~any(upMask)
                appendLog('LUT: no up-sweep data found.');
                return;
            end
            vUp = tbl.voltage_V(upMask);
            dUp = tbl.mean_nm(upMask);
            cf       = polyfit(vUp, dUp, 1);
            kFromLUT = cf(1);   % fallback K from LUT slope

            tok = regexp(fname, '^lut_(\d{8}_\d{6})\.csv$', 'tokens');
            modelLoaded = false;
            if ~isempty(tok)
                ts = tok{1}{1};

                % ── Try companion model_<timestamp>.csv ───────────────────
                modelFile = fullfile(fpath, ['model_' ts '.csv']);
                if isfile(modelFile)
                    mTbl = readtable(modelFile);
                    vars = mTbl.Properties.VariableNames;
                    if ismember('K_nm_per_V', vars) && height(mTbl) > 0
                        row = mTbl(1,:);
                        sK.Value   = clampV(row.K_nm_per_V, sK.Limits);
                        if ismember('tau_us', vars)
                            sTau.Value = clampV(row.tau_us, sTau.Limits);
                        else
                            sTau.Value = clampV(row.tau_ms * 1000, sTau.Limits);
                        end

                        if ismember('theta_piezo_us', vars) && ismember('theta_protocol_us', vars)
                            sTh.Value  = clampV(row.theta_piezo_us,        sTh.Limits);
                            sDel.Value = clampV(row.theta_protocol_us,     sDel.Limits);
                            thetaStr   = sprintf('θ_piezo=%.1fµs  θ_proto=%.1fµs', ...
                                         row.theta_piezo_us, row.theta_protocol_us);
                        elseif ismember('theta_piezo_ms', vars) && ismember('theta_protocol_ms', vars)
                            sTh.Value  = clampV(row.theta_piezo_ms * 1000, sTh.Limits);
                            sDel.Value = clampV(row.theta_protocol_ms * 1000, sDel.Limits);
                            thetaStr   = sprintf('θ_piezo=%.1fµs  θ_proto=%.1fµs', ...
                                         row.theta_piezo_ms*1000, row.theta_protocol_ms*1000);
                        else
                            thetaStr  = sprintf('θ=%.1fµs (total)', row.theta_us);
                        end

                        if ismember('v_dead_V', vars)
                            sVdead.Value = clampV(row.v_dead_V, sVdead.Limits);
                        end
                        noiseVal = 0;
                        if ismember('noise_rms_nm', vars)
                            noiseVal = row.noise_rms_nm;
                            if noiseVal > 0
                                sNoise.Value = clampV(noiseVal, sNoise.Limits);
                            end
                        end
                        tStr = strjoin(arrayfun(@(x) sprintf('%.0f',x), ...
                               mTbl.temperature_C, 'UniformOutput',false), ', ');
                        appendLog(sprintf( ...
                            'LUT+Model: K=%.0f nm/V  τ=%.0f µs  %s  Vdead=%.2fV  noise≈%.1f nm | T=[%s]°C', ...
                            row.K_nm_per_V, sTau.Value, thetaStr, row.v_dead_V, noiseVal, tStr));
                        modelLoaded = true;
                    end
                end

                % ── Try companion summary_<timestamp>.csv for hysteresis ──
                summaryFile = fullfile(fpath, ['summary_' ts '.csv']);
                if isfile(summaryFile)
                    sTbl = readtable(summaryFile);
                    svars = sTbl.Properties.VariableNames;
                    if ismember('hysteresis_max_nm', svars) && height(sTbl) > 0
                        hystVal = mean(sTbl.hysteresis_max_nm);
                        if hystVal >= 0
                            sHyst.Value = clampV(hystVal, sHyst.Limits);
                            appendLog(sprintf('  Hysteresis (from summary): %.1f nm', hystVal));
                        end
                    end
                end
            end

            % ── Fallback: K only from LUT slope ──────────────────────────
            if ~modelLoaded
                sK.Value = clampV(kFromLUT, sK.Limits);
                temps = unique(tbl.temperature_C);
                tStr  = strjoin(arrayfun(@(x) sprintf('%.0f',x), temps, ...
                                'UniformOutput',false), ', ');
                appendLog(sprintf( ...
                    'LUT: K≈%.0f nm/V (slope) | %.0f–%.0f nm | T=[%s]°C  — 无 model 文件, τ/θ 未更新', ...
                    kFromLUT, min(dUp), max(dUp), tStr));
            end
        catch ME
            appendLog(['LUT load error: ' ME.message]);
        end
    end

    function onExport()
        [fname, fpath] = uiputfile( ...
            {'*.png','PNG image (*.png)'; ...
             '*.pdf','PDF document (*.pdf)'; ...
             '*.svg','SVG vector (*.svg)'; ...
             '*.eps','EPS vector (*.eps)'}, ...
            'Export simulation figure');
        if isequal(fname,0), return; end
        exportgraphics(fig, fullfile(fpath,fname), 'Resolution',300);
        appendLog(['Exported → ' fullfile(fpath,fname)]);
    end

    function onSaveConfig()
        readP();
        sim.saveConfig(CONFIG_FILE, p);
        appendLog(['Config saved → ' CONFIG_FILE]);
    end

    function onClose()
        readP();
        sim.saveConfig(CONFIG_FILE, p);
        delete(fig);
    end

    function onCtrlModeChange(mode)
        isPID  = strcmp(mode, 'PID');
        isADRC = strcmp(mode, 'ADRC');
        sKp.Enable    = onOffStr(isPID);
        sKi.Enable    = onOffStr(isPID);
        sKd.Enable    = onOffStr(isPID);
        sDN.Enable    = onOffStr(isPID);
        sWc.Enable    = onOffStr(isADRC);
        sW0.Enable    = onOffStr(isADRC);
        sSmith.Enable = onOffStr(isADRC);
    end

    function s = onOffStr(b)
        if b, s = 'on'; else, s = 'off'; end
    end

    function hitAx = findHoveredAx()
        % Pixel-based hit test: compare cursor position against each axes rect.
        % fig.CurrentPoint gives cursor in figure pixels (origin = bottom-left).
        % getpixelposition(..., true) gives screen-absolute pixels; subtract
        % figure origin to get figure-relative coords for comparison.
        hitAx  = [];
        pt     = fig.CurrentPoint;
        figScr = getpixelposition(fig, true);
        candAx = [axDisp, axErr, axVolt, axDist];
        for ii = 1:4
            ap = getpixelposition(candAx(ii), true);
            rx = ap(1) - figScr(1);
            ry = ap(2) - figScr(2);
            if pt(1) >= rx && pt(1) <= rx+ap(3) && ...
               pt(2) >= ry && pt(2) <= ry+ap(4)
                hitAx = candAx(ii);
                return;
            end
        end
    end

    function onScroll(~, evt)
        hitAx = findHoveredAx();
        if isempty(hitAx), return; end

        % 1.2× per scroll tick; positive VerticalScrollCount = wheel away = zoom out
        factor = 1.2 ^ double(evt.VerticalScrollCount);

        mods = fig.CurrentModifier;
        if ~isempty(mods) && any(strcmp(mods, 'shift'))
            % Shift+Scroll: Y zoom on hovered axis only
            yl = hitAx.YLim;
            cy = mean(yl);
            hitAx.YLim = cy + (yl - cy) * factor;
        else
            % Scroll: X zoom — update one axis; linkaxes propagates to all
            xl = hitAx.XLim;
            cx = mean(xl);
            hitAx.XLim = cx + (xl - cx) * factor;
        end
    end

    function onMouseDown(~, ~)
        if ~strcmp(fig.SelectionType, 'normal'), return; end  % left-click only
        ax = findHoveredAx();
        if isempty(ax), return; end
        dragAx       = ax;
        dragInitXLim = ax.XLim;
        dragInitYLim = ax.YLim;
        dragInitPt   = ax.CurrentPoint(1, 1:2);  % grab point in data coords
    end

    function onMouseMove(~, ~)
        if isempty(dragAx), return; end
        % Temporarily restore initial limits so CurrentPoint is in original data space,
        % then compute the shift needed to keep the grab point under the cursor.
        dragAx.XLim = dragInitXLim;
        dragAx.YLim = dragInitYLim;
        curPt  = dragAx.CurrentPoint(1, 1:2);
        shift  = dragInitPt - curPt;          % how far cursor moved in data coords
        dragAx.XLim = dragInitXLim + shift(1);  % linkaxes syncs X to all plots
        dragAx.YLim = dragInitYLim + shift(2);
    end

    function onMouseUp(~, ~)
        dragAx = [];
    end

    function appendLog(msg)
        ts   = datestr(now, 'HH:MM:SS');
        line = [ts '  ' msg];
        old  = logArea.Value;
        if ischar(old), old = {old}; end
        logArea.Value = [old(:); {line}];   % force column, then vertical concat
        scroll(logArea, 'bottom');
        drawnow limitrate;
    end

    function drawPlots(t, yMeas, yTrue, vArr, errArr, distArr, spArr)
        tLim = [0, p.t_total];

        cla(axDisp);  hold(axDisp,'on');
        plot(axDisp, t, yTrue, 'Color',[0.70 0.70 0.70],'LineWidth',0.8,'DisplayName','True');
        plot(axDisp, t, yMeas, 'Color',[0.18 0.46 0.82],'LineWidth',1.2,'DisplayName','Measured');
        plot(axDisp, t, spArr, 'r--','LineWidth',0.8,'DisplayName','Setpoint');
        legend(axDisp,'Location','southeast','FontSize',7);
        title(axDisp,'Displacement (nm)');
        xlabel(axDisp,'Time (s)');  ylabel(axDisp,'nm');
        grid(axDisp,'on');  hold(axDisp,'off');
        xlim(axDisp, tLim);
        niceYLim(axDisp, [yTrue; yMeas; spArr], 50);

        cla(axErr);  hold(axErr,'on');
        hE = plot(axErr, t, errArr, 'Color',[0.85 0.28 0.15],'LineWidth',1.2, ...
                  'DisplayName','Error');
        if cbDistErr.Value
            hD = plot(axErr, t, distArr, 'Color',[0.62 0.15 0.62],'LineWidth',1.0, ...
                      'LineStyle','--','DisplayName','Disturbance');
            legend(axErr, [hE, hD], 'Location','northeast','FontSize',7);
            half = max(max(abs([errArr; distArr])) * 1.10, 20);
        else
            legend(axErr, 'off');
            half = max(max(abs(errArr)) * 1.10, 20);
        end
        yline(axErr, 0,'k-','LineWidth',0.5,'HandleVisibility','off');
        title(axErr,'Positioning Error (nm)');
        xlabel(axErr,'Time (s)');  ylabel(axErr,'nm');
        grid(axErr,'on');  hold(axErr,'off');
        xlim(axErr, tLim);
        ylim(axErr, [-half, half]);
        drawErrOverlays();

        cla(axVolt);  hold(axVolt,'on');
        plot(axVolt, t, vArr,'Color',[0.15 0.62 0.15],'LineWidth',1.2);
        title(axVolt,'Control Voltage (V)');
        xlabel(axVolt,'Time (s)');  ylabel(axVolt,'V');
        grid(axVolt,'on');  hold(axVolt,'off');
        xlim(axVolt, tLim);
        ylim(axVolt, [0, p.v_max + 0.1]);

        cla(axDist);  hold(axDist,'on');
        plot(axDist, t, distArr,'Color',[0.62 0.15 0.62],'LineWidth',1.2);
        title(axDist,'Disturbance (nm)');
        xlabel(axDist,'Time (s)');  ylabel(axDist,'nm');
        grid(axDist,'on');  hold(axDist,'off');
        xlim(axDist, tLim);
        if max(abs(distArr)) < 1e-9
            ylim(axDist, [-1, 1]);
        else
            niceYLim(axDist, distArr, 1);
        end
    end

    function drawErrOverlays()
        % Remove previous overlay objects and redraw based on checkbox state
        delete(findobj(axErr, 'Tag','dynOverlay'));
        if isempty(simData), return; end
        m    = simData.dynMetrics;
        eArr = simData.errArr;
        n    = numel(eArr);
        tail = round(0.9*n):n;
        ssR  = sqrt(mean(eArr(tail).^2));

        hold(axErr,'on');
        yPos = 0.97;   % top-right stacking position (normalised axes units)

        % ── Norm RMS: ±SS_RMS band + text ──────────────────────────
        if cbNormRMS.Value
            yline(axErr,  ssR,'--','Color',[0.85 0.28 0.15],'LineWidth',0.9, ...
                  'HandleVisibility','off','Tag','dynOverlay');
            yline(axErr, -ssR,'--','Color',[0.85 0.28 0.15],'LineWidth',0.9, ...
                  'HandleVisibility','off','Tag','dynOverlay');
            if ~isnan(m.normRMS)
                lbl = sprintf('Norm RMS: %.1f%%', m.normRMS);
            else
                lbl = 'Norm RMS: N/A';
            end
            text(axErr, 0.98, yPos, lbl, 'Units','normalized', ...
                 'FontSize',8,'FontWeight','bold','HorizontalAlignment','right', ...
                 'Color',[0.85 0.28 0.15],'BackgroundColor',[0.97 0.97 0.97], ...
                 'Margin',2,'Tag','dynOverlay');
            yPos = yPos - 0.12;
        end

        % ── Phase lag: text annotation ──────────────────────────────
        if cbPhaseLag.Value
            if ~isnan(m.phaseLag_us)
                lbl = sprintf('Phase lag: %.0f µs', m.phaseLag_us);
            else
                lbl = 'Phase lag: N/A';
            end
            text(axErr, 0.98, yPos, lbl, 'Units','normalized', ...
                 'FontSize',8,'FontWeight','bold','HorizontalAlignment','right', ...
                 'Color',[0.10 0.45 0.75],'BackgroundColor',[0.97 0.97 0.97], ...
                 'Margin',2,'Tag','dynOverlay');
            yPos = yPos - 0.12;
        end

        % ── Amplitude ratio: text annotation ────────────────────────
        if cbAmpRatio.Value
            if ~isnan(m.ampRatio)
                lbl = sprintf('Amp ratio: %.1f%%', m.ampRatio);
            else
                lbl = 'Amp ratio: N/A';
            end
            text(axErr, 0.98, yPos, lbl, 'Units','normalized', ...
                 'FontSize',8,'FontWeight','bold','HorizontalAlignment','right', ...
                 'Color',[0.15 0.60 0.15],'BackgroundColor',[0.97 0.97 0.97], ...
                 'Margin',2,'Tag','dynOverlay');
            yPos = yPos - 0.12;
        end

        % ── Min approach: horizontal line + text ────────────────────
        if cbMinApp.Value
            yline(axErr,  m.minApproach_nm,':', 'Color',[0.55 0.25 0.65], ...
                  'LineWidth',1.2,'HandleVisibility','off','Tag','dynOverlay');
            yline(axErr, -m.minApproach_nm,':', 'Color',[0.55 0.25 0.65], ...
                  'LineWidth',1.2,'HandleVisibility','off','Tag','dynOverlay');
            lbl = sprintf('Min approach: %.1f nm', m.minApproach_nm);
            text(axErr, 0.98, yPos, lbl, 'Units','normalized', ...
                 'FontSize',8,'FontWeight','bold','HorizontalAlignment','right', ...
                 'Color',[0.55 0.25 0.65],'BackgroundColor',[0.97 0.97 0.97], ...
                 'Margin',2,'Tag','dynOverlay');
        end

        hold(axErr,'off');
    end

    function niceYLim(ax, data, minHalfSpan)
        lo  = min(data(:));
        hi  = max(data(:));
        pad = max((hi - lo) * 0.08, minHalfSpan * 0.08);
        lo  = lo - pad;
        hi  = hi + pad;
        if (hi - lo) < 2 * minHalfSpan
            mid = (hi + lo) / 2;
            lo  = mid - minHalfSpan;
            hi  = mid + minHalfSpan;
        end
        ylim(ax, [lo, hi]);
    end

    function v = clampV(v, lims)
        v = max(lims(1), min(lims(2), v));
    end

    % ---- setpoint generator helpers
    function onSelectSPRow(evt)
        if ~isempty(evt.Selection), selectedSPRow = evt.Selection(1); end
    end
    function onAddSP()
        tblSP.Data = [tblSP.Data; {true,'Step',1000,1.0,0.1,0.0}];
    end
    function onRemoveSP()
        n = size(tblSP.Data,1);
        if n == 0, return; end
        idx = selectedSPRow;
        if idx < 1 || idx > n, idx = n; end
        tblSP.Data(idx,:) = [];
        selectedSPRow = min(idx, size(tblSP.Data,1));
    end

    % ---- disturbance generator helpers
    function onSelectRow(evt)
        if ~isempty(evt.Selection), selectedRow = evt.Selection(1); end
    end
    function onAddSignal()
        tblSig.Data = [tblSig.Data; {true,'Sine',50,0.2,0.0,0.0}];
    end
    function onRemoveSignal()
        n = size(tblSig.Data,1);
        if n == 0, return; end
        idx = selectedRow;
        if idx < 1 || idx > n, idx = n; end
        tblSig.Data(idx,:) = [];
        selectedRow = min(idx, size(tblSig.Data,1));
    end


end % simulate
