using System;
using System.Collections.Generic;
using System.Globalization;

namespace TestRig.Harness.Logic
{
    /// <summary>Which game configuration a harness run exercises.</summary>
    public enum HarnessMode { WarSails, NoDlc, FeatureOff, ChainOff }

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

        /// <summary>
        /// Ids of the health scenarios that bracket the soak (F-S6-1), trimmed and in requested order;
        /// empty when the key is absent. Only valid for a soak run, i.e. never together with <see cref="Scenarios"/>.
        /// </summary>
        public IReadOnlyList<string> Health { get; }

        private RunConfig(int seed, int days, HarnessMode mode, double stallMinutes, double budgetMinutes,
            IReadOnlyList<string> ownAssemblies, IReadOnlyList<string> scenarios, IReadOnlyList<string> health)
        {
            Seed = seed;
            Days = days;
            Mode = mode;
            StallMinutes = stallMinutes;
            BudgetMinutes = budgetMinutes;
            OwnAssemblies = ownAssemblies;
            Scenarios = scenarios;
            Health = health;
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
            string[] health = null;
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
                    error = ReadScenarioIds("scenarios", value, ref scenarios);
                }
                else if (string.Equals(key, "health", StringComparison.OrdinalIgnoreCase))
                {
                    error = ReadScenarioIds("health", value, ref health);
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

            if (health != null && scenarios != null)
            {
                return RunConfigResult.Invalid("'health' cannot be combined with 'scenarios' (health brackets a soak run)");
            }

            return RunConfigResult.Valid(new RunConfig(
                seed.Value,
                days.Value,
                mode.Value,
                stallMinutes ?? DefaultStallMinutes,
                budgetMinutes ?? DefaultBudgetMinutes,
                ownAssemblies ?? new string[0],
                scenarios ?? new string[0],
                health ?? new string[0]));
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

        // Like ReadNameList, but at least one id and no id twice (ordinal): a present key means scenario
        // (or health) mode.
        private static string ReadScenarioIds(string key, string value, ref string[] slot)
        {
            string error = ReadNameList(key, value, ref slot);
            if (error != null)
            {
                return error;
            }

            if (slot.Length == 0)
            {
                return "invalid value for '" + key + "' (expected at least one scenario id): " + value;
            }

            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string id in slot)
            {
                if (!seen.Add(id))
                {
                    return "duplicate scenario id in '" + key + "': " + id;
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

            return "invalid value for 'mode' (expected WarSails, NoDlc, FeatureOff or ChainOff): " + value;
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
    /// In health mode (run.cfg <c>health=</c>, F-S6-1) the Running phase is a soak bracketed by
    /// two health runners: health@0 (time stopped) -> soak (time runs until the requested days)
    /// -> health@N (time stopped) -> Ending. A taint in health@0 skips the rest and the soak; the
    /// soak watchdog and the daysReached check stay as in a plain soak.
    /// </summary>
    public sealed class HarnessRun
    {
        private enum RunKind { Soak, Scenarios, Health }

        // Health mode: which part of the Running phase is active.
        private enum HealthSegment { AtStart, Soak, AtEnd }

        private readonly RunConfig _config;
        private readonly double _startRealSeconds;
        private readonly RunKind _kind;

        // Scenario mode only.
        private readonly ScenarioRunner _runner;

        // Health mode only: the brackets before and after the soak.
        private readonly ScenarioRunner _healthAtStart;
        private readonly ScenarioRunner _healthAtEnd;

        private HealthSegment _segment;

        // Health mode: start of the soak segment, and its result once it ended (null before).
        private double _soakStartSeconds;
        private ScenarioStatus? _soakStatus;
        private int _soakSeconds;

        private double _lastProgressSeconds;
        private double _endingSinceSeconds;
        private int _maxDaysSeen;
        private bool _wasInMapEvent;

        // Real time of the last change to a final Status/Reason (completion, abort, end-stall).
        private double _finalRealSeconds;

        // Bounds of the rate window for runningDaysPerRealMinute (F-S6-5): real time and DaysReached at
        // its start and end. The window is the Running phase, in health mode only its soak segment.
        // Null start = never started; null end = still open.
        private double? _runningStartSeconds;
        private int _runningStartDays;
        private double? _runningEndSeconds;
        private int _runningEndDays;

        /// <summary>Soak run; <paramref name="config"/> must request neither scenarios nor health.</summary>
        public HarnessRun(RunConfig config, double startRealSeconds)
            : this(config, startRealSeconds, RunKind.Soak, null, null, null)
        {
        }

        /// <summary>Scenario run; <paramref name="config"/> must request scenarios.</summary>
        public HarnessRun(RunConfig config, double startRealSeconds, ScenarioRunner runner)
            : this(config, startRealSeconds, RunKind.Scenarios, runner, null, null)
        {
        }

        /// <summary>
        /// Soak run bracketed by health scenarios; <paramref name="config"/> must request health. The
        /// runners are typically <see cref="ScenarioRunner.ForHealth"/> of the resolved health scenarios
        /// at day 0 and at <see cref="RunConfig.Days"/>.
        /// </summary>
        public HarnessRun(RunConfig config, double startRealSeconds, ScenarioRunner healthAtStart, ScenarioRunner healthAtEnd)
            : this(config, startRealSeconds, RunKind.Health, null, healthAtStart, healthAtEnd)
        {
        }

        private HarnessRun(RunConfig config, double startRealSeconds, RunKind kind,
            ScenarioRunner runner, ScenarioRunner healthAtStart, ScenarioRunner healthAtEnd)
        {
            if (config == null)
            {
                throw new ArgumentNullException("config");
            }

            if (kind == RunKind.Scenarios && runner == null)
            {
                throw new ArgumentNullException("runner");
            }

            if (kind == RunKind.Health && healthAtStart == null)
            {
                throw new ArgumentNullException("healthAtStart");
            }

            if (kind == RunKind.Health && healthAtEnd == null)
            {
                throw new ArgumentNullException("healthAtEnd");
            }

            if ((kind == RunKind.Scenarios) != config.Scenarios.Count > 0)
            {
                throw new ArgumentException(kind == RunKind.Scenarios
                    ? "a scenario run needs a config with scenarios"
                    : "a config with scenarios needs a scenario runner", "config");
            }

            if ((kind == RunKind.Health) != config.Health.Count > 0)
            {
                throw new ArgumentException(kind == RunKind.Health
                    ? "a health run needs a config with health"
                    : "a config with health needs health runners", "config");
            }

            _config = config;
            _startRealSeconds = startRealSeconds;
            _kind = kind;
            _runner = runner;
            _healthAtStart = healthAtStart;
            _healthAtEnd = healthAtEnd;
            _segment = HealthSegment.AtStart;
            _lastProgressSeconds = startRealSeconds;
            Phase = HarnessPhase.Armed;
            Status = RunStatus.Running;
        }

        /// <summary>
        /// Ids of the scenario lines a run of <paramref name="config"/> reports, in order: "soak" for a
        /// soak run, the requested ids for a scenario run, and for a health run "&lt;id&gt;@0" per health id,
        /// "soak", then "&lt;id&gt;@&lt;days&gt;" per health id.
        /// </summary>
        public static IReadOnlyList<string> ResultIds(RunConfig config)
        {
            if (config == null)
            {
                throw new ArgumentNullException(nameof(config));
            }

            if (config.Scenarios.Count > 0)
            {
                return config.Scenarios;
            }

            var ids = new List<string>();
            foreach (string id in config.Health)
            {
                ids.Add(ScenarioRunner.HealthId(id, 0));
            }

            ids.Add(RunResult.SoakScenarioId);
            foreach (string id in config.Health)
            {
                ids.Add(ScenarioRunner.HealthId(id, config.Days));
            }

            return ids;
        }

        // The runner driven in the current tick of phase Running; null while a soak (segment) runs.
        private ScenarioRunner ActiveRunner
        {
            get
            {
                switch (_kind)
                {
                    case RunKind.Scenarios:
                        return _runner;

                    case RunKind.Health:
                        switch (_segment)
                        {
                            case HealthSegment.AtStart:
                                return _healthAtStart;

                            case HealthSegment.AtEnd:
                                return _healthAtEnd;

                            default:
                                return null;
                        }

                    default:
                        return null;
                }
            }
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
        /// Whether game time should run: in phase Running, in scenario mode only while the current
        /// scenario waits on <see cref="ScenarioStep.Days"/>, and in health mode only during the soak.
        /// </summary>
        public bool TimeShouldRun
        {
            get
            {
                ScenarioRunner active = ActiveRunner;
                return Phase == HarnessPhase.Running && (active == null || active.TimeShouldRun);
            }
        }

        /// <summary>
        /// Number of scenario lines with a result (0 in soak mode; in health mode including the soak
        /// once it ended); a change means run-result.json should be rewritten.
        /// </summary>
        public int ScenariosFinished
        {
            get
            {
                switch (_kind)
                {
                    case RunKind.Scenarios:
                        return _runner.Results.Count;

                    case RunKind.Health:
                        return _healthAtStart.Results.Count + (_soakStatus.HasValue ? 1 : 0) + _healthAtEnd.Results.Count;

                    default:
                        return 0;
                }
            }
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

            // A running (health) scenario is bounded by its own limits (see ScenarioRunner), so it counts
            // as progress; the budget below still applies.
            ScenarioRunner active = ActiveRunner;
            if (Phase == HarnessPhase.Running && active != null && active.HasCurrentScenario)
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
        /// checks; in health mode the health@0 lines, the soak line with its daysReached check once the
        /// soak ended (Skipped without a check when a final run never started it), then the health@N
        /// lines. realSeconds is rounded to whole seconds and the rate to two decimals.
        /// </summary>
        public RunResult ToResult(double realSeconds, IReadOnlyList<ModuleEntry> modules, ExceptionSummary exceptions)
        {
            return ToResult(Status, Reason, realSeconds, modules, exceptions, false);
        }

        /// <summary>
        /// Result record for an unhandled exception that terminates the process. A run without a
        /// final status yet (Running) becomes Aborted with reason "unhandled:&lt;phase&gt;" as of
        /// <paramref name="realSeconds"/>: the soak scenario Failed, or in scenario mode the current
        /// scenario Error and the remaining ones Skipped; in health mode a running soak segment is
        /// Failed, the current health scenario Error and everything not started Skipped. A run that already has a final status keeps
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
            switch (_kind)
            {
                case RunKind.Scenarios:
                    // Copies: the runner's lists keep growing after this record is taken.
                    scenarios = crashed ? _runner.ResultsAfterCrash(realSeconds) : new List<ScenarioResult>(_runner.Results);
                    checks = new List<CheckResult>(_runner.Checks);
                    break;

                case RunKind.Health:
                    HealthLines(status, realSeconds, crashed, out scenarios, out checks);
                    break;

                default:
                    bool daysPassed = DaysReached >= _config.Days;
                    checks = new[] { DaysReachedCheck() };
                    scenarios = new[] { new ScenarioResult(RunResult.SoakScenarioId, ClassifySoak(status, reason, daysPassed), seconds) };
                    break;
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
                RunningRate(realSeconds),
                PlayerMapEvents,
                modules,
                exceptions,
                scenarios,
                checks);
        }

        private CheckResult DaysReachedCheck()
        {
            return new CheckResult(
                RunResult.SoakScenarioId,
                "daysReached",
                ">= " + _config.Days.ToString(CultureInfo.InvariantCulture),
                DaysReached.ToString(CultureInfo.InvariantCulture),
                DaysReached >= _config.Days);
        }

        // Health mode: health@0 lines, soak line (+ its check), health@N lines, each part as far as it has
        // a result. A soak that never started is listed (Skipped, no check) only in a final record.
        private void HealthLines(RunStatus status, double realSeconds, bool crashed,
            out IReadOnlyList<ScenarioResult> scenarios, out IReadOnlyList<CheckResult> checks)
        {
            var lines = new List<ScenarioResult>(crashed ? _healthAtStart.ResultsAfterCrash(realSeconds) : _healthAtStart.Results);
            var checkList = new List<CheckResult>(_healthAtStart.Checks);

            bool soakRunning = Phase == HarnessPhase.Running && _segment == HealthSegment.Soak;
            if (_soakStatus.HasValue)
            {
                lines.Add(new ScenarioResult(RunResult.SoakScenarioId, _soakStatus.Value, _soakSeconds));
                checkList.Add(DaysReachedCheck());
            }
            else if (crashed && soakRunning)
            {
                lines.Add(new ScenarioResult(RunResult.SoakScenarioId, ScenarioStatus.Failed, SoakSecondsAt(realSeconds)));
                checkList.Add(DaysReachedCheck());
            }
            else if (status != RunStatus.Running)
            {
                lines.Add(new ScenarioResult(RunResult.SoakScenarioId, ScenarioStatus.Skipped, null));
            }

            lines.AddRange(crashed ? _healthAtEnd.ResultsAfterCrash(realSeconds) : _healthAtEnd.Results);
            checkList.AddRange(_healthAtEnd.Checks);

            scenarios = lines;
            checks = checkList;
        }

        private int SoakSecondsAt(double realSeconds)
        {
            return (int)Math.Round(Math.Max(0, realSeconds - _soakStartSeconds), MidpointRounding.AwayFromZero);
        }

        // Game days per real minute of the rate window (the Running phase, in health mode its soak
        // segment), which ends at the latest with the run's final transition; while it lasts it ends at
        // realSeconds. Null when the window never began or has no duration.
        private double? RunningRate(double realSeconds)
        {
            if (!_runningStartSeconds.HasValue)
            {
                return null;
            }

            double end = _runningEndSeconds ?? realSeconds;
            int days = (_runningEndSeconds.HasValue ? _runningEndDays : DaysReached) - _runningStartDays;
            double minutes = (end - _runningStartSeconds.Value) / 60.0;
            if (!(minutes > 0))
            {
                return null;
            }

            return Math.Round(days / minutes, 2, MidpointRounding.AwayFromZero);
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

            if (_kind == RunKind.Health)
            {
                if (Phase == HarnessPhase.Running && _segment == HealthSegment.Soak)
                {
                    EndSoak(ClassifySoak(Status, Reason, DaysReached >= _config.Days), realSeconds);
                }

                _healthAtStart.Abort(realSeconds);
                _healthAtEnd.Abort(realSeconds);
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
            switch (_kind)
            {
                case RunKind.Scenarios:
                    return TickScenarios(_runner, o) ?? (_runner.IsFinished ? Complete(o.RealSeconds) : HarnessAction.KeepRunning);

                case RunKind.Health:
                    return TickHealth(o);

                default:
                    return o.DaysElapsed >= _config.Days ? Complete(o.RealSeconds) : HarnessAction.KeepRunning;
            }
        }

        // Health mode: each segment change happens on the tick that ends the previous segment; health@N
        // starts on the tick after the soak ended, once game time is stopped again.
        private HarnessAction TickHealth(HarnessObservation o)
        {
            switch (_segment)
            {
                case HealthSegment.AtStart:
                    HarnessAction? tainted = TickScenarios(_healthAtStart, o);
                    if (tainted.HasValue)
                    {
                        // No soak after a taint: the game state is unknown.
                        _healthAtEnd.Abort(o.RealSeconds);
                        return tainted.Value;
                    }

                    if (_healthAtStart.IsFinished)
                    {
                        StartSoak(o.RealSeconds);
                    }

                    return HarnessAction.KeepRunning;

                case HealthSegment.Soak:
                    if (o.DaysElapsed >= _config.Days)
                    {
                        EndSoak(ScenarioStatus.Passed, o.RealSeconds);
                    }

                    return HarnessAction.KeepRunning;

                default:
                    return TickScenarios(_healthAtEnd, o)
                        ?? (_healthAtEnd.IsFinished ? Complete(o.RealSeconds) : HarnessAction.KeepRunning);
            }
        }

        private void StartSoak(double realSeconds)
        {
            _segment = HealthSegment.Soak;
            _soakStartSeconds = realSeconds;
            _lastProgressSeconds = realSeconds;
            StartRateWindow(realSeconds);
        }

        // Ends the soak segment with its result; a passed soak hands over to health@N.
        private void EndSoak(ScenarioStatus status, double realSeconds)
        {
            _soakStatus = status;
            _soakSeconds = SoakSecondsAt(realSeconds);
            _segment = HealthSegment.AtEnd;
            _lastProgressSeconds = realSeconds;
            EndRateWindow(realSeconds);
        }

        // Drives one runner by a tick (the days key is not evaluated here); every runner step is progress
        // for the stall watchdog. Returns RequestEndGame when the runner got tainted, else null.
        private HarnessAction? TickScenarios(ScenarioRunner runner, HarnessObservation o)
        {
            int progressBefore = runner.Progress;
            runner.Tick(o.RealSeconds, o.DaysElapsed);
            if (runner.Progress != progressBefore)
            {
                _lastProgressSeconds = o.RealSeconds;
            }

            if (runner.IsTainted)
            {
                Status = RunStatus.Aborted;
                Reason = "tainted:" + runner.TaintedBy;
                _finalRealSeconds = o.RealSeconds;
                EnterPhase(HarnessPhase.Ending, o.RealSeconds);
                return HarnessAction.RequestEndGame;
            }

            return null;
        }

        private HarnessAction Complete(double realSeconds)
        {
            Status = RunStatus.Completed;
            _finalRealSeconds = realSeconds;
            EnterPhase(HarnessPhase.Ending, realSeconds);
            return HarnessAction.RequestEndGame;
        }

        // Every phase change is progress; entering Ending also starts the end-stall clock. Entering and
        // leaving Running bound the rate window, in health mode the soak segment does (see StartSoak/EndSoak).
        private void EnterPhase(HarnessPhase phase, double realSeconds)
        {
            if (phase == HarnessPhase.Running && _kind != RunKind.Health)
            {
                StartRateWindow(realSeconds);
            }
            else if (Phase == HarnessPhase.Running)
            {
                EndRateWindow(realSeconds);
            }

            Phase = phase;
            _lastProgressSeconds = realSeconds;
            _endingSinceSeconds = realSeconds;
        }

        // DaysReached already holds this tick.
        private void StartRateWindow(double realSeconds)
        {
            _runningStartSeconds = realSeconds;
            _runningStartDays = DaysReached;
        }

        // Only an open window is closed, so a later phase change keeps the first end.
        private void EndRateWindow(double realSeconds)
        {
            if (!_runningStartSeconds.HasValue || _runningEndSeconds.HasValue)
            {
                return;
            }

            _runningEndSeconds = realSeconds;
            _runningEndDays = DaysReached;
        }
    }
}
