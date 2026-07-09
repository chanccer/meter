function results = simulate_headless(varargin)
%SIMULATE_HEADLESS  Headless entry point for the Piezo PID/ADRC simulation.
%
%   Same simulation as simulate()'s GUI, but with no uifigure/figure and no
%   user interaction — runs cleanly under `matlab -batch`, in CI, or on
%   machines with no display server.
%
%   results = simulate_headless()
%   results = simulate_headless('K', 500, 't_total', 1.0)
%   results = simulate_headless('ConfigFile', 'simulate_config.json')
%
%   Command-line example (from the project directory, no MATLAB desktop):
%       matlab -batch "simulate_headless('SaveCSV','out.csv','Verbose',false)"
%
%   See `help sim.runHeadless` for the full list of options (ConfigFile,
%   SaveCSV, SaveMAT, Plot, PlotFile, Verbose) and parameter overrides.

    results = sim.runHeadless(varargin{:});
end
