function sp = makeSetpoint(t, p)
%MAKESETPOINT  Compute setpoint trajectory: base DC + stacked waveform rows.
%   Each row of p.setpoints: {Enable, Type, Amp(nm), Period(s), Start(s), Dur(s)}
%   Types: Step | Sine | Square | Sawtooth | Triangle | Random | Noise
    sp = ones(size(t)) * p.sp_dc;
    if isempty(p.setpoints), return; end
    for ii = 1:size(p.setpoints, 1)
        row    = p.setpoints(ii,:);
        if ~row{1}, continue; end
        amp    = row{3};
        period = max(row{4}, 1e-9);
        t0     = row{5};
        dur    = row{6};
        freq   = 1 / period;
        if dur <= 0
            mask = t >= t0;
        else
            mask = t >= t0 & t < t0 + dur;
        end
        if ~any(mask), continue; end
        phi = (t(mask) - t0) * freq;
        switch row{2}
            case 'Step'
                seg = amp * ones(size(phi));
            case 'Sine'
                seg = amp * sin(2*pi * phi);
            case 'Square'
                seg = amp * sign(sin(2*pi * phi));
            case 'Sawtooth'
                seg = amp * (2*mod(phi,1) - 1);
            case 'Triangle'
                seg = amp * (1 - 4*abs(mod(phi+0.25,1) - 0.5));
            case 'Random'
                % Piecewise-constant; new value every Period
                stepIdx = floor(phi) + 1;
                nSt     = max(stepIdx) + 1;
                s       = RandStream('mt19937ar','Seed', ii * 3571);
                vals    = amp * (2*rand(s, nSt, 1) - 1);   % column → seg stays column
                seg     = vals(min(stepIdx, numel(vals)));
            case 'Noise'
                % Gaussian white noise; Amp = RMS; Period ignored
                s   = RandStream('mt19937ar','Seed', ii * 7919);
                seg = amp * randn(s, size(phi));
            otherwise
                seg = zeros(size(phi));
        end
        sp(mask) = sp(mask) + seg;
    end
end
