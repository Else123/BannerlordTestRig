using System;
using System.Collections.Generic;
using System.Globalization;

namespace TestRig.Harness.Logic
{
    /// <summary>Result of <see cref="ScenarioRunner.Resolve"/>: exactly one of Scenarios / Error is set.</summary>
    public sealed class ScenarioResolution
    {
        private ScenarioResolution(IReadOnlyList<IScenario> scenarios, string error)
        {
            Scenarios = scenarios;
            Error = error;
        }

        public bool IsValid
        {
            get { return Error == null; }
        }

        /// <summary>The requested scenarios in requested order; non-null only when valid.</summary>
        public IReadOnlyList<IScenario> Scenarios { get; }

        /// <summary>Non-null only when invalid; names the offending id.</summary>
        public string Error { get; }

        internal static ScenarioResolution Valid(IReadOnlyList<IScenario> scenarios)
        {
            return new ScenarioResolution(scenarios, null);
        }

        internal static ScenarioResolution Invalid(string error)
        {
            return new ScenarioResolution(null, error);
        }
    }

    /// <summary>
    /// Engine-free runner of the scenarios of one run, driven once per game tick while the run is in
    /// phase Running. Scenarios run one after another, each starting on the tick after the previous
    /// one ended. Per scenario:
    /// <code>
    /// Passed   ran to the end with at least one check and all checks passed
    /// Failed   ran to the end and at least one check failed
    /// Error    ran to the end without any check (does not taint)
    /// Error    threw from Run, its steps or an Until condition (taints)
    /// Timeout  an Until timed out or the scenario exceeded ScenarioTimeLimitSeconds (taints)
    /// Skipped  never started because the run was tainted or aborted
    /// </code>
    /// After a tainting end the game state is unknown, so all remaining scenarios are Skipped.
    /// </summary>
    public sealed class ScenarioRunner
    {
        /// <summary>Real-time limit of one scenario, from its start.</summary>
        public const double ScenarioTimeLimitSeconds = 300;

        private readonly IReadOnlyList<IScenario> _scenarios;
        private readonly Action<string> _log;
        private readonly List<ScenarioResult> _results = new List<ScenarioResult>();
        private readonly List<CheckResult> _checks = new List<CheckResult>();

        private int _nextIndex;

        // State of the current scenario; _current is null between scenarios.
        private Context _current;
        private IEnumerator<ScenarioStep> _steps;
        private ScenarioStep _wait;
        private double _startSeconds;
        private int _ticksLeft;
        private int _resumeDay;
        private double _untilDeadline;

        /// <param name="scenarios">Scenarios in run order, typically from <see cref="Resolve"/>.</param>
        /// <param name="log">Receives one line per runner event and per <see cref="IScenarioContext.Log"/> call.</param>
        public ScenarioRunner(IReadOnlyList<IScenario> scenarios, Action<string> log)
        {
            if (scenarios == null)
            {
                throw new ArgumentNullException(nameof(scenarios));
            }

            if (log == null)
            {
                throw new ArgumentNullException(nameof(log));
            }

            foreach (IScenario scenario in scenarios)
            {
                if (scenario == null)
                {
                    throw new ArgumentException("contains a null scenario", nameof(scenarios));
                }
            }

            _scenarios = scenarios;
            _log = log;
            Results = _results.AsReadOnly();
            Checks = _checks.AsReadOnly();
        }

        /// <summary>True once every scenario has a result.</summary>
        public bool IsFinished
        {
            get { return _results.Count == _scenarios.Count; }
        }

        /// <summary>True once a scenario timed out or threw; the remaining scenarios are then Skipped.</summary>
        public bool IsTainted
        {
            get { return TaintedBy != null; }
        }

        /// <summary>True only while the current scenario waits on <see cref="ScenarioStep.Days"/>.</summary>
        public bool TimeShouldRun
        {
            get { return _current != null && _wait != null && _wait.Kind == ScenarioStep.StepKind.Days; }
        }

        /// <summary>Results of the ended scenarios, in run order; grows by one per ended scenario.</summary>
        public IReadOnlyList<ScenarioResult> Results { get; }

        /// <summary>All checks recorded so far, in call order.</summary>
        public IReadOnlyList<CheckResult> Checks { get; }

        /// <summary>
        /// True while a scenario is running. Each one ends on its own at the latest after
        /// <see cref="ScenarioTimeLimitSeconds"/> or when its Until step times out, so the stall
        /// watchdog treats it as progress; those limits are the guard.
        /// </summary>
        internal bool HasCurrentScenario
        {
            get { return _current != null; }
        }

        /// <summary>Id of the scenario that tainted the run; null while untainted.</summary>
        internal string TaintedBy { get; private set; }

        /// <summary>Counts starts, resumes and ends of scenarios; a change is progress for the stall watchdog.</summary>
        internal int Progress { get; private set; }

