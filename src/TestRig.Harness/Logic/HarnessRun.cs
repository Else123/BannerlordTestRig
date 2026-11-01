using System;
using System.Globalization;
using System.Text;

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

        private RunConfig(int seed, int days, HarnessMode mode, double stallMinutes, double budgetMinutes)
        {
            Seed = seed;
            Days = days;
            Mode = mode;
            StallMinutes = stallMinutes;
            BudgetMinutes = budgetMinutes;
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
                budgetMinutes ?? DefaultBudgetMinutes));
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
    /// </summary>
    public sealed class HarnessRun
    {
        private readonly RunConfig _config;
        private readonly double _startRealSeconds;

        private double _lastProgressSeconds;
        private double _endingSinceSeconds;
        private int _maxDaysSeen;
        private bool _wasInMapEvent;

        public HarnessRun(RunConfig config, double startRealSeconds)
        {
            if (config == null)
            {
                throw new ArgumentNullException("config");
            }

            _config = config;
            _startRealSeconds = startRealSeconds;
            _lastProgressSeconds = startRealSeconds;
            Phase = HarnessPhase.Armed;
            Status = RunStatus.Running;
        }

        public HarnessPhase Phase { get; private set; }

        public RunStatus Status { get; private set; }

        /// <summary>Null while Running / Completed; otherwise "timeout:&lt;phase&gt;", "stall:&lt;phase&gt;" or "end-stall".</summary>
        public string Reason { get; private set; }

        /// <summary>Highest in-game day count observed in any phase before Quit.</summary>
        public int DaysReached { get; private set; }

        /// <summary>Number of map events the player entered (false -> true edges of PlayerInMapEvent).</summary>
        public int PlayerMapEvents { get; private set; }

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

        /// <summary>Key=value result record, LF-separated with a trailing LF.</summary>
        public string FormatResult(double realSeconds)
        {
            double elapsed = Math.Max(0, realSeconds - _startRealSeconds);
            double rate = elapsed > 0 ? DaysReached / (elapsed / 60.0) : 0;

            var sb = new StringBuilder();
            AppendLine(sb, "status", Status.ToString());
            AppendLine(sb, "reason", Reason ?? string.Empty);
            AppendLine(sb, "seed", _config.Seed.ToString(CultureInfo.InvariantCulture));
            AppendLine(sb, "mode", _config.Mode.ToString());
            AppendLine(sb, "daysRequested", _config.Days.ToString(CultureInfo.InvariantCulture));
            AppendLine(sb, "daysReached", DaysReached.ToString(CultureInfo.InvariantCulture));
            AppendLine(sb, "realSeconds", elapsed.ToString("F0", CultureInfo.InvariantCulture));
            AppendLine(sb, "gameDaysPerRealMinute", rate.ToString("F2", CultureInfo.InvariantCulture));
            AppendLine(sb, "playerMapEvents", PlayerMapEvents.ToString(CultureInfo.InvariantCulture));
            return sb.ToString();
        }

        /// <summary>
        /// Result record for an invalid run.cfg: same keys as <see cref="FormatResult"/>, status
        /// Aborted, reason "config:&lt;error on one line&gt;", every other value empty.
        /// </summary>
        public static string FormatConfigError(string error)
        {
            string oneLine = (error ?? string.Empty).Replace("\r", " ").Replace("\n", " ");

            var sb = new StringBuilder();
            AppendLine(sb, "status", RunStatus.Aborted.ToString());
            AppendLine(sb, "reason", "config:" + oneLine);
            AppendLine(sb, "seed", string.Empty);
            AppendLine(sb, "mode", string.Empty);
            AppendLine(sb, "daysRequested", string.Empty);
            AppendLine(sb, "daysReached", string.Empty);
            AppendLine(sb, "realSeconds", string.Empty);
            AppendLine(sb, "gameDaysPerRealMinute", string.Empty);
            AppendLine(sb, "playerMapEvents", string.Empty);
            return sb.ToString();
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

        private static void AppendLine(StringBuilder sb, string key, string value)
        {
            sb.Append(key).Append('=').Append(value).Append('\n');
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
            if (o.DaysElapsed >= _config.Days)
            {
                Status = RunStatus.Completed;
                EnterPhase(HarnessPhase.Ending, o.RealSeconds);
                return HarnessAction.RequestEndGame;
            }

            return HarnessAction.KeepRunning;
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
