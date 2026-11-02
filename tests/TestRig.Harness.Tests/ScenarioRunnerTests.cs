using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class ScenarioRunnerTests
    {
        // ---------------------------------------------------------------- helpers

        private readonly List<string> _log = new List<string>();

        /// <summary>Fake scenario whose body is an iterator method; counts how often Run is called.</summary>
        private sealed class FakeScenario : IScenario
        {
            private readonly Func<IScenarioContext, IEnumerable<ScenarioStep>> _body;

            public FakeScenario(string id, Func<IScenarioContext, IEnumerable<ScenarioStep>> body)
            {
                Id = id;
                _body = body;
            }

            public string Id { get; }

            public int RunCalls { get; private set; }

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                RunCalls++;
                return _body(ctx);
            }
        }

        private static FakeScenario Scenario(string id, Func<IScenarioContext, IEnumerable<ScenarioStep>> body)
        {
            return new FakeScenario(id, body);
        }

        private ScenarioRunner NewRunner(params IScenario[] scenarios)
        {
            return new ScenarioRunner(scenarios, _log.Add);
        }

        private static ScenarioResult ResultOf(ScenarioRunner runner, string id)
        {
            return runner.Results.Single(r => r.Id == id);
        }

        // Iterator bodies (lambdas cannot yield).

        private static IEnumerable<ScenarioStep> PassImmediately(IScenarioContext ctx)
        {
            ctx.Check("ok", true, "true", "true");
            yield break;
        }

        private static IEnumerable<ScenarioStep> FailOneOfTwo(IScenarioContext ctx)
        {
            ctx.Check("first", false, "1", "2");
            ctx.Check("second", true, "3", "3");
            yield break;
        }

        private static IEnumerable<ScenarioStep> NoChecks(IScenarioContext ctx)
        {
            ctx.Log("doing nothing");
            yield break;
        }

        private static IEnumerable<ScenarioStep> WaitThreeTicksThenPass(IScenarioContext ctx)
        {
            yield return ScenarioStep.Ticks(3);
            ctx.Check("after ticks", true, "x", "x");
        }

        private static IEnumerable<ScenarioStep> WaitTwoDaysThenPass(IScenarioContext ctx)
        {
            yield return ScenarioStep.Days(2);
            ctx.Check("after days", true, "x", "x");
        }

        private static IEnumerable<ScenarioStep> WaitForever(IScenarioContext ctx)
        {
            yield return ScenarioStep.Until(() => false, 10000, "never");
            ctx.Check("unreachable", true, "x", "x");
        }

        private static IEnumerable<ScenarioStep> WaitTenSecondsForNothing(IScenarioContext ctx)
        {
            yield return ScenarioStep.Until(() => false, 10, "never");
            ctx.Check("unreachable", true, "x", "x");
        }

        // Makes step progress on every tick and never finishes.
        private static IEnumerable<ScenarioStep> TickForever(IScenarioContext ctx)
        {
            while (true)
            {
                yield return ScenarioStep.Ticks(1);
            }
        }

        private static IEnumerable<ScenarioStep> ThrowAfterOneTick(IScenarioContext ctx)
        {
            yield return ScenarioStep.Ticks(1);
            throw new InvalidOperationException("boom in scenario");
        }

        private static IEnumerable<ScenarioStep> ConditionThrows(IScenarioContext ctx)
        {
            yield return ScenarioStep.Until(() => throw new InvalidOperationException("boom in condition"), 100, "throws");
            ctx.Check("unreachable", true, "x", "x");
        }

        private static IEnumerable<ScenarioStep> LogHello(IScenarioContext ctx)
        {
            ctx.Log("hello from scenario");
            ctx.Check("ok", true, "true", "true");
            yield break;
        }

        private static IEnumerable<ScenarioStep> WaitOneTickThenPass(IScenarioContext ctx)
        {
            yield return ScenarioStep.Ticks(1);
            ctx.Check("ok", true, "true", "true");
        }

        // ------------------------------------------------- scenario steps

        [Theory]
        [InlineData(0)]
        [InlineData(-1)]
        public void Ticks_LessThanOne_Throws(int n)
        {
            Assert.ThrowsAny<ArgumentException>(() => ScenarioStep.Ticks(n));
        }

        [Theory]
        [InlineData(0)]
        [InlineData(-3)]
        public void Days_LessThanOne_Throws(int n)
        {
            Assert.ThrowsAny<ArgumentException>(() => ScenarioStep.Days(n));
        }

        [Theory]
        [InlineData(0.0)]
        [InlineData(-1.0)]
        [InlineData(double.NaN)]
        public void Until_TimeoutNotPositive_Throws(double timeout)
        {
            Assert.ThrowsAny<ArgumentException>(() => ScenarioStep.Until(() => true, timeout, "d"));
        }

        [Fact]
        public void Until_NullCondition_Throws()
        {
            Assert.ThrowsAny<ArgumentException>(() => ScenarioStep.Until(null, 5, "d"));
        }

        [Fact]
        public void Steps_ValidArguments_AreCreated()
        {
            Assert.NotNull(ScenarioStep.Ticks(1));
            Assert.NotNull(ScenarioStep.Days(1));
            Assert.NotNull(ScenarioStep.Until(() => true, 0.5, "d"));
        }

        // ------------------------------------------------- run.cfg scenarios key

        private const string BaseCfg = "seed=1\ndays=1\nmode=WarSails\n";

        [Fact]
        public void Parse_WithoutScenariosKey_HasNoScenarios()
        {
            RunConfigResult result = RunConfig.Parse(BaseCfg);

            Assert.Equal(RunConfigStatus.Valid, result.Status);
            Assert.Empty(result.Config.Scenarios);
        }

        [Fact]
        public void Parse_ScenariosKey_IsTrimmedListInOrder()
        {
            RunConfigResult result = RunConfig.Parse(BaseCfg + "scenarios= smithing.b , smithing.a ");

            Assert.Equal(RunConfigStatus.Valid, result.Status);
            Assert.Equal(new[] { "smithing.b", "smithing.a" }, result.Config.Scenarios);
        }

        [Fact]
        public void Parse_ScenariosKey_IsCaseInsensitive()
        {
            RunConfigResult result = RunConfig.Parse(BaseCfg + "SCENARIOS=a");

            Assert.Equal(RunConfigStatus.Valid, result.Status);
            Assert.Equal(new[] { "a" }, result.Config.Scenarios);
        }

        [Theory]
        [InlineData("scenarios=")]
        [InlineData("scenarios=   ")]
        [InlineData("scenarios= , ")]
        [InlineData("scenarios=a,b,a")]
        [InlineData("scenarios=a\nscenarios=b")]
        [InlineData("scenarios=a\u0000")]
        public void Parse_BadScenariosValue_IsInvalidAndNamesTheKey(string line)
        {
            RunConfigResult result = RunConfig.Parse(BaseCfg + line);

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Null(result.Config);
            Assert.Contains("scenarios", result.Error);
        }

        // ------------------------------------------------- resolution

        [Fact]
        public void Resolve_KeepsRequestedOrderAndInstances()
        {
            FakeScenario a = Scenario("a", PassImmediately);
            FakeScenario b = Scenario("b", PassImmediately);
            FakeScenario c = Scenario("c", PassImmediately);

            ScenarioResolution resolution = ScenarioRunner.Resolve(new[] { "c", "a" }, new IScenario[] { b, a, c });

            Assert.True(resolution.IsValid);
            Assert.Null(resolution.Error);
            Assert.Equal(2, resolution.Scenarios.Count);
            Assert.Same(c, resolution.Scenarios[0]);
            Assert.Same(a, resolution.Scenarios[1]);
        }

        [Fact]
        public void Resolve_UnknownId_IsErrorNamingTheId()
        {
            ScenarioResolution resolution = ScenarioRunner.Resolve(
                new[] { "a", "missing.one" }, new IScenario[] { Scenario("a", PassImmediately) });

            Assert.False(resolution.IsValid);
            Assert.Null(resolution.Scenarios);
            Assert.Contains("missing.one", resolution.Error);
        }

        [Fact]
        public void Resolve_RequestedIdDiscoveredTwice_IsErrorNamingTheId()
        {
            ScenarioResolution resolution = ScenarioRunner.Resolve(
                new[] { "dup.id" },
                new IScenario[] { Scenario("dup.id", PassImmediately), Scenario("dup.id", PassImmediately) });

            Assert.False(resolution.IsValid);
            Assert.Contains("dup.id", resolution.Error);
        }

        [Fact]
        public void Resolve_UnrequestedIdDiscoveredTwice_IsIgnored()
        {
            ScenarioResolution resolution = ScenarioRunner.Resolve(
                new[] { "a" },
                new IScenario[] { Scenario("a", PassImmediately), Scenario("x", PassImmediately), Scenario("x", PassImmediately) });

            Assert.True(resolution.IsValid);
            Assert.Single(resolution.Scenarios);
        }

        // ------------------------------------------------- runner: stepping and statuses

        [Fact]
        public void Constructor_NullScenarios_Throws()
        {
            Assert.Throws<ArgumentNullException>(() => new ScenarioRunner(null, _log.Add));
        }

        [Fact]
        public void BeforeFirstTick_NothingRunsAndNothingIsFinished()
        {
            FakeScenario a = Scenario("a", PassImmediately);
            ScenarioRunner runner = NewRunner(a);

            Assert.Equal(0, a.RunCalls);
            Assert.False(runner.IsFinished);
            Assert.Empty(runner.Results);
            Assert.False(runner.TimeShouldRun);
        }

        [Fact]
        public void ScenarioWithoutWaits_PassesOnFirstTick()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", PassImmediately));

            runner.Tick(5, 0);

            Assert.True(runner.IsFinished);
            Assert.False(runner.IsTainted);
            ScenarioResult a = Assert.Single(runner.Results);
            Assert.Equal("a", a.Id);
            Assert.Equal(ScenarioStatus.Passed, a.Status);
            Assert.Equal(0, a.Seconds);
            CheckResult check = Assert.Single(runner.Checks);
            Assert.Equal("a", check.Scenario);
            Assert.Equal("ok", check.Name);
            Assert.True(check.Passed);
        }

        [Fact]
        public void Ticks_ResumesExactlyNTicksLater()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", WaitThreeTicksThenPass));

            runner.Tick(0, 0);   // starts the scenario, yields Ticks(3)
            runner.Tick(1, 0);
            runner.Tick(2, 0);
            Assert.False(runner.IsFinished);
            Assert.Empty(runner.Checks);

            runner.Tick(3, 0);

            Assert.True(runner.IsFinished);
            Assert.Equal(ScenarioStatus.Passed, ResultOf(runner, "a").Status);
        }

        [Fact]
        public void Until_ResumesOnceConditionIsTrue()
        {
            bool ready = false;
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                yield return ScenarioStep.Until(() => ready, 60, "ready");
                ctx.Check("ready", ready, "True", ready.ToString());
            }

            ScenarioRunner runner = NewRunner(Scenario("a", Body));

            runner.Tick(0, 0);
            runner.Tick(1, 0);
            runner.Tick(2, 0);
            Assert.False(runner.IsFinished);

            ready = true;
            runner.Tick(3, 0);

            Assert.True(runner.IsFinished);
            Assert.Equal(ScenarioStatus.Passed, ResultOf(runner, "a").Status);
        }

        [Fact]
        public void Until_TimeoutInRealSeconds_IsTimeoutAndTaintsTheRest()
        {
            FakeScenario b = Scenario("b", PassImmediately);
            ScenarioRunner runner = NewRunner(Scenario("a", WaitTenSecondsForNothing), b);

            runner.Tick(100, 0);
            runner.Tick(109, 0);
            Assert.False(runner.IsFinished);

            runner.Tick(110, 0);

            Assert.True(runner.IsFinished);
            Assert.True(runner.IsTainted);
            Assert.Equal(ScenarioStatus.Timeout, ResultOf(runner, "a").Status);
            Assert.Equal(10, ResultOf(runner, "a").Seconds);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "b").Status);
            Assert.Null(ResultOf(runner, "b").Seconds);
            Assert.Equal(0, b.RunCalls);
        }

        [Fact]
        public void Days_WaitsForNMoreGameDaysFromTheYield()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", WaitTwoDaysThenPass));

            runner.Tick(0, 5);   // yields Days(2) at day 5
            runner.Tick(1, 6);
            Assert.False(runner.IsFinished);

            runner.Tick(2, 7);

            Assert.True(runner.IsFinished);
            Assert.Equal(ScenarioStatus.Passed, ResultOf(runner, "a").Status);
        }

        [Fact]
        public void TimeShouldRun_OnlyWhileWaitingOnDays()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", WaitTwoDaysThenPass));

            runner.Tick(0, 0);
            Assert.True(runner.TimeShouldRun);

            runner.Tick(1, 1);
            Assert.True(runner.TimeShouldRun);

            runner.Tick(2, 2);
            Assert.False(runner.TimeShouldRun);
        }

        [Fact]
        public void TimeShouldRun_IsFalseWhileWaitingOnTicksOrUntil()
        {
            ScenarioRunner ticks = NewRunner(Scenario("a", WaitThreeTicksThenPass));
            ticks.Tick(0, 0);
            Assert.False(ticks.TimeShouldRun);

            ScenarioRunner until = NewRunner(Scenario("a", WaitForever));
            until.Tick(0, 0);
            Assert.False(until.TimeShouldRun);
        }

        [Fact]
        public void FailedCheck_FailsScenarioButNextScenarioStillRuns()
        {
            FakeScenario b = Scenario("b", PassImmediately);
            ScenarioRunner runner = NewRunner(Scenario("a", FailOneOfTwo), b);

            for (int i = 0; i < 5; i++)
            {
                runner.Tick(i, 0);
            }

            Assert.True(runner.IsFinished);
            Assert.False(runner.IsTainted);
            Assert.Equal(ScenarioStatus.Failed, ResultOf(runner, "a").Status);
            Assert.Equal(ScenarioStatus.Passed, ResultOf(runner, "b").Status);
            Assert.Equal(1, b.RunCalls);
        }

        [Fact]
        public void FailedCheck_DoesNotStopTheScenario_AllChecksRecordedInOrder()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", FailOneOfTwo), Scenario("b", PassImmediately));

            for (int i = 0; i < 5; i++)
            {
                runner.Tick(i, 0);
            }

            Assert.Equal(new[] { "a/first", "a/second", "b/ok" }, runner.Checks.Select(c => c.Scenario + "/" + c.Name));
            CheckResult first = runner.Checks[0];
            Assert.False(first.Passed);
            Assert.Equal("1", first.Expected);
            Assert.Equal("2", first.Actual);
        }

        // Spec: "Nach Timeout oder Ausnahme: Rest Skipped" - a scenario without checks is an Error,
        // but the game state is known, so it does not taint the rest of the run.
        [Fact]
        public void ScenarioWithoutChecks_IsErrorButDoesNotTaint()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", NoChecks), Scenario("b", PassImmediately));

            for (int i = 0; i < 5; i++)
            {
                runner.Tick(i, 0);
            }

            Assert.Equal(ScenarioStatus.Error, ResultOf(runner, "a").Status);
            Assert.Equal(ScenarioStatus.Passed, ResultOf(runner, "b").Status);
            Assert.False(runner.IsTainted);
        }

        [Fact]
        public void ExceptionFromIterator_IsErrorAndTaintsTheRest()
        {
            FakeScenario c = Scenario("c", PassImmediately);
            ScenarioRunner runner = NewRunner(Scenario("a", ThrowAfterOneTick), Scenario("b", PassImmediately), c);

            runner.Tick(0, 0);
            runner.Tick(1, 0);

            Assert.True(runner.IsFinished);
            Assert.True(runner.IsTainted);
            Assert.Equal(ScenarioStatus.Error, ResultOf(runner, "a").Status);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "b").Status);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "c").Status);
            Assert.Equal(0, c.RunCalls);
            Assert.Contains(_log, line => line.Contains("boom in scenario"));
        }

        [Fact]
        public void ExceptionFromUntilCondition_IsErrorAndTaintsTheRest()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", ConditionThrows), Scenario("b", PassImmediately));

            for (int i = 0; i < 3; i++)
            {
                runner.Tick(i, 0);
            }

            Assert.True(runner.IsTainted);
            Assert.Equal(ScenarioStatus.Error, ResultOf(runner, "a").Status);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "b").Status);
        }

        [Fact]
        public void PerScenarioLimit_Is300RealSeconds()
        {
            Assert.Equal(300.0, ScenarioRunner.ScenarioTimeLimitSeconds);
        }

        [Fact]
        public void PerScenarioLimit_TimesOutAWaitingScenario()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", WaitForever), Scenario("b", PassImmediately));

            runner.Tick(50, 0);
            runner.Tick(349, 0);
            Assert.False(runner.IsFinished);

            runner.Tick(350, 0);

            Assert.True(runner.IsTainted);
            Assert.Equal(ScenarioStatus.Timeout, ResultOf(runner, "a").Status);
            Assert.Equal(300, ResultOf(runner, "a").Seconds);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "b").Status);
        }

        [Fact]
        public void PerScenarioLimit_TimesOutAScenarioThatKeepsStepping()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", TickForever));

            for (int t = 0; t < 300; t += 10)
            {
                runner.Tick(t, 0);
            }

            Assert.False(runner.IsFinished);

            runner.Tick(300, 0);

            Assert.Equal(ScenarioStatus.Timeout, ResultOf(runner, "a").Status);
        }

        [Fact]
        public void Seconds_AreRealSecondsFromStartToFinish_RoundedAwayFromZero()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", WaitOneTickThenPass));

            runner.Tick(10, 0);
            runner.Tick(16.5, 0);

            Assert.Equal(7, ResultOf(runner, "a").Seconds);
        }

        [Fact]
        public void Results_FollowScenarioOrder_AndGrowByOnePerFinishedScenario()
        {
            ScenarioRunner runner = NewRunner(
                Scenario("a", WaitOneTickThenPass), Scenario("b", WaitOneTickThenPass), Scenario("c", WaitOneTickThenPass));
            var counts = new List<int>();

            for (int i = 0; i < 10 && !runner.IsFinished; i++)
            {
                runner.Tick(i, 0);
                if (counts.Count == 0 || counts[counts.Count - 1] != runner.Results.Count)
                {
                    counts.Add(runner.Results.Count);
                }
            }

            Assert.Equal(new[] { "a", "b", "c" }, runner.Results.Select(r => r.Id));
            Assert.Equal(new[] { 0, 1, 2, 3 }, counts.SkipWhile(c => c == 0).Prepend(0));
            Assert.All(runner.Results, r => Assert.Equal(ScenarioStatus.Passed, r.Status));
        }

        [Fact]
        public void EachScenario_IsRunExactlyOnce_AndTicksAfterFinishAreHarmless()
        {
            FakeScenario a = Scenario("a", PassImmediately);
            FakeScenario b = Scenario("b", WaitOneTickThenPass);
            ScenarioRunner runner = NewRunner(a, b);

            for (int i = 0; i < 10; i++)
            {
                runner.Tick(i, 0);
            }

            Assert.Equal(1, a.RunCalls);
            Assert.Equal(1, b.RunCalls);
            Assert.Equal(2, runner.Results.Count);
            Assert.Equal(2, runner.Checks.Count);
        }

        [Fact]
        public void Log_IsForwardedToTheLogger()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", LogHello));

            runner.Tick(0, 0);

            Assert.Contains(_log, line => line.Contains("hello from scenario"));
        }

        [Fact]
        public void Abort_CurrentScenarioTimesOut_RestSkipped()
        {
            ScenarioRunner runner = NewRunner(
                Scenario("a", PassImmediately), Scenario("b", WaitForever), Scenario("c", PassImmediately));

            for (int i = 0; i < 4; i++)
            {
                runner.Tick(i, 0);
            }

            runner.Abort(50);

            Assert.True(runner.IsFinished);
            Assert.Equal(new[] { "a", "b", "c" }, runner.Results.Select(r => r.Id));
            Assert.Equal(ScenarioStatus.Passed, ResultOf(runner, "a").Status);
            Assert.Equal(ScenarioStatus.Timeout, ResultOf(runner, "b").Status);
            Assert.NotNull(ResultOf(runner, "b").Seconds);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "c").Status);
            Assert.False(runner.TimeShouldRun);
        }

        [Fact]
        public void Abort_BeforeFirstTick_SkipsAll()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", PassImmediately), Scenario("b", PassImmediately));

            runner.Abort(10);

            Assert.True(runner.IsFinished);
            Assert.All(runner.Results, r => Assert.Equal(ScenarioStatus.Skipped, r.Status));
            Assert.Equal(2, runner.Results.Count);
        }

        [Fact]
        public void Abort_AfterFinish_ChangesNothing()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", PassImmediately));
            runner.Tick(0, 0);

            runner.Abort(10);

            Assert.Equal(ScenarioStatus.Passed, Assert.Single(runner.Results).Status);
        }

        [Fact]
        public void ScenarioThrows_LogsOneLineWithTypeAndMessageOnly()
        {
            ScenarioRunner runner = NewRunner(Scenario("a", ThrowAfterOneTick));
            runner.Tick(0, 0);

            runner.Tick(1, 0);

            string line = Assert.Single(_log, l => l.Contains("threw"));
            Assert.Contains("InvalidOperationException: boom in scenario", line);
            Assert.DoesNotContain("\n", line);
            Assert.DoesNotContain(" at ", line);
        }

        [Fact]
        public void DisposeThrows_LogsOneLineWithTypeAndMessageOnly()
        {
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                try
                {
                    yield return ScenarioStep.Until(() => false, 100, "never");
                }
                finally
                {
                    throw new InvalidOperationException("boom in finally");
                }
            }

            ScenarioRunner runner = NewRunner(Scenario("a", Body));
            runner.Tick(0, 0);

            runner.Abort(1);

            string line = Assert.Single(_log, l => l.Contains("dispose threw"));
            Assert.Contains("InvalidOperationException: boom in finally", line);
            Assert.DoesNotContain("\n", line);
            Assert.DoesNotContain(" at ", line);
        }

        [Fact]
        public void LogThrowingInsideEnd_DoesNotEscapeTick()
        {
            var runner = new ScenarioRunner(
                new IScenario[] { Scenario("a", PassImmediately) },
                m =>
                {
                    if (m.Contains("Passed"))
                    {
                        throw new InvalidOperationException("log broken");
                    }
                });

            Exception thrown = Record.Exception(() => runner.Tick(0, 0));

            Assert.Null(thrown);
            Assert.True(runner.IsFinished);
        }

        // ------------------------------------------------- HarnessRun integration

        private static HarnessObservation Obs(double t, bool menu = false, bool map = false, bool inGame = false, int days = 0)
        {
            return new HarnessObservation
            {
                RealSeconds = t,
                MainMenuActive = menu,
                MapActive = map,
                InGame = inGame,
                DaysElapsed = days,
            };
        }

        private static HarnessObservation OnMap(double t, int days = 0)
        {
            return Obs(t, map: true, inGame: true, days: days);
        }

        private static void DriveToRunning(HarnessRun run, double t)
        {
            run.Tick(Obs(t, menu: true));
            run.Tick(OnMap(t));
            run.Tick(OnMap(t));
            Assert.Equal(HarnessPhase.Running, run.Phase);
        }

        private HarnessRun NewScenarioRun(double stallMinutes, double budgetMinutes, params IScenario[] scenarios)
        {
            string text = string.Format(CultureInfo.InvariantCulture,
                "seed=3\ndays=1\nmode=NoDlc\nstallMinutes={0}\nbudgetMinutes={1}\nscenarios={2}",
                stallMinutes, budgetMinutes, string.Join(",", scenarios.Select(s => s.Id)));
            RunConfigResult parsed = RunConfig.Parse(text);
            Assert.Equal(RunConfigStatus.Valid, parsed.Status);
            return new HarnessRun(parsed.Config, 0, new ScenarioRunner(scenarios, _log.Add));
        }

        private HarnessRun NewScenarioRun(params IScenario[] scenarios)
        {
            return NewScenarioRun(5, 60, scenarios);
        }

        private static RunResult ToResult(HarnessRun run, double t)
        {
            return run.ToResult(t, new ModuleEntry[0], ExceptionSummary.Empty);
        }

        [Fact]
        public void Soak_DaysReachedCheck_BelongsToScenarioSoak()
        {
            HarnessRun run = new HarnessRun(RunConfig.Parse(BaseCfg).Config, 0);
            DriveToRunning(run, 0);
            run.Tick(OnMap(10, days: 1));

            CheckResult check = Assert.Single(ToResult(run, 10).Checks);
            Assert.Equal("soak", check.Scenario);
            Assert.Equal("daysReached", check.Name);
        }

        [Fact]
        public void Soak_TimeShouldRunInPhaseRunning()
        {
            HarnessRun run = new HarnessRun(RunConfig.Parse(BaseCfg).Config, 0);
            DriveToRunning(run, 0);

            Assert.True(run.TimeShouldRun);
        }

        [Fact]
        public void ScenarioRun_RunnerIsNotDrivenBeforePhaseRunning()
        {
            FakeScenario a = Scenario("a", PassImmediately);
            HarnessRun run = NewScenarioRun(a);

            DriveToRunning(run, 0);

            Assert.Equal(0, a.RunCalls);
            Assert.False(run.TimeShouldRun);
        }

        [Fact]
        public void ScenarioRun_AfterLastScenario_CompletesAndEndsTheGame()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately), Scenario("b", WaitOneTickThenPass));
            DriveToRunning(run, 0);

            HarnessAction last = HarnessAction.None;
            for (int t = 1; t < 10 && run.Phase == HarnessPhase.Running; t++)
            {
                last = run.Tick(OnMap(t));
            }

            Assert.Equal(HarnessAction.RequestEndGame, last);
            Assert.Equal(HarnessPhase.Ending, run.Phase);
            Assert.Equal(RunStatus.Completed, run.Status);
            Assert.Null(run.Reason);
        }

        [Fact]
        public void ScenarioRun_DaysKeyIsNotEvaluated()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", WaitForever));
            DriveToRunning(run, 0);

            HarnessAction action = run.Tick(OnMap(1, days: 5));
            action = run.Tick(OnMap(2, days: 6));

            Assert.Equal(HarnessAction.KeepRunning, action);
            Assert.Equal(HarnessPhase.Running, run.Phase);
            Assert.Equal(RunStatus.Running, run.Status);
        }

        [Fact]
        public void ScenarioRun_TimeShouldRunFollowsTheCurrentStep()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", WaitTwoDaysThenPass), Scenario("b", WaitForever));
            DriveToRunning(run, 0);

            run.Tick(OnMap(1, days: 0));
            Assert.True(run.TimeShouldRun);

            run.Tick(OnMap(2, days: 2));   // a resumes and passes; b waits on Until
            run.Tick(OnMap(3, days: 2));
            Assert.False(run.TimeShouldRun);
        }

        [Fact]
        public void ScenarioRun_Result_HasScenarioEntriesAndChecksButNoSoak()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately), Scenario("b", FailOneOfTwo));
            DriveToRunning(run, 0);
            for (int t = 1; t < 10 && run.Phase == HarnessPhase.Running; t++)
            {
                run.Tick(OnMap(t));
            }

            RunResult result = ToResult(run, 20);

            Assert.Equal(RunStatus.Completed, result.Status);
            Assert.Equal(new[] { "a", "b" }, result.Scenarios.Select(s => s.Id));
            Assert.Equal(ScenarioStatus.Passed, result.Scenarios[0].Status);
            Assert.Equal(ScenarioStatus.Failed, result.Scenarios[1].Status);
            Assert.DoesNotContain(result.Scenarios, s => s.Id == "soak");
            Assert.DoesNotContain(result.Checks, c => c.Name == "daysReached");
            Assert.Equal(new[] { "a", "b", "b" }, result.Checks.Select(c => c.Scenario));
        }

        [Fact]
        public void ScenarioRun_ScenariosFinished_CountsUpForResultRewrite()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", WaitOneTickThenPass), Scenario("b", WaitOneTickThenPass));
            DriveToRunning(run, 0);
            Assert.Equal(0, run.ScenariosFinished);

            var seen = new List<int>();
            for (int t = 1; t < 10 && run.Phase == HarnessPhase.Running; t++)
            {
                run.Tick(OnMap(t));
                if (seen.Count == 0 || seen[seen.Count - 1] != run.ScenariosFinished)
                {
                    seen.Add(run.ScenariosFinished);
                }
            }

            Assert.Equal(new[] { 0, 1, 2 }, seen.SkipWhile(c => c == 0).Prepend(0));
            Assert.Equal(2, ToResult(run, 10).Scenarios.Count);
        }

        [Fact]
        public void ScenarioRun_PartialResult_ListsOnlyFinishedScenarios()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately), Scenario("b", WaitForever));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));
            run.Tick(OnMap(2));

            RunResult result = ToResult(run, 2);

            Assert.Equal(RunStatus.Running, result.Status);
            Assert.Equal(1, run.ScenariosFinished);
            Assert.Equal("a", Assert.Single(result.Scenarios).Id);
        }

        [Fact]
        public void ScenarioRun_TimeoutTaintsRunAndEndsGame()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", WaitTenSecondsForNothing), Scenario("b", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));

            HarnessAction action = run.Tick(OnMap(11));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(HarnessPhase.Ending, run.Phase);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("tainted:a", run.Reason);
            RunResult result = ToResult(run, 11);
            Assert.Equal(ScenarioStatus.Timeout, result.Scenarios[0].Status);
            Assert.Equal(ScenarioStatus.Skipped, result.Scenarios[1].Status);
        }

        [Fact]
        public void ScenarioRun_ExceptionTaintsRunAndEndsGame()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", ThrowAfterOneTick), Scenario("b", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));

            HarnessAction action = run.Tick(OnMap(2));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("tainted:a", run.Reason);
            RunResult result = ToResult(run, 2);
            Assert.Equal(ScenarioStatus.Error, result.Scenarios[0].Status);
            Assert.Equal(ScenarioStatus.Skipped, result.Scenarios[1].Status);
        }

        [Fact]
        public void ScenarioRun_StepProgressCountsAgainstStall()
        {
            // stall 1 min, no new days (time is stopped), but the scenario steps every tick.
            HarnessRun run = NewScenarioRun(1, 60, Scenario("a", TickForever));
            DriveToRunning(run, 0);

            for (int t = 30; t <= 240; t += 30)
            {
                run.Tick(OnMap(t));
            }

            Assert.Equal(HarnessPhase.Running, run.Phase);
            Assert.Equal(RunStatus.Running, run.Status);
        }

        private static IEnumerable<ScenarioStep> WaitTwoMinutesForNothing(IScenarioContext ctx)
        {
            yield return ScenarioStep.Until(() => false, 120, "never");
            ctx.Check("unreachable", true, "x", "x");
        }

        [Fact]
        public void ScenarioRun_UntilLongerThanStall_TimesOutViaItsOwnLimitNotStall()
        {
            HarnessRun run = NewScenarioRun(1, 60, Scenario("a", WaitTwoMinutesForNothing), Scenario("b", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));    // starts a, which waits on Until (deadline 121)

            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(30)));
            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(70)));
            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(120)));
            HarnessAction action = run.Tick(OnMap(125));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("tainted:a", run.Reason);
            RunResult result = ToResult(run, 125);
            Assert.Equal(ScenarioStatus.Timeout, result.Scenarios.Single(s => s.Id == "a").Status);
            Assert.Equal(ScenarioStatus.Skipped, result.Scenarios.Single(s => s.Id == "b").Status);
        }

        [Fact]
        public void ScenarioRun_ScenarioLimitBeyondStall_TimesOutViaScenarioLimitNotStall()
        {
            HarnessRun run = NewScenarioRun(1, 60, Scenario("a", WaitForever));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));

            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(150)));
            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(300)));
            HarnessAction action = run.Tick(OnMap(310));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("tainted:a", run.Reason);
            Assert.Equal(ScenarioStatus.Timeout, ToResult(run, 310).Scenarios.Single().Status);
        }

        [Fact]
        public void ScenarioRun_BudgetStillAbortsAWaitingScenario()
        {
            HarnessRun run = NewScenarioRun(1, 2, Scenario("a", WaitForever));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));

            HarnessAction action = run.Tick(OnMap(121));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("timeout:Running", run.Reason);
        }

        [Fact]
        public void ScenarioRun_BudgetStillAborts()
        {
            HarnessRun run = NewScenarioRun(1, 2, Scenario("a", TickForever), Scenario("b", PassImmediately));
            DriveToRunning(run, 0);

            HarnessAction action = HarnessAction.None;
            for (int t = 10; t <= 120 && run.Phase == HarnessPhase.Running; t += 10)
            {
                action = run.Tick(OnMap(t));
            }

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("timeout:Running", run.Reason);
            RunResult result = ToResult(run, 120);
            Assert.Equal(ScenarioStatus.Timeout, result.Scenarios.Single(s => s.Id == "a").Status);
            Assert.Equal(ScenarioStatus.Skipped, result.Scenarios.Single(s => s.Id == "b").Status);
        }

        [Fact]
        public void ScenarioRun_AbortBeforeRunning_SkipsAllScenarios()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately), Scenario("b", PassImmediately));

            run.Tick(Obs(300));   // still Armed: stall after 5 min

            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("stall:Armed", run.Reason);
            RunResult result = ToResult(run, 300);
            Assert.Equal(2, result.Scenarios.Count);
            Assert.All(result.Scenarios, s => Assert.Equal(ScenarioStatus.Skipped, s.Status));
            Assert.Equal(2, run.ScenariosFinished);
        }

        // ------------------------------------------------- implementer decisions

        [Fact]
        public void Constructor_NullLog_Throws()
        {
            Assert.Throws<ArgumentNullException>(() => new ScenarioRunner(new IScenario[0], null));
        }

        [Fact]
        public void Constructor_NullScenarioEntry_Throws()
        {
            Assert.ThrowsAny<ArgumentException>(() => new ScenarioRunner(new IScenario[] { null }, _log.Add));
        }

        [Fact]
        public void Resolve_IdsAreComparedOrdinal()
        {
            ScenarioResolution resolution = ScenarioRunner.Resolve(new[] { "A" }, new IScenario[] { Scenario("a", PassImmediately) });

            Assert.False(resolution.IsValid);
            Assert.Contains("'A'", resolution.Error);
        }

        [Fact]
        public void Resolve_IdRequestedTwice_IsErrorNamingTheId()
        {
            ScenarioResolution resolution = ScenarioRunner.Resolve(new[] { "a", "a" }, new IScenario[] { Scenario("a", PassImmediately) });

            Assert.False(resolution.IsValid);
            Assert.Contains("'a'", resolution.Error);
        }

        [Fact]
        public void NullStep_IsErrorAndTaintsTheRest()
        {
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                yield return null;
            }

            ScenarioRunner runner = NewRunner(Scenario("a", Body), Scenario("b", PassImmediately));

            runner.Tick(0, 0);

            Assert.True(runner.IsTainted);
            Assert.Equal(ScenarioStatus.Error, ResultOf(runner, "a").Status);
            Assert.Equal(ScenarioStatus.Skipped, ResultOf(runner, "b").Status);
        }

        [Fact]
        public void Abort_DisposesTheIterator_SoFinallyBlocksRun()
        {
            bool cleanedUp = false;
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                try
                {
                    yield return ScenarioStep.Until(() => false, 100, "never");
                }
                finally
                {
                    cleanedUp = true;
                }
            }

            ScenarioRunner runner = NewRunner(Scenario("a", Body));
            runner.Tick(0, 0);

            runner.Abort(1);

            Assert.True(cleanedUp);
        }

        [Fact]
        public void SoakConstructor_ConfigWithScenarios_Throws()
        {
            RunConfig config = RunConfig.Parse(BaseCfg + "scenarios=a").Config;

            Assert.ThrowsAny<ArgumentException>(() => new HarnessRun(config, 0));
        }

        [Fact]
        public void ScenarioConstructor_ConfigWithoutScenariosOrNullRunner_Throws()
        {
            RunConfig soak = RunConfig.Parse(BaseCfg).Config;
            RunConfig withScenarios = RunConfig.Parse(BaseCfg + "scenarios=a").Config;
            var runner = new ScenarioRunner(new IScenario[] { Scenario("a", PassImmediately) }, _log.Add);

            Assert.ThrowsAny<ArgumentException>(() => new HarnessRun(soak, 0, runner));
            Assert.Throws<ArgumentNullException>(() => new HarnessRun(withScenarios, 0, null));
        }

        private static RunResult ToUnhandled(HarnessRun run, double t)
        {
            return run.ToUnhandledResult(t, new ModuleEntry[0], ExceptionSummary.Empty);
        }

        [Fact]
        public void ScenarioRun_Unhandled_CurrentIsErrorRestSkipped_RunUnchanged()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately), Scenario("b", WaitForever), Scenario("c", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));   // a passes
            run.Tick(OnMap(2));   // b starts and waits

            RunResult result = ToUnhandled(run, 9);

            Assert.Equal(RunStatus.Aborted, result.Status);
            Assert.Equal("unhandled:Running", result.Reason);
            Assert.Equal(new[] { "a", "b", "c" }, result.Scenarios.Select(s => s.Id));
            Assert.Equal(ScenarioStatus.Passed, result.Scenarios[0].Status);
            Assert.Equal(ScenarioStatus.Error, result.Scenarios[1].Status);
            Assert.Equal(7, result.Scenarios[1].Seconds);
            Assert.Equal(ScenarioStatus.Skipped, result.Scenarios[2].Status);
            Assert.Null(result.Scenarios[2].Seconds);
            Assert.Equal(new[] { "a" }, result.Checks.Select(c => c.Scenario));

            Assert.Equal(RunStatus.Running, run.Status);
            Assert.Equal(1, run.ScenariosFinished);
        }

        [Fact]
        public void ScenarioRun_UnhandledBeforeRunning_SkipsAll()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately), Scenario("b", PassImmediately));
            run.Tick(Obs(1, menu: true));

            RunResult result = ToUnhandled(run, 2);

            Assert.Equal("unhandled:StartRequested", result.Reason);
            Assert.Equal(2, result.Scenarios.Count);
            Assert.All(result.Scenarios, s => Assert.Equal(ScenarioStatus.Skipped, s.Status));
        }

        [Fact]
        public void ScenarioRun_UnhandledAfterCompletion_KeepsTheFinalResult()
        {
            HarnessRun run = NewScenarioRun(Scenario("a", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));
            Assert.Equal(RunStatus.Completed, run.Status);

            RunResult result = ToUnhandled(run, 50);

            Assert.Equal(RunStatus.Completed, result.Status);
            Assert.Equal(1, result.RealSeconds);
            Assert.Equal(ScenarioStatus.Passed, Assert.Single(result.Scenarios).Status);
        }
    }
}
