function saveConfig(configPath, p)
%SAVECONFIG  Write params struct to a human-readable JSON file.

    try
        cfg.K             = p.K;
        cfg.tau_us        = p.tau_us;
        cfg.theta_us      = p.theta_us;
        cfg.v_dead        = p.v_dead;
        cfg.hysteresis_nm = p.hysteresis_nm;
        cfg.noise         = p.noise;
        cfg.ctrl_mode     = p.ctrl_mode;
        cfg.kp            = p.kp;
        cfg.ki            = p.ki;
        cfg.kd            = p.kd;
        cfg.d_filter_n    = p.d_filter_n;
        cfg.adrc_wc       = p.adrc_wc;
        cfg.adrc_w0       = p.adrc_w0;
        cfg.smith_adrc    = p.smith_adrc;
        cfg.prev_kp       = p.prev_kp;
        cfg.prev_ki       = p.prev_ki;
        cfg.delay_us      = p.delay_us;
        cfg.sp_dc         = p.sp_dc;
        cfg.v_max         = p.v_max;
        cfg.t_total       = p.t_total;
        cfg.dt_pid_us     = p.dt_pid_us;
        cfg.fs_sample_hz  = p.fs_sample_hz;
        cfg.bw_enable     = p.bw_enable;
        cfg.bw_A          = p.bw_A;
        cfg.bw_beta       = p.bw_beta;
        cfg.bw_gamma      = p.bw_gamma;
        cfg.bw_D          = p.bw_D;
        cfg.setpoints     = cellToJson(p.setpoints);
        cfg.signals       = cellToJson(p.signals);
        fid = fopen(configPath, 'w', 'n', 'UTF-8');
        if fid == -1, return; end
        fprintf(fid, '%s', jsonencode(cfg, 'PrettyPrint', true));
        fclose(fid);
    catch
        % silently ignore write errors (read-only filesystem, etc.)
    end
end

% -----------------------------------------------------------------------
function arr = cellToJson(c)
    arr = struct('en',{},'type',{},'amp',{},'period',{},'t0',{},'dur',{});
    if isempty(c), return; end
    for i = 1:size(c, 1)
        arr(i).en     = logical(c{i,1});
        arr(i).type   = char(c{i,2});
        arr(i).amp    = double(c{i,3});
        arr(i).period = double(c{i,4});
        arr(i).t0     = double(c{i,5});
        arr(i).dur    = double(c{i,6});
    end
end
