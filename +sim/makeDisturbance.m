function d = makeDisturbance(t, p)
%MAKEDISTURBANCE  Sum all enabled disturbance waveform rows.
%   Each row of p.signals: {Enable, Type, Amp(nm), Period(s), Start(s), Dur(s)}
%   Types: Sine | Square | Sawtooth | Triangle | Noise
    d = zeros(size(t));
    if isempty(p.signals), return; end
    for ii = 1:size(p.signals, 1)
        row    = p.signals(ii,:);
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
            case 'Sine'
                seg = amp * sin(2*pi * phi);
            case 'Square'
                seg = amp * sign(sin(2*pi * phi));
            case 'Sawtooth'
                seg = amp * (2*mod(phi,1) - 1);
            case 'Triangle'
                seg = amp * (1 - 4*abs(mod(phi+0.25,1) - 0.5));
            case 'Noise'
                % Gaussian white noise; Amp = RMS; Period ignored
                s   = RandStream('mt19937ar','Seed', ii * 7919);
                seg = amp * randn(s, size(phi));
            otherwise
                seg = zeros(size(phi));
        end
        d(mask) = d(mask) + seg;
    end
end