        /// <summary>
        /// Resolves the requested ids against the discovered scenarios, ordinally and in requested
        /// order. Invalid when an id is unknown, requested twice, or implemented by more than one
        /// discovered scenario; duplicates among unrequested scenarios are ignored.
        /// </summary>
        public static ScenarioResolution Resolve(IReadOnlyList<string> requestedIds, IEnumerable<IScenario> discovered)
        {
            if (requestedIds == null)
            {
                throw new ArgumentNullException(nameof(requestedIds));
            }

            if (discovered == null)
            {
                throw new ArgumentNullException(nameof(discovered));
            }

            var byId = new Dictionary<string, List<IScenario>>(StringComparer.Ordinal);
            foreach (IScenario scenario in discovered)
            {
                if (scenario == null || scenario.Id == null)
                {
                    continue;
                }

                List<IScenario> matches;
                if (!byId.TryGetValue(scenario.Id, out matches))
                {
                    matches = new List<IScenario>();
                    byId.Add(scenario.Id, matches);
                }

                matches.Add(scenario);
            }

            var requested = new HashSet<string>(StringComparer.Ordinal);
            var resolved = new List<IScenario>();
            foreach (string id in requestedIds)
            {
                List<IScenario> matches;
                if (id == null || !byId.TryGetValue(id, out matches))
                {
                    return ScenarioResolution.Invalid("unknown scenario id '" + id + "'");
                }

                if (!requested.Add(id))
                {
                    return ScenarioResolution.Invalid("scenario id '" + id + "' is requested more than once");
                }

                if (matches.Count > 1)
                {
                    var types = new List<string>();
                    foreach (IScenario match in matches)
                    {
                        types.Add(match.GetType().FullName);
                    }

                    return ScenarioResolution.Invalid(
                        "scenario id '" + id + "' is implemented more than once: " + string.Join(", ", types));
                }

                resolved.Add(matches[0]);
            }

            return ScenarioResolution.Valid(resolved.ToArray());
        }

        /// <summary>
        /// Drives the runner by one game tick: starts the next scenario (and runs it up to its first
        /// step) or resumes the current one once its step is over. Does nothing once finished.
        /// </summary>
        public void Tick(double realSeconds, int daysElapsed)
        {
            if (IsFinished)
            {
                return;
            }

            // Every call into scenario code (Run, its steps, Until conditions) happens in here.
            try
            {
                if (_current == null)
                {
                    StartNext(realSeconds);
                    if (_current != null)
                    {
                        Advance(realSeconds, daysElapsed);
                    }
                }
                else if (realSeconds - _startSeconds >= ScenarioTimeLimitSeconds)
                {
                    End(ScenarioStatus.Timeout, realSeconds, true,
                        "exceeded the limit of " + ScenarioTimeLimitSeconds.ToString(CultureInfo.InvariantCulture) + " s");
                }
                else if (IsWaitOver(realSeconds, daysElapsed))
                {
                    Advance(realSeconds, daysElapsed);
                }
                else if (_wait.Kind == ScenarioStep.StepKind.Until && realSeconds >= _untilDeadline)
                {
                    End(ScenarioStatus.Timeout, realSeconds, true,
                        "Until '" + _wait.Description + "' not met within "
                        + _wait.TimeoutSeconds.ToString(CultureInfo.InvariantCulture) + " s");
                }
            }
            catch (Exception e)
            {
                // The scenario already ended when the log callback threw inside End; nothing left to end.
                if (_current != null)
                {
                    End(ScenarioStatus.Error, realSeconds, true, "threw " + e.GetType().Name + ": " + e.Message);
                }
            }
        }

        /// <summary>
        /// Ends the run from outside (stall, budget): the current scenario becomes Timeout and the
        /// remaining ones Skipped. Does not taint and does nothing once finished.
        /// </summary>
        public void Abort(double realSeconds)
        {
            if (IsFinished)
            {
                return;
            }

            if (_current != null)
            {
                End(ScenarioStatus.Timeout, realSeconds, false, "aborted by the harness");
            }

            SkipRemaining();
        }

        /// <summary>
        /// Results as they would be if the process died now: the ended ones, the current scenario as
        /// Error and the remaining ones Skipped. The runner itself is not changed.
        /// </summary>
        internal IReadOnlyList<ScenarioResult> ResultsAfterCrash(double realSeconds)
        {
            var results = new List<ScenarioResult>(_results);
            if (_current != null)
            {
                results.Add(new ScenarioResult(_current.ScenarioId, ScenarioStatus.Error, SecondsSinceStart(realSeconds)));
            }

            for (int i = _nextIndex; i < _scenarios.Count; i++)
            {
                results.Add(new ScenarioResult(_scenarios[i].Id, ScenarioStatus.Skipped, null));
            }

            return results;
        }

