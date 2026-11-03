using System;
using System.Collections.Generic;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// One in-game test, discovered in a plugin module and run by <see cref="ScenarioRunner"/>.
    /// <see cref="Run"/> is typically an iterator method: plain code between the yields runs on one
    /// game tick, each yielded <see cref="ScenarioStep"/> says what to wait for before resuming.
    /// </summary>
    public interface IScenario
    {
        /// <summary>Unique id, matched ordinally against the <c>scenarios=</c> and <c>health=</c> keys of run.cfg.</summary>
        string Id { get; }

        /// <summary>
        /// Called once per run; the steps are consumed one per resume. A health scenario
        /// (<c>health=</c>) is called twice on the same instance: before the soak (result id
        /// <c>&lt;id&gt;@0</c>) and after it (<c>&lt;id&gt;@&lt;days&gt;</c>), so it may keep state from
        /// the first call for the second one. It must not yield <see cref="ScenarioStep.Days"/>.
        /// </summary>
        IEnumerable<ScenarioStep> Run(IScenarioContext ctx);
    }

    /// <summary>What a running scenario can report back to the harness.</summary>
    public interface IScenarioContext
    {
        /// <summary>
        /// Records one check of the current scenario. A failed check fails the scenario but does
        /// not stop it; the remaining checks and scenarios still run.
        /// </summary>
        void Check(string name, bool passed, string expected, string actual);

        /// <summary>Writes one line to the harness log, prefixed with the scenario id.</summary>
        void Log(string message);

        /// <summary>
        /// In-game day count of the current tick: day changes (daily ticks) since the campaign
        /// session was launched, the same counter as <c>daysReached</c> in run-result.json. A health
        /// scenario sees the count at the map (normally 0) before the soak and at least the
        /// requested days after it.
        /// </summary>
        int Day { get; }
    }

    /// <summary>A wait yielded by a scenario. Created only through the factory methods.</summary>
    public sealed class ScenarioStep
    {
        internal enum StepKind { Ticks, Days, Until }

        private ScenarioStep(StepKind kind, int count, Func<bool> condition, double timeoutSeconds, string description)
        {
            Kind = kind;
            Count = count;
            Condition = condition;
            TimeoutSeconds = timeoutSeconds;
            Description = description;
        }

        internal StepKind Kind { get; }

        /// <summary>Ticks or days to wait; 0 for Until.</summary>
        internal int Count { get; }

        internal Func<bool> Condition { get; }

        internal double TimeoutSeconds { get; }

        internal string Description { get; }

        /// <summary>Resumes the scenario <paramref name="n"/> game ticks later (n &gt;= 1). Game time stays stopped.</summary>
        public static ScenarioStep Ticks(int n)
        {
            if (n < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(n), n, "must be at least 1");
            }

            return new ScenarioStep(StepKind.Ticks, n, null, 0, null);
        }

        /// <summary>
        /// Lets game time run until <paramref name="n"/> more day changes have passed since the
        /// yield (n &gt;= 1), then resumes the scenario. The engine counts daily ticks, so
        /// <c>Days(1)</c> ends at the next day change, i.e. after 0 to 24 in-game hours.
        /// </summary>
        public static ScenarioStep Days(int n)
        {
            if (n < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(n), n, "must be at least 1");
            }

            return new ScenarioStep(StepKind.Days, n, null, 0, null);
        }

        /// <summary>
        /// Resumes the scenario on the first later tick on which <paramref name="condition"/> is true.
        /// If it is still false <paramref name="timeoutSeconds"/> real seconds after the yield, the
        /// scenario ends as Timeout. Game time stays stopped while waiting.
        /// </summary>
        public static ScenarioStep Until(Func<bool> condition, double timeoutSeconds, string description)
        {
            if (condition == null)
            {
                throw new ArgumentNullException(nameof(condition));
            }

            if (double.IsNaN(timeoutSeconds) || double.IsInfinity(timeoutSeconds) || timeoutSeconds <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(timeoutSeconds), timeoutSeconds, "must be a finite number > 0");
            }

            return new ScenarioStep(StepKind.Until, 0, condition, timeoutSeconds, description);
        }
    }
}
