function [lines, statusMsg, dynMetrics] = computeMetrics(t, errArr, spArr, yTrue)
%COMPUTEMETRICS  Step-response metrics + dynamic tracking metrics.
%   dynMetrics.normRMS     – SS RMS as % of setpoint RMS variation
%   dynMetrics.phaseLag_us – output lag behind setpoint (µs, xcorr)
%   dynMetrics.ampRatio    – peak-to-peak output / setpoint in SS tail (%)

    dt = t(2) - t(1);
    n  = numel(errArr);

    % Steady-state: last 10% of simulation
    tail  = round(0.9*n):n;
    ssRMS = sqrt(mean(errArr(tail).^2));

    % Detect primary step: largest setpoint jump
    dsp = diff(spArr);
    [~, stepIdx] = max(abs(dsp));
    stepIdx = stepIdx + 1;
    stepAmp = spArr(end) - spArr(max(1, stepIdx-1));
    hasStep = abs(stepAmp) > 1;

    if hasStep
        yRef   = spArr(end);
        y0     = spArr(max(1, stepIdx-1));
        yRange = yRef - y0;
        seg    = yTrue(stepIdx:end);

        % Overshoot
        if yRange > 0
            pk = max(seg);
        else
            pk = min(seg);
        end
        overshoot = max(0, (pk - yRef) / abs(yRange) * 100);

        % Rise time 10 → 90%
        lo10 = y0 + 0.10 * yRange;
        hi90 = y0 + 0.90 * yRange;
        if yRange > 0
            i10 = find(seg >= lo10, 1, 'first');
            i90 = find(seg >= hi90, 1, 'first');
        else
            i10 = find(seg <= lo10, 1, 'first');
            i90 = find(seg <= hi90, 1, 'first');
        end
        if ~isempty(i10) && ~isempty(i90) && i90 > i10
            riseStr = sprintf('%.0f µs', (i90 - i10) * dt * 1e6);
        else
            riseStr = 'N/A';
        end

        % Settling time (2% band around yRef)
        band    = 0.02 * abs(yRange);
        inBand  = abs(seg - yRef) < band;
        lastOut = find(~inBand, 1, 'last');
        if isempty(lastOut)
            settleStr = '0 µs (instant)';
        else
            settleStr = sprintf('%.0f µs', lastOut * dt * 1e6);
        end

        overStr = sprintf('%.1f%%', overshoot);
    else
        overStr   = 'N/A (no step detected)';
        riseStr   = 'N/A';
        settleStr = 'N/A';
    end

    % Integral criteria over full simulation
    IAE  = trapz(t, abs(errArr));
    ITAE = trapz(t, t .* abs(errArr));

    % ── Dynamic tracking metrics (steady-state tail) ────────────────
    sp_tail   = spArr(tail);
    y_tail    = yTrue(tail);
    yM_tail   = errArr(tail) + y_tail;   % reconstruct yMeas in tail

    % 1. Normalized RMS: SS_RMS as % of setpoint RMS variation
    sp_var = rms(sp_tail - mean(sp_tail));
    if sp_var > 1
        normRMS = ssRMS / sp_var * 100;
    else
        normRMS = NaN;
    end

    % 2. Phase lag via cross-correlation (positive = output lags setpoint)
    sp_z = sp_tail - mean(sp_tail);
    y_z  = y_tail  - mean(y_tail);
    if rms(sp_z) > 1 && rms(y_z) > 1
        maxLag = min(round(numel(tail)/2), round(2/dt));
        [r, lags] = xcorr(y_z, sp_z, maxLag);
        [~, mi]   = max(r);
        phaseLag_us = lags(mi) * dt * 1e6;
    else
        phaseLag_us = NaN;
    end

    % 3. Amplitude ratio: P2P output / P2P setpoint in SS tail (%)
    pp_sp = max(sp_tail) - min(sp_tail);
    pp_y  = max(y_tail)  - min(y_tail);
    if pp_sp > 1
        ampRatio = pp_y / pp_sp * 100;
    else
        ampRatio = NaN;
    end

    % 4. Mean minimum approach: for each measured point, distance to the
    %    nearest value anywhere on the full setpoint trajectory.
    %    Captures "how close did the output ever get to each target value"
    %    independently of timing — robust to pure phase lag.
    stride   = max(1, round(numel(spArr)/500));  % downsample sp for speed
    sp_ds    = spArr(1:stride:end);
    nT       = numel(yM_tail);
    minD     = zeros(nT, 1);
    for ii = 1:nT
        minD(ii) = min(abs(yM_tail(ii) - sp_ds));
    end
    minApproach_nm = mean(minD);

    dynMetrics.normRMS        = normRMS;
    dynMetrics.phaseLag_us    = phaseLag_us;
    dynMetrics.ampRatio       = ampRatio;
    dynMetrics.minApproach_nm = minApproach_nm;

    % Format dynamic metrics lines
    if ~isnan(normRMS)
        normStr = sprintf('%.1f%%', normRMS);
    else
        normStr = 'N/A (static SP)';
    end
    if ~isnan(phaseLag_us)
        lagStr = sprintf('%.0f µs', phaseLag_us);
    else
        lagStr = 'N/A';
    end
    if ~isnan(ampRatio)
        ampStr = sprintf('%.1f%%', ampRatio);
    else
        ampStr = 'N/A (static SP)';
    end

    lines = { ...
        '── Step Response ──────────────────────────────────────────'; ...
        sprintf('  Overshoot           : %s',     overStr); ...
        sprintf('  Rise time (10→90%%) : %s',     riseStr); ...
        sprintf('  Settling time (2%%) : %s',     settleStr); ...
        sprintf('  SS RMS error        : %.2f nm', ssRMS); ...
        ''; ...
        '── Integral Criteria ──────────────────────────────────────'; ...
        sprintf('  IAE   (∫|e|dt)      : %.1f nm·s',  IAE); ...
        sprintf('  ITAE  (∫t|e|dt)     : %.1f nm·s²', ITAE); ...
        ''; ...
        '── Dynamic Tracking (SS tail) ─────────────────────────────'; ...
        sprintf('  Norm RMS            : %s  (SS err / SP swing)', normStr); ...
        sprintf('  Phase lag           : %s',     lagStr); ...
        sprintf('  Amplitude ratio     : %s  (output / SP peak-to-peak)', ampStr); ...
        sprintf('  Min approach        : %.1f nm  (mean nearest SP value)', minApproach_nm); ...
    };

    if ssRMS < 0.05 * max(abs(spArr(end)), 1)
        statusMsg = sprintf('Done  |  SS RMS: %.1f nm  — Converged ✓', ssRMS);
    else
        statusMsg = sprintf('Done  |  SS RMS: %.1f nm  — Not converged ✗  (adjust gains)', ssRMS);
    end
end