        private void StartNext(double realSeconds)
        {
            IScenario scenario = _scenarios[_nextIndex];
            _nextIndex++;
            _current = new Context(this, scenario.Id);
            _wait = null;
            _startSeconds = realSeconds;
            Progress++;
            _log("scenario " + scenario.Id + ": started");

            IEnumerable<ScenarioStep> steps = scenario.Run(_current);
            if (steps == null)
            {
                End(ScenarioStatus.Error, realSeconds, false, "Run returned null");
                return;
            }

            _steps = steps.GetEnumerator();
        }

        // Ticks counts down here, so call it exactly once per tick.
        private bool IsWaitOver(double realSeconds, int daysElapsed)
        {
            switch (_wait.Kind)
            {
                case ScenarioStep.StepKind.Ticks:
                    _ticksLeft--;
                    return _ticksLeft <= 0;

                case ScenarioStep.StepKind.Days:
                    return daysElapsed >= _resumeDay;

                default:
                    return _wait.Condition();
            }
        }

        private void Advance(double realSeconds, int daysElapsed)
        {
            Progress++;
            if (!_steps.MoveNext())
            {
                Complete(realSeconds);
                return;
            }

            ScenarioStep step = _steps.Current;
            if (step == null)
            {
                End(ScenarioStatus.Error, realSeconds, true, "yielded a null step");
                return;
            }

            // Only the field matching step.Kind is read while waiting.
            _wait = step;
            _ticksLeft = step.Count;
            _resumeDay = daysElapsed + step.Count;
            _untilDeadline = realSeconds + step.TimeoutSeconds;
        }

        private void Complete(double realSeconds)
        {
            if (_current.CheckCount == 0)
            {
                End(ScenarioStatus.Error, realSeconds, false, "ended without any check");
            }
            else
            {
                End(_current.AnyFailed ? ScenarioStatus.Failed : ScenarioStatus.Passed, realSeconds, false, null);
            }
        }

        private void End(ScenarioStatus status, double realSeconds, bool taints, string detail)
        {
            string id = _current.ScenarioId;
            int seconds = SecondsSinceStart(realSeconds);
            _current.Close();
            DisposeSteps(id);

            _current = null;
            _wait = null;
            Progress++;
            _results.Add(new ScenarioResult(id, status, seconds));
            _log("scenario " + id + ": " + status + " after " + seconds.ToString(CultureInfo.InvariantCulture) + " s"
                + (detail == null ? string.Empty : " (" + detail + ")"));

            if (taints)
            {
                TaintedBy = id;
                SkipRemaining();
            }
        }

        // Disposing runs the finally blocks of an iterator that was stopped early.
        private void DisposeSteps(string id)
        {
            IEnumerator<ScenarioStep> steps = _steps;
            _steps = null;
            if (steps == null)
            {
                return;
            }

            try
            {
                steps.Dispose();
            }
            catch (Exception e)
            {
                _log("scenario " + id + ": dispose threw " + e.GetType().Name + ": " + e.Message);
            }
        }

        private void SkipRemaining()
        {
            for (; _nextIndex < _scenarios.Count; _nextIndex++)
            {
                string id = _scenarios[_nextIndex].Id;
                _results.Add(new ScenarioResult(id, ScenarioStatus.Skipped, null));
                _log("scenario " + id + ": Skipped");
            }
        }

        private int SecondsSinceStart(double realSeconds)
        {
            return (int)Math.Round(Math.Max(0, realSeconds - _startSeconds), MidpointRounding.AwayFromZero);
        }

        /// <summary>Context handed to one scenario; calls after the scenario ended are ignored.</summary>
        private sealed class Context : IScenarioContext
        {
            private readonly ScenarioRunner _runner;
            private bool _closed;

            public Context(ScenarioRunner runner, string scenarioId)
            {
                _runner = runner;
                ScenarioId = scenarioId;
            }

            public string ScenarioId { get; }

            public int CheckCount { get; private set; }

            public bool AnyFailed { get; private set; }

            public void Check(string name, bool passed, string expected, string actual)
            {
                if (_closed)
                {
                    _runner._log("scenario " + ScenarioId + ": check '" + name + "' after the scenario ended, ignored");
                    return;
                }

                _runner._checks.Add(new CheckResult(ScenarioId, name, expected, actual, passed));
                CheckCount++;
                if (!passed)
                {
                    AnyFailed = true;
                }

                _runner._log("scenario " + ScenarioId + ": check '" + name + "' " + (passed ? "passed" : "FAILED")
                    + " (expected " + expected + ", actual " + actual + ")");
            }

            public void Log(string message)
            {
                _runner._log("scenario " + ScenarioId + ": " + message);
            }

            public void Close()
            {
                _closed = true;
            }
        }
    }
}
