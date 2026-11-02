using System;
using System.Collections.Generic;
using System.Globalization;

namespace TestRig.Harness.Logic
{
    /// <summary>Which game configuration a harness run exercises.</summary>
    public enum HarnessMode { WarSails, NoDlc, FeatureOff }

    /// <summary>Outcome class of parsing the run config file.</summary>
    public enum RunConfigStatus { Inert, Valid, Invalid }

    /// <summary>Result of <see cref="RunConfig.Parse"/>: exactly one of Config / Error is set when not inert.</summary>
    public sealed class RunConfigResult
    {
        public RunConfigStatus Status { get; }

        /// <summary>Non-null only when <see cref="Status"/> is Valid.</summary>
        public RunConfig Config { get; }

        /// <summary>Non-null only when <see cref="Status"/> is Invalid.</summary>
        public string Error { get; }

        private RunConfigResult(RunConfigStatus status, RunConfig config, string error)
        {
            Status = status;
            Config = config;
            Error = error;
        }

        internal static RunConfigResult Inert()
        {
            return new RunConfigResult(RunConfigStatus.Inert, null, null);
        }

        internal static RunConfigResult Valid(RunConfig config)
        {
            return new RunConfigResult(RunConfigStatus.Valid, config, null);
        }

        internal static RunConfigResult Invalid(string error)
        {
            return new RunConfigResult(RunConfigStatus.Invalid, null, error);
        }
    }

    /// <summary>
    /// Engine-free configuration of one unattended harness run, read from a simple
    /// key=value text file. An absent file means the harness stays inert (normal play);
    /// a present but broken file is an error, never silently ignored.
    /// </summary>
    public sealed class RunConfig
    {
        public const double DefaultStallMinutes = 5;
        public const double DefaultBudgetMinutes = 60;

        public const int MaxDays = 365;

        public int Seed { get; }
        public int Days { get; }
        public HarnessMode Mode { get; }
        public double StallMinutes { get; }
        public double BudgetMinutes { get; }

        /// <summary>
        /// Simple names (without ".dll") of the assemblies under test, trimmed and without empty
        /// entries; empty when the key is absent. Classifies exceptions as own in run-result.json.
        /// </summary>
        public IReadOnlyList<string> OwnAssemblies { get; }

        /// <summary>
        /// Ids of the scenarios to run, trimmed and in requested order; empty when the key is absent,
        /// which makes the run a soak. With scenarios, <see cref="Days"/> is still required but not evaluated.
        /// </summary>
        public IReadOnlyList<string> Scenarios { get; }

        private RunConfig(int seed, int days, HarnessMode mode, double stallMinutes, double budgetMinutes,
            IReadOnlyList<string> ownAssemblies, IReadOnlyList<string> scenarios)
        {
            Seed = seed;
            Days = days;
            Mode = mode;
            StallMinutes = stallMinutes;
            BudgetMinutes = budgetMinutes;
            OwnAssemblies = ownAssemblies;
            Scenarios = scenarios;
        }

