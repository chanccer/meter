function p = loadConfig(configPath)
%LOADCONFIG  Load params from JSON; missing/corrupt fields fall back to defaults.

    p = sim.defaultParams();
    if ~isfile(configPath), return; end
    try
        cfg = jsondecode(fileread(configPath));
        scalarFields = {'K','tau_us','theta_us','v_dead','hysteresis_nm', ...
                        'kp','ki','kd','d_filter_n','adrc_wc','adrc_w0', ...
                        'smith_adrc','delay_us','sp_dc','noise','v_max','t_total','dt_pid_us', ...
                        'bw_enable','bw_A','bw_beta','bw_gamma','bw_D'};
        for i = 1:numel(scalarFields)
            f = scalarFields{i};
            if isfield(cfg, f)
                p.(f) = double(cfg.(f));
            end
        end
        % Backward compatibility: old configs stored delays/time in ms
        if isfield(cfg, 'tau_ms') && ~isfield(cfg, 'tau_us')
            p.tau_us = double(cfg.tau_ms) * 1000;
        end
        if isfield(cfg, 'theta_ms') && ~isfield(cfg, 'theta_us')
            p.theta_us = double(cfg.theta_ms) * 1000;
        end
        if isfield(cfg, 'dt_pid_ms') && ~isfield(cfg, 'dt_pid_us')
            p.dt_pid_us = double(cfg.dt_pid_ms) * 1000;
        end

        if isfield(cfg, 'ctrl_mode') && ischar(cfg.ctrl_mode)
            p.ctrl_mode = cfg.ctrl_mode;
        end
        if isfield(cfg, 'setpoints') && ~isnumeric(cfg.setpoints)
            p.setpoints = jsonToCell(cfg.setpoints);
        end
        if isfield(cfg, 'signals') && ~isnumeric(cfg.signals)
            p.signals = jsonToCell(cfg.signals);
        end
    catch
        % return defaults on any parse error
    end
end

% -----------------------------------------------------------------------
function c = jsonToCell(arr)
    if isempty(arr) || isnumeric(arr)
        c = {};
        return;
    end
    n = numel(arr);
    c = cell(n, 6);
    for i = 1:n
        c{i,1} = logical(arr(i).en);
        c{i,2} = char(arr(i).type);
        c{i,3} = double(arr(i).amp);
        c{i,4} = double(arr(i).period);
        c{i,5} = double(arr(i).t0);
        c{i,6} = double(arr(i).dur);
    end
end
