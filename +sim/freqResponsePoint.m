function out = freqResponsePoint(p, freqHz, ampNm, dcNm, nCyclesSettle, nCyclesMeasure)
%FREQRESPONSEPOINT  Single-frequency closed-loop gain/phase via sine-fit.
%
%   Drives sim.runSim() with a pure sine setpoint at freqHz, discards the
%   first nCyclesSettle periods as transient, then fits
%   y(t) ~= A*cos(w t) + B*sin(w t) + C to both yTrue and the setpoint
%   over the remaining nCyclesMeasure periods (least squares) to extract
%   closed-loop gain (dB, 0 dB = perfect tracking) and phase lag (deg,
%   positive = output lags the setpoint).
%
%   out.gainDB, out.phaseLagDeg, out.vPeak, out.vTrough, out.saturated

    period      = 1 / freqHz;
    p.sp_dc     = dcNm;
    p.setpoints = {true, 'Sine', ampNm, period, 0, 0};
    p.t_total   = (nCyclesSettle + nCyclesMeasure) * period;

    [t, ~, yTrue, vArr, ~, ~, spArr] = sim.runSim(p);

    mask = t >= nCyclesSettle * period;
    tt = t(mask);  yy = yTrue(mask);  rr = spArr(mask);  vv = vArr(mask);

    w  = 2*pi*freqHz;
    X  = [cos(w*tt), sin(w*tt), ones(size(tt))];
    cY = X \ yy;
    cR = X \ rr;

    magY = hypot(cY(1), cY(2));
    magR = hypot(cR(1), cR(2));
    phY  = atan2(cY(2), cY(1));
    phR  = atan2(cR(2), cR(1));

    dPhi = phR - phY;
    dPhi = mod(dPhi + pi, 2*pi) - pi;   % wrap to (-pi, pi], no toolbox dependency

    out.gainDB      = 20*log10(max(magY,eps) / max(magR,eps));
    out.phaseLagDeg = rad2deg(dPhi);
    out.vPeak       = max(vv);
    out.vTrough     = min(vv);
    out.saturated   = (out.vPeak >= p.v_max - 1e-6) || (out.vTrough <= 1e-6);
end