        /// <summary>
        /// Parses the config text. <c>null</c> (file absent) is inert. Never throws:
        /// every problem is reported as an Invalid result naming the offending key or line.
        /// </summary>
        public static RunConfigResult Parse(string text)
        {
            if (text == null)
            {
                return RunConfigResult.Inert();
            }

            int? seed = null;
            int? days = null;
            HarnessMode? mode = null;
            double? stallMinutes = null;
            double? budgetMinutes = null;
            string[] ownAssemblies = null;
            string[] scenarios = null;
            bool anyLine = false;

            foreach (string rawLine in text.Split('\n'))
            {
                string line = rawLine.Trim();
                if (line.Length == 0 || line[0] == '#')
                {
                    continue;
                }

                anyLine = true;
                int eq = line.IndexOf('=');
                if (eq < 0)
                {
                    return RunConfigResult.Invalid("line has no '=': " + line);
                }

                string key = line.Substring(0, eq).Trim();
                string value = line.Substring(eq + 1).Trim();
                string error = null;

                if (string.Equals(key, "seed", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadInt("seed", value, 0, int.MaxValue, ref seed);
                }
                else if (string.Equals(key, "days", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadInt("days", value, 1, MaxDays, ref days);
                }
                else if (string.Equals(key, "mode", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadMode(value, ref mode);
                }
                else if (string.Equals(key, "stallMinutes", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadMinutes("stallMinutes", value, ref stallMinutes);
                }
                else if (string.Equals(key, "budgetMinutes", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadMinutes("budgetMinutes", value, ref budgetMinutes);
                }
                else if (string.Equals(key, "ownAssemblies", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadNameList("ownAssemblies", value, ref ownAssemblies);
                }
                else if (string.Equals(key, "scenarios", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadScenarioIds(value, ref scenarios);
                }
                else
                {
                    error = "unknown key '" + key + "'";
                }

                if (error != null)
                {
                    return RunConfigResult.Invalid(error);
                }
            }

            if (!anyLine)
            {
                return RunConfigResult.Invalid("config is empty");
            }

            if (!seed.HasValue)
            {
                return RunConfigResult.Invalid("missing required key 'seed'");
            }

            if (!days.HasValue)
            {
                return RunConfigResult.Invalid("missing required key 'days'");
            }

            if (!mode.HasValue)
            {
                return RunConfigResult.Invalid("missing required key 'mode'");
            }

            return RunConfigResult.Valid(new RunConfig(
                seed.Value,
                days.Value,
                mode.Value,
                stallMinutes ?? DefaultStallMinutes,
                budgetMinutes ?? DefaultBudgetMinutes,
                ownAssemblies ?? new string[0],
                scenarios ?? new string[0]));
        }

        // Each Read* helper stores into the slot and returns null, or returns an error text.
        // A slot that is already filled means the key appeared twice.

        private static string ReadInt(string key, string value, int min, int max, ref int? slot)
        {
            if (slot.HasValue)
            {
                return "duplicate key '" + key + "'";
            }

            int parsed;
            if (HasControlCharacter(value)
                || !int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)
                || parsed < min
                || parsed > max)
            {
                return "invalid value for '" + key + "' (expected integer " + min + ".." + max + "): " + value;
            }

            slot = parsed;
            return null;
        }

        private static string ReadMinutes(string key, string value, ref double? slot)
        {
            if (slot.HasValue)
            {
                return "duplicate key '" + key + "'";
            }

            double parsed;
            if (HasControlCharacter(value)
                || !double.TryParse(value, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed)
                || double.IsNaN(parsed)
                || double.IsInfinity(parsed)
                || parsed <= 0)
            {
                return "invalid value for '" + key + "' (expected number > 0): " + value;
            }

            slot = parsed;
            return null;
        }

        // Comma-separated names; an empty value or empty entries are allowed and dropped.
        private static string ReadNameList(string key, string value, ref string[] slot)
        {
            if (slot != null)
            {
                return "duplicate key '" + key + "'";
            }

            if (HasControlCharacter(value))
            {
                return "invalid value for '" + key + "' (expected comma-separated names): " + value;
            }

            var names = new List<string>();
            foreach (string entry in value.Split(','))
            {
                string name = entry.Trim();
                if (name.Length > 0)
                {
                    names.Add(name);
                }
            }

            slot = names.ToArray();
            return null;
        }

        // Like ReadNameList, but at least one id and no id twice (ordinal): a present key means scenario mode.
        private static string ReadScenarioIds(string value, ref string[] slot)
        {
            string error = ReadNameList("scenarios", value, ref slot);
            if (error != null)
            {
                return error;
            }

            if (slot.Length == 0)
            {
                return "invalid value for 'scenarios' (expected at least one scenario id): " + value;
            }

            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string id in slot)
            {
                if (!seen.Add(id))
                {
                    return "duplicate scenario id in 'scenarios': " + id;
                }
            }

            return null;
        }

        // Enum names only: Enum.TryParse would also accept numbers ("1") and comma lists.
        private static string ReadMode(string value, ref HarnessMode? slot)
        {
            if (slot.HasValue)
            {
                return "duplicate key 'mode'";
            }

            foreach (string name in Enum.GetNames(typeof(HarnessMode)))
            {
                if (string.Equals(name, value, StringComparison.OrdinalIgnoreCase))
                {
                    slot = (HarnessMode)Enum.Parse(typeof(HarnessMode), name);
                    return null;
                }
            }

            return "invalid value for 'mode' (expected WarSails, NoDlc or FeatureOff): " + value;
        }

        // .NET number parsing tolerates trailing NUL characters; a config value must not.
        private static bool HasControlCharacter(string value)
        {
            foreach (char c in value)
            {
                if (char.IsControl(c))
                {
                    return true;
                }
            }

            return false;
        }
    }

    public enum HarnessPhase { Armed, StartRequested, CharacterCreation, Map, Running, Ending, Quit }

    public enum RunStatus { Running, Completed, Aborted }

    /// <summary>What the engine-side driver should do after a tick.</summary>
    public enum HarnessAction { None, StartNewGame, AdvanceCreation, SetupMap, KeepRunning, RequestEndGame, QuitProcess }

    /// <summary>Snapshot of the game state the driver samples once per tick.</summary>
    public struct HarnessObservation
    {
        public double RealSeconds;            // monotonic real time
        public bool MainMenuActive;
        public bool CharacterCreationActive;
        public bool MapActive;                // campaign map state is the active state
        public bool InGame;                   // a Game/Campaign currently exists
        public bool GameEnded;                // OnGameEnd has fired
        public int DaysElapsed;               // in-game days since the map was reached
        public bool PlayerInMapEvent;         // main party is part of a MapEvent right now
    }

    /// <summary>
    /// Engine-free state machine of one unattended run: menu -> new game -> character
    /// creation -> map -> N in-game days -> end game -> quit. A watchdog aborts the run
    /// on a total time budget or when no progress (phase change, new day) is made for
    /// too long, so a hung game never blocks a soak loop.
    /// In scenario mode the Running phase drives a <see cref="ScenarioRunner"/> instead of
    /// counting days: the run completes after the last scenario and is aborted with reason
    /// "tainted:&lt;id&gt;" when a scenario taints it.
    /// </summary>
    public sealed class HarnessRun
    {
        private readonly RunConfig _config;
        private readonly double _startRealSeconds;

        // Null in soak mode.
        private readonly ScenarioRunner _runner;

        private double _lastProgressSeconds;
        private double _endingSinceSeconds;
        private int _maxDaysSeen;
        private bool _wasInMapEvent;
        private int _runnerProgressSeen;

        // Real time of the last change to a final Status/Reason (completion, abort, end-stall).
        private double _finalRealSeconds;

        /// <summary>Soak run; <paramref name="config"/> must not request scenarios.</summary>
        public HarnessRun(RunConfig config, double startRealSeconds)
            : this(config, startRealSeconds, null, false)
        {
        }

        /// <summary>Scenario run; <paramref name="config"/> must request scenarios.</summary>
        public HarnessRun(RunConfig config, double startRealSeconds, ScenarioRunner runner)
            : this(config, startRealSeconds, runner, true)
        {
        }

        private HarnessRun(RunConfig config, double startRealSeconds, ScenarioRunner runner, bool scenarioMode)
        {
            if (config == null)
            {
                throw new ArgumentNullException("config");
            }

            if (scenarioMode && runner == null)
            {
                throw new ArgumentNullException("runner");
            }

            if (scenarioMode != config.Scenarios.Count > 0)
            {
                throw new ArgumentException(scenarioMode
                    ? "a scenario run needs a config with scenarios"
                    : "a config with scenarios needs a scenario runner", "config");
            }

            _config = config;
            _startRealSeconds = startRealSeconds;
            _runner = runner;
            _lastProgressSeconds = startRealSeconds;
            Phase = HarnessPhase.Armed;
            Status = RunStatus.Running;
        }

        public HarnessPhase Phase { get; private set; }

        public RunStatus Status { get; private set; }

        /// <summary>Null while Running / Completed; otherwise "timeout:&lt;phase&gt;", "stall:&lt;phase&gt;", "tainted:&lt;scenario id&gt;" or "end-stall".</summary>
        public string Reason { get; private set; }

        /// <summary>Highest in-game day count observed in any phase before Quit.</summary>
        public int DaysReached { get; private set; }

        /// <summary>Number of map events the player entered (false -> true edges of PlayerInMapEvent).</summary>
        public int PlayerMapEvents { get; private set; }

        /// <summary>
        /// Whether game time should run: in phase Running, and in scenario mode only while the
        /// current scenario waits on <see cref="ScenarioStep.Days"/>.
        /// </summary>
        public bool TimeShouldRun
        {
            get { return Phase == HarnessPhase.Running && (_runner == null || _runner.TimeShouldRun); }
        }

        /// <summary>Number of scenarios with a result (0 in soak mode); a change means run-result.json should be rewritten.</summary>
        public int ScenariosFinished
        {
            get { return _runner == null ? 0 : _runner.Results.Count; }
        }

        public HarnessAction Tick(HarnessObservation o)
        {
            if (Phase == HarnessPhase.Quit)
            {
                return HarnessAction.None;
            }

            // Recorded before any rule, so an abort on this very tick still reports it.
            RecordObservation(o);

            if (Phase == HarnessPhase.Ending)
            {
                return TickEnding(o);
            }

            // In scenario mode a running scenario is bounded by its own limits (see ScenarioRunner), so
            // it counts as progress; the budget below still applies.
            if (Phase == HarnessPhase.Running && _runner != null && _runner.HasCurrentScenario)
            {
                _lastProgressSeconds = o.RealSeconds;
            }

            HarnessAction abort = CheckWatchdog(o);
            if (abort != HarnessAction.None)
            {
                return abort;
            }

            HarnessAction action = Transition(o);

            if (o.DaysElapsed > _maxDaysSeen)
            {
                _maxDaysSeen = o.DaysElapsed;
                _lastProgressSeconds = o.RealSeconds;
            }

            return action;
        }

        /// <summary>
        /// Result record of this run at <paramref name="realSeconds"/>: in soak mode one soak scenario
        /// and one daysReached check; in scenario mode the scenarios with a result so far and their
        /// checks. realSeconds is rounded to whole seconds and the rate to two decimals.
        /// </summary>
        public RunResult ToResult(double realSeconds, IReadOnlyList<ModuleEntry> modules, ExceptionSummary exceptions)
        {
            return ToResult(Status, Reason, realSeconds, modules, exceptions, false);
        }

        /// <summary>
        /// Result record for an unhandled exception that terminates the process. A run without a
        /// final status yet (Running) becomes Aborted with reason "unhandled:&lt;phase&gt;" as of
        /// <paramref name="realSeconds"/>: the soak scenario Failed, or in scenario mode the current
        /// scenario Error and the remaining ones Skipped. A run that already has a final status keeps
        /// it and its timing as of the final transition (realSeconds, rate, scenario seconds), so the
        /// crash only updates the exception counts. The run itself is not changed.
        /// </summary>
        public RunResult ToUnhandledResult(double realSeconds, IReadOnlyList<ModuleEntry> modules, ExceptionSummary exceptions)
        {
            return Status == RunStatus.Running
                ? ToResult(RunStatus.Aborted, "unhandled:" + Phase, realSeconds, modules, exceptions, true)
                : ToResult(Status, Reason, _finalRealSeconds, modules, exceptions, false);
        }

        private RunResult ToResult(RunStatus status, string reason, double realSeconds,
            IReadOnlyList<ModuleEntry> modules, ExceptionSummary exceptions, bool crashed)
        {
            double elapsed = Math.Max(0, realSeconds - _startRealSeconds);
            double rate = elapsed > 0 ? DaysReached / (elapsed / 60.0) : 0;
            int seconds = (int)Math.Round(elapsed, MidpointRounding.AwayFromZero);

            IReadOnlyList<ScenarioResult> scenarios;
            IReadOnlyList<CheckResult> checks;
            if (_runner == null)
            {
                bool daysPassed = DaysReached >= _config.Days;
                checks = new[]
                {
                    new CheckResult(
                        RunResult.SoakScenarioId,
                        "daysReached",
                        ">= " + _config.Days.ToString(CultureInfo.InvariantCulture),
                        DaysReached.ToString(CultureInfo.InvariantCulture),
                        daysPassed),
                };
                scenarios = new[] { new ScenarioResult(RunResult.SoakScenarioId, ClassifySoak(status, reason, daysPassed), seconds) };
            }
            else
            {
                // Copies: the runner's lists keep growing after this record is taken.
                scenarios = crashed ? _runner.ResultsAfterCrash(realSeconds) : new List<ScenarioResult>(_runner.Results);
                checks = new List<CheckResult>(_runner.Checks);
            }

            return new RunResult(
                status,
                reason ?? string.Empty,
                _config.Seed,
                _config.Mode.ToString(),
                _config.Days,
                DaysReached,
                seconds,
                Math.Round(rate, 2, MidpointRounding.AwayFromZero),
                PlayerMapEvents,
                modules,
                exceptions,
                scenarios,
                checks);
        }

        /// <summary>
        /// Maps the run outcome to the soak scenario status. Reasons come from this class
        /// (<see cref="Abort"/>, <see cref="TickEnding"/>, <see cref="ToUnhandledResult"/>) and from the
        /// config-error record:
        /// <code>
        /// status     reason                              scenario
        /// Completed  (none)                              Passed if the check passed, else Failed
        /// Aborted    "timeout:&lt;phase&gt;"  (budget)          Timeout
        /// Aborted    "stall:&lt;phase&gt;"    (no progress)     Timeout
        /// Aborted    "end-stall"            (no clean exit)  Timeout
        /// Aborted    "timeout:&lt;phase&gt;;end-stall"         Timeout
        /// Aborted    "stall:&lt;phase&gt;;end-stall"           Timeout
        /// Aborted    "config:&lt;error&gt;"                   Error
        /// Aborted    "unhandled:&lt;phase&gt;" (crash)          Failed (the mod under test crashed)
        /// Aborted    anything else / none                Error
        /// Running    any (not a final state)             Error
        /// </code>
        /// </summary>
        public static ScenarioStatus ClassifySoak(RunStatus status, string reason, bool checkPassed)
        {
            switch (status)
            {
                case RunStatus.Completed:
                    return checkPassed ? ScenarioStatus.Passed : ScenarioStatus.Failed;

                case RunStatus.Aborted:
                    if (IsTimeLimitReason(reason))
                    {
                        return ScenarioStatus.Timeout;
                    }

                    return IsUnhandledReason(reason) ? ScenarioStatus.Failed : ScenarioStatus.Error;

                default:
                    return ScenarioStatus.Error;
            }
        }

        // The first segment decides; ";end-stall" is only ever appended to a time-limit reason.
        private static bool IsTimeLimitReason(string reason)
        {
            if (string.IsNullOrEmpty(reason))
            {
                return false;
            }

            return reason.StartsWith("timeout:", StringComparison.Ordinal)
                || reason.StartsWith("stall:", StringComparison.Ordinal)
                || string.Equals(reason, "end-stall", StringComparison.Ordinal);
        }

        private static bool IsUnhandledReason(string reason)
        {
            return reason != null && reason.StartsWith("unhandled:", StringComparison.Ordinal);
        }

        private void RecordObservation(HarnessObservation o)
        {
            if (o.DaysElapsed > DaysReached)
            {
                DaysReached = o.DaysElapsed;
            }

            if (o.PlayerInMapEvent && !_wasInMapEvent)
            {
                PlayerMapEvents++;
            }

            _wasInMapEvent = o.PlayerInMapEvent;
        }

        private HarnessAction TickEnding(HarnessObservation o)
        {
            if (o.GameEnded || !o.InGame)
            {
                Phase = HarnessPhase.Quit;
                return HarnessAction.QuitProcess;
            }

            // The game did not shut down in time: give up on a clean exit and quit anyway.
            if (o.RealSeconds - _endingSinceSeconds >= _config.StallMinutes * 60)
            {
                Reason = Status == RunStatus.Aborted ? Reason + ";end-stall" : "end-stall";
                Status = RunStatus.Aborted;
                _finalRealSeconds = o.RealSeconds;
                Phase = HarnessPhase.Quit;
                return HarnessAction.QuitProcess;
            }

            return HarnessAction.None;
        }

        // Budget beats stall when both have elapsed.
        private HarnessAction CheckWatchdog(HarnessObservation o)
        {
            if (o.RealSeconds - _startRealSeconds >= _config.BudgetMinutes * 60)
            {
                return Abort("timeout", o.RealSeconds);
            }

            if (o.RealSeconds - _lastProgressSeconds >= _config.StallMinutes * 60)
            {
                return Abort("stall", o.RealSeconds);
            }

            return HarnessAction.None;
        }

        private HarnessAction Abort(string kind, double realSeconds)
        {
            Status = RunStatus.Aborted;
            Reason = kind + ":" + Phase;
            _finalRealSeconds = realSeconds;
            if (_runner != null)
            {
                _runner.Abort(realSeconds);
            }

            EnterPhase(HarnessPhase.Ending, realSeconds);
            return HarnessAction.RequestEndGame;
        }

        private HarnessAction Transition(HarnessObservation o)
        {
            switch (Phase)
            {
                case HarnessPhase.Armed:
                    if (o.MainMenuActive)
                    {
                        EnterPhase(HarnessPhase.StartRequested, o.RealSeconds);
                        return HarnessAction.StartNewGame;
                    }

                    return HarnessAction.None;

                case HarnessPhase.StartRequested:
                case HarnessPhase.CharacterCreation:
                    return TransitionToMap(o);

                case HarnessPhase.Map:
                    EnterPhase(HarnessPhase.Running, o.RealSeconds);
                    return HarnessAction.KeepRunning;

                case HarnessPhase.Running:
                    return TickRunning(o);

                default:
                    return HarnessAction.None;
            }
        }

        // Shared by StartRequested and CharacterCreation; a map that is already active wins.
        private HarnessAction TransitionToMap(HarnessObservation o)
        {
            if (o.MapActive)
            {
                EnterPhase(HarnessPhase.Map, o.RealSeconds);
                return HarnessAction.SetupMap;
            }

            if (o.CharacterCreationActive)
            {
                if (Phase == HarnessPhase.StartRequested)
                {
                    EnterPhase(HarnessPhase.CharacterCreation, o.RealSeconds);
                }

                return HarnessAction.AdvanceCreation;
            }

            return HarnessAction.None;
        }

        private HarnessAction TickRunning(HarnessObservation o)
        {
            if (_runner != null)
            {
                return TickScenarios(o);
            }

            if (o.DaysElapsed >= _config.Days)
            {
                return Complete(o.RealSeconds);
            }

            return HarnessAction.KeepRunning;
        }

        // Scenario mode: the days key is ignored; every runner step is progress for the stall watchdog.
        private HarnessAction TickScenarios(HarnessObservation o)
        {
            _runner.Tick(o.RealSeconds, o.DaysElapsed);
            if (_runner.Progress != _runnerProgressSeen)
            {
                _runnerProgressSeen = _runner.Progress;
                _lastProgressSeconds = o.RealSeconds;
            }

            if (_runner.IsTainted)
            {
                Status = RunStatus.Aborted;
                Reason = "tainted:" + _runner.TaintedBy;
                _finalRealSeconds = o.RealSeconds;
                EnterPhase(HarnessPhase.Ending, o.RealSeconds);
                return HarnessAction.RequestEndGame;
            }

            return _runner.IsFinished ? Complete(o.RealSeconds) : HarnessAction.KeepRunning;
        }

        private HarnessAction Complete(double realSeconds)
        {
            Status = RunStatus.Completed;
            _finalRealSeconds = realSeconds;
            EnterPhase(HarnessPhase.Ending, realSeconds);
            return HarnessAction.RequestEndGame;
        }

        // Every phase change is progress; entering Ending also starts the end-stall clock.
        private void EnterPhase(HarnessPhase phase, double realSeconds)
        {
            Phase = phase;
            _lastProgressSeconds = realSeconds;
            _endingSinceSeconds = realSeconds;
        }
    }
}
