function cols = buildWaveformCols(cfg, sc, p0)
%BUILDWAVEFORMCOLS  One column (controller) per entry in
%   cfg.waveformControllers (see +sim/analysisConfig.m), in that order --
%   NOT hardcoded to "PID left, Preview right". An entry whose ctrl_mode
%   is 'ADRC' is skipped when sc.hasADRC is false (numerically invalid for
%   that scenario, e.g. scenario B -- see +sim/analysisConfig.m).
%
%   Shared by waveform_tracking_nature_all.m and
%   waveform_tracking_nature_split.m so there is exactly one place that
%   turns a ctrl_mode name into a runnable params struct (PID needs
%   sim.tunedPID() gains, ADRC needs sim.tunedADRC() gains + smith_adrc=1,
%   Preview needs nothing extra beyond ctrl_mode itself).
    ctrls = cfg.waveformControllers;
    cols = struct('name', {}, 'params', {}, 'lineStyle', {});
    for i = 1:numel(ctrls)
        c = ctrls(i);
        if strcmp(c.ctrl_mode, 'ADRC') && ~sc.hasADRC
            continue;
        end
        p = p0;
        p.ctrl_mode = c.ctrl_mode;
        switch c.ctrl_mode
            case 'PID'
                [kp, ki] = sim.tunedPID(p0);
                p.kp = kp; p.ki = ki; p.kd = 0; p.d_filter_n = 0;
            case 'ADRC'
                p.smith_adrc = 1;
                [wc, w0] = sim.tunedADRC(p0);
                p.adrc_wc = wc; p.adrc_w0 = w0;
            case 'Preview'
                % no extra tuning needed beyond ctrl_mode
        end
        cols(end+1) = struct('name', c.name, 'params', p, 'lineStyle', c.lineStyle); %#ok<AGROW>
    end
end
