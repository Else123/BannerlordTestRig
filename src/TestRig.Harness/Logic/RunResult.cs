using System;
using System.Collections.Generic;

namespace TestRig.Harness.Logic
{
    /// <summary>Outcome of one scenario in run-result.json.</summary>
    public enum ScenarioStatus { Passed, Failed, Timeout, Error, Skipped }

    /// <summary>One loaded module, in load order.</summary>
    public sealed class ModuleEntry
    {
        public ModuleEntry(string id, string version)
        {
            Id = id;
            Version = version;
        }

        public string Id { get; }

        public string Version { get; }
    }

    /// <summary>How often one exception key was observed.</summary>
    public sealed class ExceptionKeyCount
    {
        public ExceptionKeyCount(string key, int count)
        {
            Key = key;
            Count = count;
        }

        public string Key { get; }

        public int Count { get; }
    }

    /// <summary>
    /// Cost and accuracy of the own/harness classification in the first-chance handler; see
    /// <see cref="ExceptionStats"/> and <see cref="OwnClassificationCache"/>.
    /// </summary>
    public sealed class ClassificationSummary
    {
        /// <summary>No exception classified yet: no walks, no time, and "own" trivially exact.</summary>
        public static readonly ClassificationSummary None = new ClassificationSummary(0, 0, 0, 0, true);

        public ClassificationSummary(int walks, double walkMs, double handlerMs, double maxHandlerMs, bool ownExact)
        {
            Walks = walks;
            WalkMs = walkMs;
            HandlerMs = handlerMs;
            MaxHandlerMs = maxHandlerMs;
            OwnExact = ownExact;
        }

        /// <summary>Stack walks granted for the own classification.</summary>
        public int Walks { get; }

        /// <summary>
        /// Part of <see cref="HandlerMs"/> spent in the handler calls that were granted a walk (stack
        /// capture and walk included), so <c>WalkMs / Walks</c> is the mean cost of a walked exception
        /// and <c>(HandlerMs - WalkMs) / (total - Walks)</c> the mean cost of the others.
        /// </summary>
        public double WalkMs { get; }

        /// <summary>Summed handler time in milliseconds over all first-chance exceptions.</summary>
        public double HandlerMs { get; }

        /// <summary>Longest single handler time in milliseconds.</summary>
        public double MaxHandlerMs { get; }

        /// <summary>False once an exception was classified without its own stack walk (walk budget spent) or a walk failed.</summary>
        public bool OwnExact { get; }
    }

    /// <summary>Exception counters of a whole run; see <see cref="ExceptionStats"/>.</summary>
    public sealed class ExceptionSummary
    {
        public static readonly ExceptionSummary Empty =
            new ExceptionSummary(0, 0, 0, 0, new ExceptionKeyCount[0], ClassificationSummary.None);

        /// <param name="harness">Not own and thrown in a harness assembly; disjoint from <paramref name="own"/>.</param>
        public ExceptionSummary(int total, int own, int harness, int unhandled,
            IReadOnlyList<ExceptionKeyCount> top, ClassificationSummary classification)
        {
            Total = total;
            Own = own;
            Harness = harness;
            Unhandled = unhandled;
            Top = top ?? throw new ArgumentNullException(nameof(top));
            Classification = classification ?? throw new ArgumentNullException(nameof(classification));
        }

        public int Total { get; }

        public int Own { get; }

        public int Harness { get; }

        /// <summary>Neither own nor harness: <c>Total - Own - Harness</c>.</summary>
        public int Vanilla
        {
            get { return Total - Own - Harness; }
        }

        public int Unhandled { get; }

        /// <summary>Most frequent keys, by count descending then key ordinal.</summary>
        public IReadOnlyList<ExceptionKeyCount> Top { get; }

        public ClassificationSummary Classification { get; }
    }

    public sealed class ScenarioResult
    {
        public ScenarioResult(string id, ScenarioStatus status, int? seconds)
        {
            Id = id;
            Status = status;
            Seconds = seconds;
        }

        public string Id { get; }

        public ScenarioStatus Status { get; }

        /// <summary>Null when unknown.</summary>
        public int? Seconds { get; }
    }

    public sealed class CheckResult
    {
        public CheckResult(string scenario, string name, string expected, string actual, bool passed)
        {
            Scenario = scenario;
            Name = name;
            Expected = expected;
            Actual = actual;
            Passed = passed;
        }

        /// <summary>Id of the scenario the check belongs to ("soak" for the soak check); null when unknown.</summary>
        public string Scenario { get; }

