using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    /// <summary>
    /// Health bracket (S6 #18, F-S6-1): run.cfg <c>health=</c>, the flow health@0 -> soak -> health@N -> Ending,
    /// the result ids <c>&lt;id&gt;@0</c> / <c>&lt;id&gt;@&lt;N&gt;</c> and <see cref="IScenarioContext.Day"/>.
    /// </summary>
    public class HealthBracketTests
    {
        // ---------------------------------------------------------------- helpers

        private const string BaseCfg = "seed=1\ndays=3\nmode=WarSails\n";

        private readonly List<string> _log = new List<string>();

        /// <summary>Fake scenario whose body is an iterator method; records how often Run is called and with which day.</summary>
        private sealed class FakeScenario : IScenario
        {
            private readonly Func<IScenarioContext, IEnumerable<ScenarioStep>> _body;

            public FakeScenario(string id, Func<IScenarioContext, IEnumerable<ScenarioStep>> body)
            {
                Id = id;
                _body = body;
            }

            public string Id { get; }

            public List<int> RunDays { get; } = new List<int>();

            public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
            {
                RunDays.Add(ctx.Day);
                return _body(ctx);
            }
        }

        private static FakeScenario Scenario(string id, Func<IScenarioContext, IEnumerable<ScenarioStep>> body)
        {
            return new FakeScenario(id, body);
        }

        private static IEnumerable<ScenarioStep> PassImmediately(IScenarioContext ctx)
        {
            ctx.Check("ok", true, "true", "true");
            yield break;
        }

        private static IEnumerable<ScenarioStep> WaitOneTickThenPass(IScenarioContext ctx)
        {
            yield return ScenarioStep.Ticks(1);
            ctx.Check("ok", true, "true", "true");
        }

        private static IEnumerable<ScenarioStep> WaitForever(IScenarioContext ctx)
        {
            yield return ScenarioStep.Until(() => false, 10000, "never");
            ctx.Check("unreachable", true, "x", "x");
        }

        private static IEnumerable<ScenarioStep> ThrowImmediately(IScenarioContext ctx)
        {
            throw new InvalidOperationException("boom in health");
#pragma warning disable CS0162 // makes this method an iterator
            yield break;
#pragma warning restore CS0162
        }

        private static IEnumerable<ScenarioStep> CheckThenWaitADay(IScenarioContext ctx)
        {
            ctx.Check("before", true, "x", "x");
            yield return ScenarioStep.Days(1);
            ctx.Check("unreachable", true, "x", "x");
        }

        private static RunConfig Config(string text)
        {
            RunConfigResult result = RunConfig.Parse(text);
            Assert.Equal(RunConfigStatus.Valid, result.Status);
            return result.Config;
        }

        private HarnessRun NewHealthRun(int days, double stallMinutes, double budgetMinutes, params IScenario[] health)
        {
            string text = string.Format(CultureInfo.InvariantCulture,
                "seed=3\ndays={0}\nmode=NoDlc\nstallMinutes={1}\nbudgetMinutes={2}\nhealth={3}",
                days, stallMinutes, budgetMinutes, string.Join(",", health.Select(s => s.Id)));
            RunConfig config = Config(text);
            return new HarnessRun(config, 0,
                ScenarioRunner.ForHealth(health, 0, _log.Add),
                ScenarioRunner.ForHealth(health, config.Days, _log.Add));
        }

        private HarnessRun NewHealthRun(params IScenario[] health)
        {
            return NewHealthRun(3, 5, 60, health);
        }

        private static HarnessObservation Obs(double t, bool menu = false, bool map = false, bool inGame = false,
            bool ended = false, int days = 0)
        {
            return new HarnessObservation
            {
                RealSeconds = t,
                MainMenuActive = menu,
                MapActive = map,
                InGame = inGame,
                GameEnded = ended,
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

        private static RunResult ToResult(HarnessRun run, double t)
        {
            return run.ToResult(t, new ModuleEntry[0], ExceptionSummary.Empty);
        }

        private static RunResult ToUnhandled(HarnessRun run, double t)
        {
            return run.ToUnhandledResult(t, new ModuleEntry[0], ExceptionSummary.Empty);
        }

        private static string[] Ids(RunResult result)
        {
            return result.Scenarios.Select(s => s.Id).ToArray();
        }

        // ------------------------------------------------- run.cfg health key

        [Fact]
        public void Parse_WithoutHealthKey_HasNoHealth()
        {
            Assert.Empty(Config(BaseCfg).Health);
        }

        [Fact]
        public void Parse_HealthKey_IsTrimmedCaseInsensitiveListInOrder()
        {
            RunConfig config = Config(BaseCfg + "HEALTH= smithing.health , autotrader.health ");

            Assert.Equal(new[] { "smithing.health", "autotrader.health" }, config.Health);
            Assert.Empty(config.Scenarios);
        }

        [Theory]
        [InlineData("health=")]
        [InlineData("health= , ")]
        [InlineData("health=a,b,a")]
        [InlineData("health=a\nhealth=b")]
        [InlineData("health=a\u0000")]
        public void Parse_BadHealthValue_IsInvalidAndNamesTheKey(string line)
        {
            RunConfigResult result = RunConfig.Parse(BaseCfg + line);

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains("health", result.Error);
        }

        [Fact]
        public void Parse_HealthWithScenarios_IsInvalid()
        {
            RunConfigResult result = RunConfig.Parse(BaseCfg + "health=a\nscenarios=b");

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains("health", result.Error);
            Assert.Contains("scenarios", result.Error);
        }

        // ------------------------------------------------- result ids

        [Fact]
        public void HealthId_AppendsAtAndTheDay()
        {
            Assert.Equal("mod.health@0", ScenarioRunner.HealthId("mod.health", 0));
            Assert.Equal("mod.health@30", ScenarioRunner.HealthId("mod.health", 30));
        }

        [Fact]
        public void ResultIds_PerKindOfRun()
        {
            Assert.Equal(new[] { "soak" }, HarnessRun.ResultIds(Config(BaseCfg)));
            Assert.Equal(new[] { "b", "a" }, HarnessRun.ResultIds(Config(BaseCfg + "scenarios=b,a")));
            Assert.Equal(new[] { "x@0", "y@0", "soak", "x@3", "y@3" }, HarnessRun.ResultIds(Config(BaseCfg + "health=x,y")));
        }

        // ------------------------------------------------- ScenarioRunner.ForHealth

        [Fact]
        public void ForHealth_NegativeDay_Throws()
        {
            Assert.ThrowsAny<ArgumentException>(() => ScenarioRunner.ForHealth(new IScenario[0], -1, _log.Add));
        }

        [Fact]
        public void ForHealth_ResultsChecksLogAndTaintUseTheSuffixedId()
        {
            ScenarioRunner runner = ScenarioRunner.ForHealth(
                new IScenario[] { Scenario("a", PassImmediately), Scenario("b", ThrowImmediately), Scenario("c", PassImmediately) },
                30, _log.Add);

            runner.Tick(1, 30);
            runner.Tick(2, 30);

            Assert.Equal(new[] { "a@30", "b@30", "c@30" }, runner.Results.Select(r => r.Id));
            Assert.Equal(new[] { ScenarioStatus.Passed, ScenarioStatus.Error, ScenarioStatus.Skipped }, runner.Results.Select(r => r.Status));
            Assert.Equal("a@30", Assert.Single(runner.Checks).Scenario);
            Assert.True(runner.IsTainted);
            Assert.Contains(_log, l => l.StartsWith("scenario a@30: started", StringComparison.Ordinal));
        }

        [Fact]
        public void ForHealth_DaysStep_IsErrorWithoutTaint_NextScenarioRuns()
        {
            ScenarioRunner runner = ScenarioRunner.ForHealth(
                new IScenario[] { Scenario("a", CheckThenWaitADay), Scenario("b", PassImmediately) }, 0, _log.Add);

            runner.Tick(1, 0);

            Assert.Equal(ScenarioStatus.Error, runner.Results[0].Status);
            Assert.False(runner.IsTainted);
            Assert.False(runner.TimeShouldRun);
            Assert.Contains(_log, l => l.Contains("a@0") && l.Contains("Days"));

            runner.Tick(2, 0);

            Assert.Equal(ScenarioStatus.Passed, runner.Results[1].Status);
            Assert.True(runner.IsFinished);
        }

        [Fact]
        public void PlainRunner_DaysStepStillAllowed()
        {
            var runner = new ScenarioRunner(new IScenario[] { Scenario("a", CheckThenWaitADay) }, _log.Add);

            runner.Tick(1, 0);

            Assert.True(runner.TimeShouldRun);
            Assert.Empty(runner.Results);
        }

        [Fact]
        public void ContextDay_IsTheDayCountOfTheCurrentTick()
        {
            var seen = new List<int>();
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                seen.Add(ctx.Day);
                yield return ScenarioStep.Days(2);
                seen.Add(ctx.Day);
                ctx.Check("ok", true, "x", "x");
            }

            var runner = new ScenarioRunner(new IScenario[] { Scenario("a", Body) }, _log.Add);
            runner.Tick(1, 4);
            runner.Tick(2, 5);
            runner.Tick(3, 6);

            Assert.Equal(new[] { 4, 6 }, seen);
            Assert.Equal(ScenarioStatus.Passed, Assert.Single(runner.Results).Status);
        }

        [Fact]
        public void ContextDaysRequested_IsTheValueGivenToTheRunnerAndDefaultsToZero()
        {
            var seen = new List<int>();
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                seen.Add(ctx.DaysRequested);
                ctx.Check("ok", true, "x", "x");
                yield break;
            }

            var requested = new ScenarioRunner(new IScenario[] { Scenario("a", Body) }, _log.Add, 7);
            requested.Tick(1, 0);
            var unknown = new ScenarioRunner(new IScenario[] { Scenario("b", Body) }, _log.Add);
            unknown.Tick(1, 0);

            Assert.Equal(new[] { 7, 0 }, seen);
        }

        [Fact]
        public void ContextDaysRequested_IsTheSameInBothHealthBrackets()
        {
            var seen = new List<int>();
            IEnumerable<ScenarioStep> Body(IScenarioContext ctx)
            {
                seen.Add(ctx.DaysRequested);
                ctx.Check("ok", true, "x", "x");
                yield break;
            }

            var scenarios = new IScenario[] { Scenario("a", Body) };
            ScenarioRunner.ForHealth(scenarios, 0, _log.Add, 5).Tick(1, 0);
            ScenarioRunner.ForHealth(scenarios, 5, _log.Add, 5).Tick(1, 5);

            Assert.Equal(new[] { 5, 5 }, seen);
        }

        [Fact]
        public void Constructor_NegativeDaysRequested_Throws()
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => new ScenarioRunner(new IScenario[0], _log.Add, -1));
        }

        // ------------------------------------------------- HarnessRun construction

        [Fact]
        public void Constructors_RejectMismatchedHealthConfigAndRunners()
        {
            RunConfig soak = Config(BaseCfg);
            RunConfig health = Config(BaseCfg + "health=a");
            IScenario[] scenarios = { Scenario("a", PassImmediately) };
            ScenarioRunner atStart = ScenarioRunner.ForHealth(scenarios, 0, _log.Add);
            ScenarioRunner atEnd = ScenarioRunner.ForHealth(scenarios, 3, _log.Add);

            Assert.ThrowsAny<ArgumentException>(() => new HarnessRun(health, 0));
            Assert.ThrowsAny<ArgumentException>(() => new HarnessRun(health, 0, atStart));
            Assert.ThrowsAny<ArgumentException>(() => new HarnessRun(soak, 0, atStart, atEnd));
            Assert.Throws<ArgumentNullException>(() => new HarnessRun(health, 0, null, atEnd));
            Assert.Throws<ArgumentNullException>(() => new HarnessRun(health, 0, atStart, null));
        }

        // ------------------------------------------------- flow

        [Fact]
        public void Flow_HealthAtZero_Soak_HealthAtN_Completes()
        {
            FakeScenario a = Scenario("a", PassImmediately);
            FakeScenario b = Scenario("b", WaitOneTickThenPass);
            HarnessRun run = NewHealthRun(a, b);
            DriveToRunning(run, 0);

            // health@0: time stays stopped until both scenarios ended.
            Assert.False(run.TimeShouldRun);
            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(1)));   // a@0 passes
            Assert.False(run.TimeShouldRun);
            run.Tick(OnMap(2));                                            // b@0 starts, waits a tick
            Assert.False(run.TimeShouldRun);
            run.Tick(OnMap(3));                                            // b@0 passes -> soak starts
            Assert.True(run.TimeShouldRun);
            Assert.Equal(2, run.ScenariosFinished);

            // Soak: days count up with time running.
            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(10, days: 2)));
            Assert.True(run.TimeShouldRun);
            Assert.Equal(HarnessAction.KeepRunning, run.Tick(OnMap(20, days: 3)));   // soak done -> time stops
            Assert.False(run.TimeShouldRun);
            Assert.Equal(3, run.ScenariosFinished);
            Assert.Single(a.RunDays);

            // health@N on the following ticks, then Ending.
            run.Tick(OnMap(21, days: 3));                                  // a@3 passes
            run.Tick(OnMap(22, days: 3));                                  // b@3 starts
            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(OnMap(23, days: 3)));   // b@3 passes

            Assert.Equal(HarnessPhase.Ending, run.Phase);
            Assert.Equal(RunStatus.Completed, run.Status);
            Assert.Null(run.Reason);
            Assert.Equal(new[] { 0, 3 }, a.RunDays);
            Assert.Equal(new[] { 0, 3 }, b.RunDays);

            RunResult result = ToResult(run, 23);
            Assert.Equal(new[] { "a@0", "b@0", "soak", "a@3", "b@3" }, Ids(result));
            Assert.All(result.Scenarios, s => Assert.Equal(ScenarioStatus.Passed, s.Status));
            Assert.Equal(17, result.Scenarios[2].Seconds);   // soak segment 3 s .. 20 s
            Assert.Equal(new[] { "a@0", "b@0", "soak", "a@3", "b@3" }, result.Checks.Select(c => c.Scenario));
            CheckResult soakCheck = result.Checks[2];
            Assert.Equal("daysReached", soakCheck.Name);
            Assert.Equal(">= 3", soakCheck.Expected);
            Assert.True(soakCheck.Passed);
            Assert.Equal(3, result.DaysReached);
        }

        [Fact]
        public void InterimResult_ListsOnlyEndedSegments()
        {
            HarnessRun run = NewHealthRun(Scenario("a", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));   // a@0 passes, soak running

            RunResult result = ToResult(run, 5);

            Assert.Equal(RunStatus.Running, result.Status);
            Assert.Equal(new[] { "a@0" }, Ids(result));
            Assert.Equal(new[] { "a@0" }, result.Checks.Select(c => c.Scenario));
        }

        [Fact]
        public void TaintAtZero_SkipsTheRest_NoSoak()
        {
            FakeScenario a = Scenario("a", ThrowImmediately);
            FakeScenario b = Scenario("b", PassImmediately);
            HarnessRun run = NewHealthRun(a, b);
            DriveToRunning(run, 0);

            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(OnMap(1)));

            Assert.False(run.TimeShouldRun);
            Assert.Equal(HarnessPhase.Ending, run.Phase);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("tainted:a@0", run.Reason);
            Assert.Empty(b.RunDays);

            RunResult result = ToResult(run, 1);
            Assert.Equal(new[] { "a@0", "b@0", "soak", "a@3", "b@3" }, Ids(result));
            Assert.Equal(
                new[] { ScenarioStatus.Error, ScenarioStatus.Skipped, ScenarioStatus.Skipped, ScenarioStatus.Skipped, ScenarioStatus.Skipped },
                result.Scenarios.Select(s => s.Status));
            Assert.Null(result.Scenarios[2].Seconds);
            Assert.Empty(result.Checks);
            Assert.Null(result.RunningDaysPerRealMinute);
        }

        [Fact]
        public void TaintAtN_KeepsThePassedSoak()
        {
            int calls = 0;
            IEnumerable<ScenarioStep> PassThenThrow(IScenarioContext ctx)
            {
                if (calls++ > 0)
                {
                    throw new InvalidOperationException("broken at day N");
                }

                ctx.Check("ok", true, "x", "x");
                yield break;
            }

            HarnessRun run = NewHealthRun(Scenario("a", PassThenThrow));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));            // a@0 passes
            run.Tick(OnMap(9, days: 3));   // soak done

            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(OnMap(10, days: 3)));

            Assert.Equal("tainted:a@3", run.Reason);
            RunResult result = ToResult(run, 10);
            Assert.Equal(new[] { ScenarioStatus.Passed, ScenarioStatus.Passed, ScenarioStatus.Error }, result.Scenarios.Select(s => s.Status));
        }

        [Fact]
        public void DaysStepInHealth_IsErrorAndTheSoakStillRuns()
        {
            HarnessRun run = NewHealthRun(Scenario("a", CheckThenWaitADay));
            DriveToRunning(run, 0);

            run.Tick(OnMap(1));

            Assert.Equal(RunStatus.Running, run.Status);
            Assert.True(run.TimeShouldRun);
            Assert.Equal(ScenarioStatus.Error, ToResult(run, 1).Scenarios[0].Status);
        }

        [Fact]
        public void StallDuringSoak_SoakTimeout_HealthAtNSkipped()
        {
            HarnessRun run = NewHealthRun(3, 1, 60, Scenario("a", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));                                  // a@0 passes, soak starts at 1 s

            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(OnMap(70, days: 0)));

            Assert.Equal("stall:Running", run.Reason);
            RunResult result = ToResult(run, 70);
            Assert.Equal(new[] { "a@0", "soak", "a@3" }, Ids(result));
            Assert.Equal(new[] { ScenarioStatus.Passed, ScenarioStatus.Timeout, ScenarioStatus.Skipped }, result.Scenarios.Select(s => s.Status));
            Assert.Equal(69, result.Scenarios[1].Seconds);
            Assert.False(result.Checks.Single(c => c.Scenario == "soak").Passed);
        }

        [Fact]
        public void BudgetDuringHealthAtN_SoakStaysPassed_CurrentTimeout_RestSkipped()
        {
            // A waits forever only at day N; a waiting health scenario counts as progress, so the budget ends it.
            IEnumerable<ScenarioStep> PassAtZeroWaitAtN(IScenarioContext ctx)
            {
                if (ctx.Day > 0)
                {
                    yield return ScenarioStep.Until(() => false, 10000, "never");
                }

                ctx.Check("ok", true, "x", "x");
            }

            HarnessRun run = NewHealthRun(3, 1, 3, Scenario("a", PassAtZeroWaitAtN), Scenario("b", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));                                  // a@0 passes
            run.Tick(OnMap(2));                                  // b@0 passes, soak starts at 2 s
            run.Tick(OnMap(10, days: 3));                        // soak done at 10 s
            run.Tick(OnMap(11, days: 3));                        // a@3 starts and waits

            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(OnMap(180, days: 3)));

            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("timeout:Running", run.Reason);
            RunResult result = ToResult(run, 180);
            Assert.Equal(new[] { "a@0", "b@0", "soak", "a@3", "b@3" }, Ids(result));
            Assert.Equal(
                new[] { ScenarioStatus.Passed, ScenarioStatus.Passed, ScenarioStatus.Passed, ScenarioStatus.Timeout, ScenarioStatus.Skipped },
                result.Scenarios.Select(s => s.Status));
            Assert.Equal(8, result.Scenarios[2].Seconds);
            Assert.True(result.Checks.Single(c => c.Scenario == "soak").Passed);
            Assert.DoesNotContain(result.Checks, c => c.Scenario == "b@3");
            Assert.Equal(22.5, result.RunningDaysPerRealMinute);   // soak segment only: 3 days in 8 s
        }

        [Fact]
        public void StallBeforeRunning_SkipsAll_NoSoakSecondsNoCheck()
        {
            FakeScenario a = Scenario("a", PassImmediately);
            HarnessRun run = NewHealthRun(3, 1, 60, a);
            run.Tick(Obs(0, menu: true));
            run.Tick(new HarnessObservation { RealSeconds = 1, InGame = true, CharacterCreationActive = true });
            Assert.Equal(HarnessPhase.CharacterCreation, run.Phase);

            Assert.Equal(HarnessAction.RequestEndGame,
                run.Tick(new HarnessObservation { RealSeconds = 70, InGame = true, CharacterCreationActive = true }));

            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("stall:CharacterCreation", run.Reason);
            Assert.Empty(a.RunDays);
            RunResult result = ToResult(run, 70);
            Assert.Equal(new[] { "a@0", "soak", "a@3" }, Ids(result));
            Assert.All(result.Scenarios, s => Assert.Equal(ScenarioStatus.Skipped, s.Status));
            Assert.Null(result.Scenarios[1].Seconds);
            Assert.Empty(result.Checks);
            Assert.Null(result.RunningDaysPerRealMinute);
        }

        [Fact]
        public void RunningHealthScenario_CountsAsProgress_BudgetStillApplies()
        {
            HarnessRun run = NewHealthRun(3, 1, 3, Scenario("a", WaitForever));
            DriveToRunning(run, 0);

            run.Tick(OnMap(1));     // a@0 starts and waits
            run.Tick(OnMap(150));   // past the 1-minute stall limit

            Assert.Equal(RunStatus.Running, run.Status);

            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(OnMap(180)));
            Assert.Equal("timeout:Running", run.Reason);
            RunResult result = ToResult(run, 180);
            Assert.Equal(new[] { ScenarioStatus.Timeout, ScenarioStatus.Skipped, ScenarioStatus.Skipped }, result.Scenarios.Select(s => s.Status));
        }

        [Fact]
        public void RunningRate_CoversOnlyTheSoakSegment()
        {
            HarnessRun run = NewHealthRun(3, 5, 60, Scenario("a", WaitOneTickThenPass));
            DriveToRunning(run, 0);
            run.Tick(OnMap(30));             // a@0 starts
            run.Tick(OnMap(60));             // a@0 passes, soak starts at 60 s
            run.Tick(OnMap(120, days: 3));   // soak done at 120 s: 3 days in 1 min
            run.Tick(OnMap(150, days: 3));   // a@3 starts
            run.Tick(OnMap(200, days: 3));   // a@3 passes

            Assert.Equal(RunStatus.Completed, run.Status);
            Assert.Equal(3.0, ToResult(run, 200).RunningDaysPerRealMinute);
        }

        [Fact]
        public void Unhandled_DuringSoak_SoakFailed_HealthAtNSkipped_RunUnchanged()
        {
            HarnessRun run = NewHealthRun(Scenario("a", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));            // soak starts at 1 s
            run.Tick(OnMap(5, days: 1));

            RunResult result = ToUnhandled(run, 9);

            Assert.Equal("unhandled:Running", result.Reason);
            Assert.Equal(new[] { "a@0", "soak", "a@3" }, Ids(result));
            Assert.Equal(new[] { ScenarioStatus.Passed, ScenarioStatus.Failed, ScenarioStatus.Skipped }, result.Scenarios.Select(s => s.Status));
            Assert.Equal(8, result.Scenarios[1].Seconds);
            Assert.Equal(RunStatus.Running, run.Status);
            Assert.Equal(1, run.ScenariosFinished);
        }

        [Fact]
        public void Unhandled_DuringHealthAtZero_CurrentErrorRestSkipped()
        {
            HarnessRun run = NewHealthRun(Scenario("a", WaitForever), Scenario("b", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));   // a@0 waits

            RunResult result = ToUnhandled(run, 4);

            Assert.Equal(new[] { "a@0", "b@0", "soak", "a@3", "b@3" }, Ids(result));
            Assert.Equal(
                new[] { ScenarioStatus.Error, ScenarioStatus.Skipped, ScenarioStatus.Skipped, ScenarioStatus.Skipped, ScenarioStatus.Skipped },
                result.Scenarios.Select(s => s.Status));
            Assert.Empty(result.Checks);
        }

        [Fact]
        public void Unhandled_BeforeRunning_SkipsAll()
        {
            HarnessRun run = NewHealthRun(Scenario("a", PassImmediately));
            run.Tick(Obs(1, menu: true));

            RunResult result = ToUnhandled(run, 2);

            Assert.Equal("unhandled:StartRequested", result.Reason);
            Assert.Equal(new[] { "a@0", "soak", "a@3" }, Ids(result));
            Assert.All(result.Scenarios, s => Assert.Equal(ScenarioStatus.Skipped, s.Status));
        }

        [Fact]
        public void EndStall_AfterCompletion_KeepsTheScenarioResults()
        {
            HarnessRun run = NewHealthRun(3, 1, 60, Scenario("a", PassImmediately));
            DriveToRunning(run, 0);
            run.Tick(OnMap(1));
            run.Tick(OnMap(2, days: 3));
            run.Tick(OnMap(3, days: 3));
            Assert.Equal(RunStatus.Completed, run.Status);

            Assert.Equal(HarnessAction.QuitProcess, run.Tick(OnMap(70, days: 3)));

            Assert.Equal("end-stall", run.Reason);
            Assert.All(ToResult(run, 70).Scenarios, s => Assert.Equal(ScenarioStatus.Passed, s.Status));
        }
    }
}
