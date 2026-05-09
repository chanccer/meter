function [lines, statusMsg] = computeMetrics(t, errArr, spArr, yTrue)
%COMPUTEMETRICS  Standard step-response performance metrics.
%   Returns a cell array of display strings and a short status message.

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
            riseStr = sprintf('%.0f ms', (i90 - i10) * dt * 1000);
        else
            riseStr = 'N/A';
        end

        % Settling time (2% band around yRef)
        band    = 0.02 * abs(yRange);
        inBand  = abs(seg - yRef) < band;
        lastOut = find(~inBand, 1, 'last');
        if isempty(lastOut)
            settleStr = '0 ms (instant)';
        else
            settleStr = sprintf('%.0f ms', lastOut * dt * 1000);
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
    };

    if ssRMS < 0.05 * max(abs(spArr(end)), 1)
        statusMsg = sprintf('Done  |  SS RMS: %.1f nm  — Converged ✓', ssRMS);
    else
        statusMsg = sprintf('Done  |  SS RMS: %.1f nm  — Not converged ✗  (adjust gains)', ssRMS);
    end
end