        public string Name { get; }

        public string Expected { get; }

        public string Actual { get; }

        public bool Passed { get; }
    }

    /// <summary>
    /// Content of run-result.json (schema 1), written by <see cref="RunResultWriter"/>.
    /// Nullable values are unknown and written as JSON null.
    /// </summary>
    public sealed class RunResult
    {
        public const int Schema = 1;

        /// <summary>Id of the scenario of a soak run (run.cfg without <c>scenarios=</c>).</summary>
        public const string SoakScenarioId = "soak";

        public RunResult(
            RunStatus status,
            string reason,
            int? seed,
            string mode,
            int? daysRequested,
            int? daysReached,
            int? realSeconds,
            double? gameDaysPerRealMinute,
            double? runningDaysPerRealMinute,
            int? playerMapEvents,
            IReadOnlyList<ModuleEntry> modules,
            ExceptionSummary exceptions,
            IReadOnlyList<ScenarioResult> scenarios,
            IReadOnlyList<CheckResult> checks)
        {
            Status = status;
            Reason = reason;
            Seed = seed;
            Mode = mode;
            DaysRequested = daysRequested;
            DaysReached = daysReached;
            RealSeconds = realSeconds;
            GameDaysPerRealMinute = gameDaysPerRealMinute;
            RunningDaysPerRealMinute = runningDaysPerRealMinute;
            PlayerMapEvents = playerMapEvents;
            Modules = modules ?? throw new ArgumentNullException(nameof(modules));
            Exceptions = exceptions ?? throw new ArgumentNullException(nameof(exceptions));
            Scenarios = scenarios ?? throw new ArgumentNullException(nameof(scenarios));
            Checks = checks ?? throw new ArgumentNullException(nameof(checks));
        }

        public RunStatus Status { get; }

        /// <summary>"" when there is no reason.</summary>
        public string Reason { get; }

        public int? Seed { get; }

        public string Mode { get; }

        public int? DaysRequested { get; }

        public int? DaysReached { get; }

        public int? RealSeconds { get; }

        /// <summary>Rounded to two decimals.</summary>
        public double? GameDaysPerRealMinute { get; }

        /// <summary>
        /// Game days per real minute over the Running phase only (from entering it until it ends,
        /// or until now while it lasts), in health mode over its soak segment only; rounded to two
        /// decimals. Null before that window began or when it has no measurable duration.
        /// </summary>
        public double? RunningDaysPerRealMinute { get; }

        public int? PlayerMapEvents { get; }

        /// <summary>Loaded modules in load order; empty when unknown.</summary>
        public IReadOnlyList<ModuleEntry> Modules { get; }

        public ExceptionSummary Exceptions { get; }

        public IReadOnlyList<ScenarioResult> Scenarios { get; }

        public IReadOnlyList<CheckResult> Checks { get; }

        /// <summary>
        /// Record for an invalid run.cfg: status Aborted, reason "config:&lt;error on one line&gt;",
        /// every run value unknown, the soak scenario an Error and no checks.
        /// </summary>
        public static RunResult ForConfigError(string error, IReadOnlyList<ModuleEntry> modules)
        {
            return ForConfigError(error, modules, new string[0]);
        }

        /// <summary>
        /// Like <see cref="ForConfigError(string, IReadOnlyList{ModuleEntry})"/> for a run.cfg whose
        /// requested scenarios could not be resolved: each requested id (once, in requested order)
        /// is an Error instead of the soak scenario. No requested ids gives the soak Error.
        /// </summary>
        public static RunResult ForConfigError(string error, IReadOnlyList<ModuleEntry> modules, IReadOnlyList<string> requestedScenarios)
        {
            if (requestedScenarios == null)
            {
                throw new ArgumentNullException(nameof(requestedScenarios));
            }

            var scenarios = new List<ScenarioResult>();
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (string id in requestedScenarios)
            {
                if (id != null && seen.Add(id))
                {
                    scenarios.Add(new ScenarioResult(id, ScenarioStatus.Error, null));
                }
            }

            if (scenarios.Count == 0)
            {
                scenarios.Add(new ScenarioResult(SoakScenarioId, ScenarioStatus.Error, null));
            }

            string oneLine = (error ?? string.Empty).Replace("\r", " ").Replace("\n", " ");
            return new RunResult(
                RunStatus.Aborted,
                "config:" + oneLine,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                null,
                modules,
                ExceptionSummary.Empty,
                scenarios,
                new CheckResult[0]);
        }
    }
}
