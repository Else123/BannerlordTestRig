using System;
using System.Globalization;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class HarnessRunTests
    {
        // ---------------------------------------------------------------- helpers

        private const string MinimalCfg = "seed=1\ndays=1\nmode=WarSails";

        private static RunConfig ValidConfig(string text)
        {
            RunConfigResult result = RunConfig.Parse(text);
            Assert.Equal(RunConfigStatus.Valid, result.Status);
            return result.Config;
        }

        private static HarnessRun NewRun(int days = 3, double stallMinutes = 5, double budgetMinutes = 60,
            double start = 0, int seed = 7, string mode = "NoDlc")
        {
            string text = string.Format(CultureInfo.InvariantCulture,
                "seed={0}\ndays={1}\nmode={2}\nstallMinutes={3}\nbudgetMinutes={4}",
                seed, days, mode, stallMinutes, budgetMinutes);
            return new HarnessRun(ValidConfig(text), start);
        }

        private static HarnessObservation Obs(double t, bool menu = false, bool creation = false,
            bool map = false, bool inGame = false, bool ended = false, int days = 0,
            bool playerInMapEvent = false)
        {
            return new HarnessObservation
            {
                RealSeconds = t,
                MainMenuActive = menu,
                CharacterCreationActive = creation,
                MapActive = map,
                InGame = inGame,
                GameEnded = ended,
                DaysElapsed = days,
                PlayerInMapEvent = playerInMapEvent,
            };
        }

        // Armed -> StartRequested -> Map -> Running, all at real time t.
        private static void DriveToRunning(HarnessRun run, double t)
        {
            run.Tick(Obs(t, menu: true));
            run.Tick(Obs(t, map: true, inGame: true));
            run.Tick(Obs(t, map: true, inGame: true));
            Assert.Equal(HarnessPhase.Running, run.Phase);
        }

        private static void WithCulture(string name, Action action)
        {
            CultureInfo previous = CultureInfo.CurrentCulture;
            try
            {
                CultureInfo.CurrentCulture = new CultureInfo(name);
                action();
            }
            finally
            {
                CultureInfo.CurrentCulture = previous;
            }
        }

        // ------------------------------------------------- AC-U1: config parsing

        [Fact]
        public void Parse_ValidFile_ReturnsAllValues()
        {
            RunConfigResult result = RunConfig.Parse("seed=42\ndays=10\nmode=WarSails\nstallMinutes=2.5\nbudgetMinutes=30");

            Assert.Equal(RunConfigStatus.Valid, result.Status);
            Assert.Null(result.Error);
            Assert.Equal(42, result.Config.Seed);
            Assert.Equal(10, result.Config.Days);
            Assert.Equal(HarnessMode.WarSails, result.Config.Mode);
            Assert.Equal(2.5, result.Config.StallMinutes);
            Assert.Equal(30.0, result.Config.BudgetMinutes);
        }

        [Fact]
        public void Parse_OptionalKeysMissing_UsesDefaults()
        {
            RunConfig config = ValidConfig(MinimalCfg);

            Assert.Equal(5.0, config.StallMinutes);
            Assert.Equal(60.0, config.BudgetMinutes);
        }

        [Fact]
        public void Parse_NullText_IsInertWithoutConfigOrError()
        {
            RunConfigResult result = RunConfig.Parse(null);

            Assert.Equal(RunConfigStatus.Inert, result.Status);
            Assert.Null(result.Config);
            Assert.Null(result.Error);
        }

        [Theory]
        [InlineData("FeatureOff", HarnessMode.FeatureOff)]
        [InlineData("nodlc", HarnessMode.NoDlc)]
        [InlineData("WARSAILS", HarnessMode.WarSails)]
        public void Parse_ModeIsCaseInsensitive(string value, HarnessMode expected)
        {
            Assert.Equal(expected, ValidConfig("seed=1\ndays=1\nmode=" + value).Mode);
        }

        [Fact]
        public void Parse_KeysAreCaseInsensitive()
        {
            RunConfig config = ValidConfig("SEED=5\nDays=2\nMODE=NoDlc\nSTALLMINUTES=1\nbudgetminutes=9");

            Assert.Equal(5, config.Seed);
            Assert.Equal(2, config.Days);
            Assert.Equal(1.0, config.StallMinutes);
            Assert.Equal(9.0, config.BudgetMinutes);
        }

        [Fact]
        public void Parse_TrimsWhitespaceAroundKeyAndValue()
        {
            RunConfig config = ValidConfig("  seed  =  9  \n\tdays\t=\t4\t\n mode = NoDlc ");

            Assert.Equal(9, config.Seed);
            Assert.Equal(4, config.Days);
            Assert.Equal(HarnessMode.NoDlc, config.Mode);
        }

        [Fact]
        public void Parse_IgnoresBlankLinesAndComments()
        {
            RunConfig config = ValidConfig("# soak run\n\nseed=3\n   \n# days=999\ndays=2\nmode=FeatureOff\n");

            Assert.Equal(3, config.Seed);
            Assert.Equal(2, config.Days);
        }

        [Fact]
        public void Parse_AcceptsWindowsLineEndings()
        {
            RunConfig config = ValidConfig("seed=3\r\ndays=2\r\nmode=NoDlc\r\nstallMinutes=7\r\n");

            Assert.Equal(3, config.Seed);
            Assert.Equal(2, config.Days);
            Assert.Equal(HarnessMode.NoDlc, config.Mode);
            Assert.Equal(7.0, config.StallMinutes);
        }

        [Theory]
        [InlineData("seed=0\ndays=1\nmode=NoDlc", 0, 1)]
        [InlineData("seed=1\ndays=365\nmode=NoDlc", 1, 365)]
        public void Parse_RangeBoundariesAreAccepted(string text, int seed, int days)
        {
            RunConfig config = ValidConfig(text);

            Assert.Equal(seed, config.Seed);
            Assert.Equal(days, config.Days);
        }

        [Fact]
        public void Parse_FractionalMinutes_UseInvariantCultureUnderGermanCulture()
        {
            WithCulture("de-DE", () =>
            {
                RunConfig config = ValidConfig("seed=1\ndays=1\nmode=NoDlc\nstallMinutes=2.5\nbudgetMinutes=0.5");

                Assert.Equal(2.5, config.StallMinutes);
                Assert.Equal(0.5, config.BudgetMinutes);
            });
        }

        [Theory]
        [InlineData("seed=-1\ndays=1\nmode=NoDlc", "seed")]
        [InlineData("seed=abc\ndays=1\nmode=NoDlc", "seed")]
        [InlineData("seed=1.5\ndays=1\nmode=NoDlc", "seed")]
        [InlineData("seed=\ndays=1\nmode=NoDlc", "seed")]
        [InlineData("seed=99999999999\ndays=1\nmode=NoDlc", "seed")]
        [InlineData("seed=1\ndays=0\nmode=NoDlc", "days")]
        [InlineData("seed=1\ndays=366\nmode=NoDlc", "days")]
        [InlineData("seed=1\ndays=-3\nmode=NoDlc", "days")]
        [InlineData("seed=1\ndays=x\nmode=NoDlc", "days")]
        [InlineData("seed=1\ndays=1\nmode=Bogus", "mode")]
        [InlineData("seed=1\ndays=1\nmode=", "mode")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nstallMinutes=0", "stallMinutes")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nstallMinutes=-1", "stallMinutes")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nstallMinutes=abc", "stallMinutes")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nbudgetMinutes=0", "budgetMinutes")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nbudgetMinutes=-5", "budgetMinutes")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nbudgetMinutes=abc", "budgetMinutes")]
        public void Parse_BadOrOutOfRangeValue_IsInvalidAndNamesTheKey(string text, string key)
        {
            RunConfigResult result = RunConfig.Parse(text);

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Null(result.Config);
            Assert.NotNull(result.Error);
            Assert.Contains(key, result.Error, StringComparison.OrdinalIgnoreCase);
        }

        [Theory]
        [InlineData("days=1\nmode=NoDlc", "seed")]
        [InlineData("seed=1\nmode=NoDlc", "days")]
        [InlineData("seed=1\ndays=1", "mode")]
        public void Parse_MissingRequiredKey_IsInvalidAndNamesTheKey(string text, string key)
        {
            RunConfigResult result = RunConfig.Parse(text);

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Null(result.Config);
            Assert.Contains(key, result.Error, StringComparison.OrdinalIgnoreCase);
        }

        [Fact]
        public void Parse_UnknownKey_IsInvalidAndNamesTheKey()
        {
            RunConfigResult result = RunConfig.Parse(MinimalCfg + "\nfoo=1");

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains("foo", result.Error, StringComparison.OrdinalIgnoreCase);
        }

        [Theory]
        [InlineData("seed=1\nseed=2\ndays=1\nmode=NoDlc", "seed")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nSEED=1", "seed")]   // same value, different case
        public void Parse_DuplicateKey_IsInvalidAndNamesTheKey(string text, string key)
        {
            RunConfigResult result = RunConfig.Parse(text);

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains(key, result.Error, StringComparison.OrdinalIgnoreCase);
        }

        [Fact]
        public void Parse_LineWithoutEquals_IsInvalidAndNamesTheLine()
        {
            RunConfigResult result = RunConfig.Parse("seed=1\ndays=1\nmode=NoDlc\nthis is garbage");

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Null(result.Config);
            Assert.Contains("this is garbage", result.Error);
        }

        [Theory]
        [InlineData("")]
        [InlineData("   \r\n \n\t")]
        [InlineData("# only a comment")]
        public void Parse_EmptyOrContentlessText_IsInvalid_NotInert(string text)
        {
            RunConfigResult result = RunConfig.Parse(text);

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Null(result.Config);
            Assert.False(string.IsNullOrEmpty(result.Error));
        }

        [Theory]
        [InlineData("=")]
        [InlineData("=\n=\n=")]
        [InlineData("seed==1")]
        [InlineData("\0\0\0")]
        [InlineData("seed=äöü\ndays=€\nmode=\U0001F600")]
        [InlineData("seed=1\u0000\ndays=1\nmode=NoDlc")]
        [InlineData("seed=2147483648\ndays=1\nmode=NoDlc")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nstallMinutes=NaN")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nbudgetMinutes=Infinity")]
        [InlineData("seed=1\ndays=1\nmode=NoDlc\nstallMinutes=1e999")]
        public void Parse_HostileInput_NeverThrowsAndIsInvalid(string text)
        {
            RunConfigResult result = null;

            Exception thrown = Record.Exception(() => result = RunConfig.Parse(text));

            Assert.Null(thrown);
            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Null(result.Config);
            Assert.False(string.IsNullOrEmpty(result.Error));
        }

        [Fact]
        public void Parse_VeryLongInput_NeverThrows()
        {
            string text = new string('x', 200000) + "=1\n" + MinimalCfg;

            Exception thrown = Record.Exception(() => RunConfig.Parse(text));

            Assert.Null(thrown);
        }

        // ------------------------------------------- AC-U2: phase machine

        [Fact]
        public void NewRun_StartsArmedAndRunningWithNothingReached()
        {
            HarnessRun run = NewRun();

            Assert.Equal(HarnessPhase.Armed, run.Phase);
            Assert.Equal(RunStatus.Running, run.Status);
            Assert.Null(run.Reason);
            Assert.Equal(0, run.DaysReached);
        }

        [Fact]
        public void Constructor_NullConfig_ThrowsArgumentNullException()
        {
            Assert.Throws<ArgumentNullException>(() => new HarnessRun(null, 0));
        }

        [Fact]
        public void Armed_WithoutMainMenu_DoesNothingAndStaysArmed()
        {
            HarnessRun run = NewRun();

            Assert.Equal(HarnessAction.None, run.Tick(Obs(1)));
            Assert.Equal(HarnessPhase.Armed, run.Phase);
        }

        [Fact]
        public void Armed_OnMainMenu_RequestsNewGame()
        {
            HarnessRun run = NewRun();

            Assert.Equal(HarnessAction.StartNewGame, run.Tick(Obs(1, menu: true)));
            Assert.Equal(HarnessPhase.StartRequested, run.Phase);
        }

        [Fact]
        public void StartNewGame_IsRequestedExactlyOnce()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));

            // The main menu may still be reported while the game manager loads.
            HarnessAction again = run.Tick(Obs(2, menu: true));

            Assert.Equal(HarnessAction.None, again);
            Assert.Equal(HarnessPhase.StartRequested, run.Phase);
        }

        [Fact]
        public void StartRequested_WhileNothingActiveYet_Waits()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));

            Assert.Equal(HarnessAction.None, run.Tick(Obs(2)));
            Assert.Equal(HarnessPhase.StartRequested, run.Phase);
        }

        [Fact]
        public void StartRequested_WhenCreationBecomesActive_AdvancesCreation()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));

            HarnessAction action = run.Tick(Obs(2, creation: true, inGame: true));

            Assert.Equal(HarnessAction.AdvanceCreation, action);
            Assert.Equal(HarnessPhase.CharacterCreation, run.Phase);
        }

        [Fact]
        public void CharacterCreation_AdvancesOnEveryTickWhileActive()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));
            run.Tick(Obs(2, creation: true, inGame: true));

            for (int i = 0; i < 5; i++)
            {
                Assert.Equal(HarnessAction.AdvanceCreation, run.Tick(Obs(3 + i, creation: true, inGame: true)));
                Assert.Equal(HarnessPhase.CharacterCreation, run.Phase);
            }
        }

        [Fact]
        public void CharacterCreation_WhileNeitherCreationNorMapActive_Waits()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));
            run.Tick(Obs(2, creation: true, inGame: true));

            Assert.Equal(HarnessAction.None, run.Tick(Obs(3, inGame: true)));
            Assert.Equal(HarnessPhase.CharacterCreation, run.Phase);
        }

        [Fact]
        public void CharacterCreation_WhenMapBecomesActive_SetsUpMap()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));
            run.Tick(Obs(2, creation: true, inGame: true));

            HarnessAction action = run.Tick(Obs(3, map: true, inGame: true));

            Assert.Equal(HarnessAction.SetupMap, action);
            Assert.Equal(HarnessPhase.Map, run.Phase);
        }

        [Fact]
        public void StartRequested_WhenMapIsActiveWithoutCreation_SetsUpMap()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));

            HarnessAction action = run.Tick(Obs(2, map: true, inGame: true));

            Assert.Equal(HarnessAction.SetupMap, action);
            Assert.Equal(HarnessPhase.Map, run.Phase);
        }

        [Fact]
        public void Map_NextTick_MovesToRunningAndKeepsRunning()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));
            run.Tick(Obs(2, map: true, inGame: true));

            HarnessAction action = run.Tick(Obs(3, map: true, inGame: true));

            Assert.Equal(HarnessAction.KeepRunning, action);
            Assert.Equal(HarnessPhase.Running, run.Phase);
        }

        [Fact]
        public void SetupMap_IsRequestedExactlyOnce()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, menu: true));
            int setups = 0;

            for (int i = 0; i < 10; i++)
            {
                if (run.Tick(Obs(2 + i, map: true, inGame: true)) == HarnessAction.SetupMap)
                {
                    setups++;
                }
            }

            Assert.Equal(1, setups);
        }

        [Fact]
        public void Running_BelowTargetDays_KeepsRunning()
        {
            HarnessRun run = NewRun(days: 3);
            DriveToRunning(run, 1);

            Assert.Equal(HarnessAction.KeepRunning, run.Tick(Obs(2, map: true, inGame: true, days: 2)));
            Assert.Equal(HarnessPhase.Running, run.Phase);
            Assert.Equal(RunStatus.Running, run.Status);
        }

        [Fact]
        public void Running_WhenTargetDaysReached_CompletesAndRequestsEndGame()
        {
            HarnessRun run = NewRun(days: 3);
            DriveToRunning(run, 1);

            HarnessAction action = run.Tick(Obs(2, map: true, inGame: true, days: 3));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(HarnessPhase.Ending, run.Phase);
            Assert.Equal(RunStatus.Completed, run.Status);
            Assert.Null(run.Reason);
            Assert.Equal(3, run.DaysReached);
        }

        [Fact]
        public void Running_DaysBeyondTarget_AlsoCompletes()
        {
            HarnessRun run = NewRun(days: 3);
            DriveToRunning(run, 1);

            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(Obs(2, map: true, inGame: true, days: 5)));
            Assert.Equal(RunStatus.Completed, run.Status);
        }

        [Fact]
        public void EndGame_IsRequestedExactlyOnce()
        {
            HarnessRun run = NewRun(days: 1);
            DriveToRunning(run, 1);
            int requests = 0;

            for (int i = 0; i < 20; i++)
            {
                HarnessAction action = run.Tick(Obs(2 + i, map: true, inGame: true, days: 1 + i));
                if (action == HarnessAction.RequestEndGame)
                {
                    requests++;
                }
            }

            Assert.Equal(1, requests);
        }

        [Fact]
        public void Ending_WhileGameStillLoaded_WaitsWithoutNewActions()
        {
            HarnessRun run = NewRun(days: 1);
            DriveToRunning(run, 1);
            run.Tick(Obs(2, map: true, inGame: true, days: 1));

            Assert.Equal(HarnessAction.None, run.Tick(Obs(3, map: true, inGame: true, days: 1)));
            Assert.Equal(HarnessPhase.Ending, run.Phase);
        }

        [Fact]
        public void Ending_WhenGameEnded_QuitsProcess()
        {
            HarnessRun run = NewRun(days: 1);
            DriveToRunning(run, 1);
            run.Tick(Obs(2, map: true, inGame: true, days: 1));

            HarnessAction action = run.Tick(Obs(3, inGame: true, ended: true, days: 1));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(RunStatus.Completed, run.Status);
        }

        [Fact]
        public void Ending_WhenNoGameExistsAnymore_QuitsProcess()
        {
            HarnessRun run = NewRun(days: 1);
            DriveToRunning(run, 1);
            run.Tick(Obs(2, map: true, inGame: true, days: 1));

            HarnessAction action = run.Tick(Obs(3, inGame: false));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
        }

        [Fact]
        public void QuitProcess_IsReturnedExactlyOnce_ThenNoneForever()
        {
            HarnessRun run = NewRun(days: 1);
            DriveToRunning(run, 1);
            run.Tick(Obs(2, map: true, inGame: true, days: 1));
            int quits = 0;

            for (int i = 0; i < 20; i++)
            {
                if (run.Tick(Obs(3 + i, ended: true, inGame: false)) == HarnessAction.QuitProcess)
                {
                    quits++;
                }
            }

            Assert.Equal(1, quits);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
        }

        [Fact]
        public void Quit_IgnoresEvenWatchdogConditions()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 1, budgetMinutes: 2);
            DriveToRunning(run, 1);
            run.Tick(Obs(2, map: true, inGame: true, days: 1));
            run.Tick(Obs(3, ended: true));

            Assert.Equal(HarnessAction.None, run.Tick(Obs(100000, menu: true, map: true, inGame: true, days: 99)));
            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(RunStatus.Completed, run.Status);
        }

        [Fact]
        public void HappyPath_VisitsEveryPhaseInOrder()
        {
            HarnessRun run = NewRun(days: 1);
            var seen = new System.Collections.Generic.List<HarnessPhase> { run.Phase };
            HarnessObservation[] script =
            {
                Obs(1, menu: true),
                Obs(2, creation: true, inGame: true),
                Obs(3, creation: true, inGame: true),
                Obs(4, map: true, inGame: true),
                Obs(5, map: true, inGame: true),
                Obs(6, map: true, inGame: true, days: 1),
                Obs(7, inGame: true, ended: true, days: 1),
                Obs(8, ended: true),
            };

            foreach (HarnessObservation o in script)
            {
                run.Tick(o);
                if (seen[seen.Count - 1] != run.Phase)
                {
                    seen.Add(run.Phase);
                }
            }

            Assert.Equal(
                new[]
                {
                    HarnessPhase.Armed, HarnessPhase.StartRequested, HarnessPhase.CharacterCreation,
                    HarnessPhase.Map, HarnessPhase.Running, HarnessPhase.Ending, HarnessPhase.Quit,
                },
                seen);
        }

        [Fact]
        public void Running_TracksMaximumDaysElapsed()
        {
            HarnessRun run = NewRun(days: 10);
            DriveToRunning(run, 1);

            run.Tick(Obs(2, map: true, inGame: true, days: 4));
            run.Tick(Obs(3, map: true, inGame: true, days: 2));

            Assert.Equal(4, run.DaysReached);
        }

        // ------------------------------------------------- AC-U3: watchdog

        [Fact]
        public void Watchdog_JustBeforeStallLimit_DoesNotFire()
        {
            HarnessRun run = NewRun(stallMinutes: 5, start: 100);

            Assert.Equal(HarnessAction.None, run.Tick(Obs(100 + 299)));
            Assert.Equal(RunStatus.Running, run.Status);
        }

        [Fact]
        public void Watchdog_NoProgressForStallMinutes_AbortsWithStallReasonAndEndsGame()
        {
            HarnessRun run = NewRun(stallMinutes: 5, start: 100);

            HarnessAction action = run.Tick(Obs(100 + 300));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("stall:Armed", run.Reason);
            Assert.Equal(HarnessPhase.Ending, run.Phase);
        }

        [Fact]
        public void Watchdog_StallReasonNamesThePhaseThatStalled()
        {
            HarnessRun run = NewRun(stallMinutes: 5);
            run.Tick(Obs(10, menu: true));

            HarnessAction action = run.Tick(Obs(10 + 300));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("stall:StartRequested", run.Reason);
        }

        [Fact]
        public void Watchdog_StallWhileRunning_AbortsWithRunningPhase()
        {
            HarnessRun run = NewRun(days: 10, stallMinutes: 5);
            DriveToRunning(run, 10);

            HarnessAction action = run.Tick(Obs(10 + 300, map: true, inGame: true, days: 0));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("stall:Running", run.Reason);
            Assert.Equal(RunStatus.Aborted, run.Status);
        }

        [Fact]
        public void Watchdog_PhaseChangeCountsAsProgress_AndResetsTheStallClock()
        {
            HarnessRun run = NewRun(stallMinutes: 5);
            run.Tick(Obs(200, menu: true));                 // phase change at t=200

            Assert.Equal(HarnessAction.None, run.Tick(Obs(200 + 299)));
            Assert.Equal(RunStatus.Running, run.Status);
            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(Obs(200 + 300)));
            Assert.Equal("stall:StartRequested", run.Reason);
        }

        [Fact]
        public void Watchdog_IncreasingDaysResetTheStallClock()
        {
            HarnessRun run = NewRun(days: 10, stallMinutes: 5);
            DriveToRunning(run, 10);
            run.Tick(Obs(250, map: true, inGame: true, days: 1));     // progress at t=250

            Assert.Equal(HarnessAction.KeepRunning, run.Tick(Obs(250 + 299, map: true, inGame: true, days: 1)));
            Assert.Equal(HarnessAction.RequestEndGame, run.Tick(Obs(250 + 300, map: true, inGame: true, days: 1)));
            Assert.Equal("stall:Running", run.Reason);
        }

        [Fact]
        public void Watchdog_RepeatedSameDayValueIsNoProgress()
        {
            HarnessRun run = NewRun(days: 10, stallMinutes: 5);
            DriveToRunning(run, 10);
            run.Tick(Obs(20, map: true, inGame: true, days: 1));      // progress at t=20

            // Re-reporting the same day must not push the stall deadline out.
            run.Tick(Obs(200, map: true, inGame: true, days: 1));
            HarnessAction action = run.Tick(Obs(20 + 300, map: true, inGame: true, days: 1));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("stall:Running", run.Reason);
        }

        [Fact]
        public void Watchdog_SteadyProgressNeverStalls()
        {
            HarnessRun run = NewRun(days: 365, stallMinutes: 5, budgetMinutes: 600);
            DriveToRunning(run, 0);

            for (int day = 1; day <= 50; day++)
            {
                HarnessAction action = run.Tick(Obs(day * 200.0, map: true, inGame: true, days: day));
                Assert.Equal(HarnessAction.KeepRunning, action);
            }

            Assert.Equal(RunStatus.Running, run.Status);
        }

        [Fact]
        public void Watchdog_TotalBudgetExceeded_AbortsWithTimeoutReasonEvenWithProgress()
        {
            HarnessRun run = NewRun(days: 365, stallMinutes: 20, budgetMinutes: 10, start: 50);   // stall > budget: isolate the budget check
            DriveToRunning(run, 50);
            run.Tick(Obs(50 + 599, map: true, inGame: true, days: 1));   // fresh progress right before the limit

            HarnessAction action = run.Tick(Obs(50 + 600, map: true, inGame: true, days: 2));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("timeout:Running", run.Reason);
            Assert.Equal(HarnessPhase.Ending, run.Phase);
        }

        [Fact]
        public void Watchdog_JustBeforeBudget_DoesNotFire()
        {
            HarnessRun run = NewRun(days: 365, stallMinutes: 20, budgetMinutes: 10);   // stall > budget: isolate the budget check
            DriveToRunning(run, 0);

            run.Tick(Obs(599, map: true, inGame: true, days: 1));

            Assert.Equal(RunStatus.Running, run.Status);
        }

        [Fact]
        public void Watchdog_TimeoutWinsOverStallWhenBothHaveElapsed()
        {
            HarnessRun run = NewRun(stallMinutes: 5, budgetMinutes: 10);

            run.Tick(Obs(600));

            Assert.Equal("timeout:Armed", run.Reason);
        }

        [Fact]
        public void Watchdog_AbortKeepsDaysReachedSoFar()
        {
            HarnessRun run = NewRun(days: 10, stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(10, map: true, inGame: true, days: 4));

            run.Tick(Obs(10 + 300, map: true, inGame: true, days: 4));

            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal(4, run.DaysReached);
        }

        [Fact]
        public void Watchdog_AbortRequestsEndGameExactlyOnce()
        {
            HarnessRun run = NewRun(stallMinutes: 5, budgetMinutes: 10);
            int requests = 0;

            // Walk well past both the stall and the budget limit while still "Ending".
            for (double t = 0; t <= 650; t += 50)
            {
                if (run.Tick(Obs(t, inGame: true)) == HarnessAction.RequestEndGame)
                {
                    requests++;
                }
            }

            Assert.Equal(1, requests);
        }

        [Fact]
        public void Watchdog_AfterAbort_GameEndedQuitsAndKeepsAbortReason()
        {
            HarnessRun run = NewRun(stallMinutes: 5);
            run.Tick(Obs(300));                                 // stall:Armed -> Ending

            HarnessAction action = run.Tick(Obs(301, ended: true));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("stall:Armed", run.Reason);
        }

        [Fact]
        public void Ending_StallAfterCompletion_QuitsAndMarksAbortedWithEndStall()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(100, map: true, inGame: true, days: 1));   // Completed -> Ending at t=100

            Assert.Equal(HarnessAction.None, run.Tick(Obs(100 + 299, map: true, inGame: true, days: 1)));
            HarnessAction action = run.Tick(Obs(100 + 300, map: true, inGame: true, days: 1));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("end-stall", run.Reason);
        }

        [Fact]
        public void Ending_StallAfterAbort_QuitsAndAppendsEndStall()
        {
            HarnessRun run = NewRun(stallMinutes: 5, budgetMinutes: 600);
            run.Tick(Obs(300));                                  // stall:Armed -> Ending at t=300

            HarnessAction action = run.Tick(Obs(300 + 300, inGame: true));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("stall:Armed;end-stall", run.Reason);
        }

        [Fact]
        public void Ending_BudgetExpiryWhileEnding_DoesNotRequestEndGameAgain()
        {
            HarnessRun run = NewRun(stallMinutes: 5, budgetMinutes: 10);
            run.Tick(Obs(600));                                  // timeout:Armed -> Ending

            HarnessAction action = run.Tick(Obs(700, inGame: true));

            Assert.Equal(HarnessAction.None, action);
            Assert.Equal("timeout:Armed", run.Reason);
        }

        [Fact]
        public void Ending_GameEndedBeatsEndStall()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(100, map: true, inGame: true, days: 1));

            HarnessAction action = run.Tick(Obs(100 + 1000, ended: true));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(RunStatus.Completed, run.Status);
            Assert.Null(run.Reason);
        }

        // ------------------------------------------------- C8: abort on the tick that delivers a new day

        [Fact]
        public void Watchdog_StallAbortOnTickDeliveringNewDay_RecordsThatDay()
        {
            HarnessRun run = NewRun(days: 10, stallMinutes: 5);
            DriveToRunning(run, 10);

            HarnessAction action = run.Tick(Obs(10 + 300, map: true, inGame: true, days: 2));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("stall:Running", run.Reason);
            Assert.Equal(2, run.DaysReached);
        }

        [Fact]
        public void Watchdog_TimeoutAbortOnTickDeliveringNewDay_RecordsThatDay()
        {
            HarnessRun run = NewRun(days: 365, stallMinutes: 20, budgetMinutes: 10);
            DriveToRunning(run, 0);

            HarnessAction action = run.Tick(Obs(600, map: true, inGame: true, days: 3));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal("timeout:Running", run.Reason);
            Assert.Equal(3, run.DaysReached);
        }

        [Fact]
        public void Watchdog_AbortOnTickDeliveringTargetDay_StaysAbortedNotCompleted()
        {
            // C6/C8: the day is recorded but is not progress, so the abort wins.
            HarnessRun run = NewRun(days: 3, stallMinutes: 5);
            DriveToRunning(run, 10);

            run.Tick(Obs(10 + 300, map: true, inGame: true, days: 3));

            Assert.Equal(RunStatus.Aborted, run.Status);
            Assert.Equal("stall:Running", run.Reason);
            Assert.Equal(3, run.DaysReached);
        }

        [Fact]
        public void Watchdog_StallAbortInEarlyPhase_AlsoRecordsDeliveredDay()
        {
            HarnessRun run = NewRun(stallMinutes: 5);

            run.Tick(Obs(300, days: 4));

            Assert.Equal("stall:Armed", run.Reason);
            Assert.Equal(4, run.DaysReached);
        }

        [Fact]
        public void Ending_RisingDaysAreRecordedInDaysReached()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(100, map: true, inGame: true, days: 1));   // Completed -> Ending

            run.Tick(Obs(150, map: true, inGame: true, days: 4));

            Assert.Equal(4, run.DaysReached);
        }

        // ------------------------------------------------- C1: Ending ignores day increases

        [Fact]
        public void Ending_RisingDaysDoNotResetTheEndStallClock_AfterCompletion()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(100, map: true, inGame: true, days: 1));   // Ending since t=100

            Assert.Equal(HarnessAction.None, run.Tick(Obs(250, map: true, inGame: true, days: 2)));
            Assert.Equal(HarnessAction.None, run.Tick(Obs(399, map: true, inGame: true, days: 3)));
            HarnessAction action = run.Tick(Obs(400, map: true, inGame: true, days: 4));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal("end-stall", run.Reason);
        }

        [Fact]
        public void Ending_RisingDaysDoNotResetTheEndStallClock_AfterAbort()
        {
            HarnessRun run = NewRun(days: 10, stallMinutes: 5, budgetMinutes: 600);
            DriveToRunning(run, 10);
            run.Tick(Obs(10 + 300, map: true, inGame: true, days: 0));   // stall:Running -> Ending since t=310

            Assert.Equal(HarnessAction.None, run.Tick(Obs(400, map: true, inGame: true, days: 1)));
            Assert.Equal(HarnessAction.None, run.Tick(Obs(609, map: true, inGame: true, days: 2)));
            HarnessAction action = run.Tick(Obs(610, map: true, inGame: true, days: 3));

            Assert.Equal(HarnessAction.QuitProcess, action);
            Assert.Equal("stall:Running;end-stall", run.Reason);
        }

        // ------------------------------------------------- C9: player map events

        [Fact]
        public void PlayerMapEvents_FreshRun_IsZero()
        {
            Assert.Equal(0, NewRun().PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_TrueAtFirstObservation_CountsOne()
        {
            HarnessRun run = NewRun();

            run.Tick(Obs(1, playerInMapEvent: true));

            Assert.Equal(1, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_StayingTrue_DoesNotCountAgain()
        {
            HarnessRun run = NewRun();

            run.Tick(Obs(1, playerInMapEvent: true));
            run.Tick(Obs(2, playerInMapEvent: true));
            run.Tick(Obs(3, playerInMapEvent: true));

            Assert.Equal(1, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_FalseOnly_StaysZero()
        {
            HarnessRun run = NewRun();

            run.Tick(Obs(1));
            run.Tick(Obs(2));

            Assert.Equal(0, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_EachRisingEdgeCounts()
        {
            HarnessRun run = NewRun();

            run.Tick(Obs(1, playerInMapEvent: true));
            run.Tick(Obs(2, playerInMapEvent: false));
            run.Tick(Obs(3, playerInMapEvent: true));
            run.Tick(Obs(4, playerInMapEvent: true));
            run.Tick(Obs(5, playerInMapEvent: false));
            run.Tick(Obs(6, playerInMapEvent: true));

            Assert.Equal(3, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_MidDayBattleWithoutDayChange_IsCounted()
        {
            HarnessRun run = NewRun(days: 10);
            DriveToRunning(run, 1);

            run.Tick(Obs(2, map: true, inGame: true, days: 1, playerInMapEvent: true));
            run.Tick(Obs(3, map: true, inGame: true, days: 1, playerInMapEvent: false));

            Assert.Equal(1, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_AreCountedInEveryPhaseExceptQuit()
        {
            HarnessRun run = NewRun(days: 3);
            HarnessObservation[] script =
            {
                Obs(1, menu: true, playerInMapEvent: true),                       // Armed -> StartRequested : 1
                Obs(2),
                Obs(3, creation: true, inGame: true, playerInMapEvent: true),     // CharacterCreation       : 2
                Obs(4, creation: true, inGame: true),
                Obs(5, map: true, inGame: true, playerInMapEvent: true),          // Map                     : 3
                Obs(6, map: true, inGame: true),                                  // Running
                Obs(7, map: true, inGame: true, playerInMapEvent: true),          // Running                 : 4
                Obs(8, map: true, inGame: true),
                Obs(9, map: true, inGame: true, days: 3, playerInMapEvent: true), // Completed -> Ending     : 5
                Obs(10, inGame: true),
                Obs(11, inGame: true, playerInMapEvent: true),                    // Ending                  : 6
                Obs(12, ended: true),                                             // Quit
                Obs(13, playerInMapEvent: true),                                  // Quit: ignored
            };

            foreach (HarnessObservation o in script)
            {
                run.Tick(o);
            }

            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(6, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_OnTheAbortingTick_IsCounted()
        {
            HarnessRun run = NewRun(stallMinutes: 5);

            HarnessAction action = run.Tick(Obs(300, playerInMapEvent: true));

            Assert.Equal(HarnessAction.RequestEndGame, action);
            Assert.Equal(1, run.PlayerMapEvents);
        }

        [Fact]
        public void PlayerMapEvents_AfterQuit_AreNotCounted()
        {
            HarnessRun run = NewRun(stallMinutes: 5);
            run.Tick(Obs(300));                 // stall:Armed -> Ending
            run.Tick(Obs(301, ended: true));    // Quit

            run.Tick(Obs(302, playerInMapEvent: true));

            Assert.Equal(HarnessPhase.Quit, run.Phase);
            Assert.Equal(0, run.PlayerMapEvents);
        }

        [Fact]
        public void ToResult_PlayerMapEventsAreReported()
        {
            HarnessRun run = NewRun();
            run.Tick(Obs(1, playerInMapEvent: true));
            run.Tick(Obs(2, playerInMapEvent: false));
            run.Tick(Obs(3, playerInMapEvent: true));

            Assert.Equal(2, ToResult(run, 60).PlayerMapEvents);
        }

        // ------------------------------------------------- AC-U4: result record

        private static readonly ModuleEntry[] SomeModules = { new ModuleEntry("Native", "v1.4.8") };

        private static RunResult ToResult(HarnessRun run, double realSeconds)
        {
            return run.ToResult(realSeconds, SomeModules, new ExceptionStats().Summary());
        }

        [Fact]
        public void ToResult_Completed_HasRunValuesPassedScenarioAndPassedCheck()
        {
            HarnessRun run = NewRun(days: 3, seed: 7, mode: "NoDlc", start: 100);
            DriveToRunning(run, 100);
            run.Tick(Obs(150, map: true, inGame: true, days: 3));
            ExceptionSummary exceptions = new ExceptionSummary(4, 1, 0, new[] { new ExceptionKeyCount("k", 4) });

            RunResult result = run.ToResult(220, SomeModules, exceptions);   // elapsed 120 s = 2 min, 3 days -> 1.50

            Assert.Equal(RunStatus.Completed, result.Status);
            Assert.Equal(string.Empty, result.Reason);
            Assert.Equal(7, result.Seed);
            Assert.Equal("NoDlc", result.Mode);
            Assert.Equal(3, result.DaysRequested);
            Assert.Equal(3, result.DaysReached);
            Assert.Equal(120, result.RealSeconds);
            Assert.Equal(1.50, result.GameDaysPerRealMinute);
            Assert.Equal(0, result.PlayerMapEvents);
            Assert.Same(SomeModules, result.Modules);
            Assert.Same(exceptions, result.Exceptions);

            ScenarioResult soak = Assert.Single(result.Scenarios);
            Assert.Equal("soak", soak.Id);
            Assert.Equal(ScenarioStatus.Passed, soak.Status);
            Assert.Equal(120, soak.Seconds);

            CheckResult check = Assert.Single(result.Checks);
            Assert.Equal("daysReached", check.Name);
            Assert.Equal(">= 3", check.Expected);
            Assert.Equal("3", check.Actual);
            Assert.True(check.Passed);
        }

        [Fact]
        public void ToResult_StallAbort_IsTimeoutWithFailedCheckAndPartialProgress()
        {
            HarnessRun run = NewRun(days: 10, seed: 3, mode: "FeatureOff", stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(10, map: true, inGame: true, days: 1));
            run.Tick(Obs(10 + 300, map: true, inGame: true, days: 1));   // stall:Running

            RunResult result = ToResult(run, 90);   // 1 day in 1.5 minutes -> 0.67

            Assert.Equal(RunStatus.Aborted, result.Status);
            Assert.Equal("stall:Running", result.Reason);
            Assert.Equal(1, result.DaysReached);
            Assert.Equal(90, result.RealSeconds);
            Assert.Equal(0.67, result.GameDaysPerRealMinute);
            Assert.Equal(ScenarioStatus.Timeout, result.Scenarios[0].Status);
            Assert.Equal(">= 10", result.Checks[0].Expected);
            Assert.Equal("1", result.Checks[0].Actual);
            Assert.False(result.Checks[0].Passed);
        }

        [Fact]
        public void ToResult_ZeroElapsedTime_ReportsZeroSecondsAndRate()
        {
            HarnessRun run = NewRun(start: 500);

            RunResult result = ToResult(run, 500);

            Assert.Equal(0, result.RealSeconds);
            Assert.Equal(0, result.GameDaysPerRealMinute);
        }

        [Fact]
        public void ToResult_ClockBeforeStart_IsClampedToZero()
        {
            Assert.Equal(0, ToResult(NewRun(start: 500), 400).RealSeconds);
        }

        [Fact]
        public void ToResult_RealSeconds_RoundsHalfAwayFromZero()
        {
            Assert.Equal(3, ToResult(NewRun(start: 0), 2.5).RealSeconds);
            Assert.Equal(2, ToResult(NewRun(start: 0), 2.49).RealSeconds);
        }

        [Fact]
        public void ToResult_FreshRun_IsRunningWithEmptyReason()
        {
            RunResult result = ToResult(NewRun(start: 0), 60);

            Assert.Equal(RunStatus.Running, result.Status);
            Assert.Equal(string.Empty, result.Reason);
            Assert.Equal(0, result.DaysReached);
            Assert.Equal(0, result.GameDaysPerRealMinute);
            Assert.Equal(ScenarioStatus.Error, result.Scenarios[0].Status);
        }

        [Fact]
        public void ToResult_UnderGermanCulture_WritesInvariantJson()
        {
            HarnessRun run = NewRun(days: 3, start: 100);
            DriveToRunning(run, 100);
            run.Tick(Obs(150, map: true, inGame: true, days: 3));

            WithCulture("de-DE", () =>
            {
                string json = RunResultWriter.Write(ToResult(run, 220));

                Assert.Contains("\"realSeconds\": 120,\n  \"gameDaysPerRealMinute\": 1.50,\n  \"playerMapEvents\": 0,", json);
            });
        }

        [Theory]
        [InlineData(RunStatus.Completed, null, true, ScenarioStatus.Passed)]
        [InlineData(RunStatus.Completed, "", true, ScenarioStatus.Passed)]
        [InlineData(RunStatus.Completed, null, false, ScenarioStatus.Failed)]
        [InlineData(RunStatus.Aborted, "timeout:Running", false, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "timeout:Armed", false, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "stall:CharacterCreation", false, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "stall:Running", true, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "end-stall", true, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "stall:Map;end-stall", false, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "timeout:Running;end-stall", false, ScenarioStatus.Timeout)]
        [InlineData(RunStatus.Aborted, "config:missing required key 'seed'", false, ScenarioStatus.Error)]
        [InlineData(RunStatus.Aborted, "stalled", false, ScenarioStatus.Error)]
        [InlineData(RunStatus.Aborted, "crash", false, ScenarioStatus.Error)]
        [InlineData(RunStatus.Aborted, "unhandled:Running", true, ScenarioStatus.Failed)]
        [InlineData(RunStatus.Aborted, "unhandled:Armed", false, ScenarioStatus.Failed)]
        [InlineData(RunStatus.Aborted, "", false, ScenarioStatus.Error)]
        [InlineData(RunStatus.Aborted, null, false, ScenarioStatus.Error)]
        [InlineData(RunStatus.Running, null, false, ScenarioStatus.Error)]
        public void ClassifySoak_MapsStatusAndReason(RunStatus status, string reason, bool checkPassed, ScenarioStatus expected)
        {
            Assert.Equal(expected, HarnessRun.ClassifySoak(status, reason, checkPassed));
        }

        // ------------------------------------------------- unhandled exception record

        [Fact]
        public void ToUnhandledResult_WhileRunning_IsAbortedWithUnhandledPhaseReason()
        {
            HarnessRun run = NewRun(days: 5, start: 0);
            DriveToRunning(run, 0);
            run.Tick(Obs(30, map: true, inGame: true, days: 2));
            ExceptionSummary exceptions = new ExceptionSummary(9, 0, 1, new ExceptionKeyCount[0]);

            RunResult result = run.ToUnhandledResult(60, SomeModules, exceptions);

            Assert.Equal(RunStatus.Aborted, result.Status);
            Assert.Equal("unhandled:Running", result.Reason);
            Assert.Equal(2, result.DaysReached);
            Assert.Equal(60, result.RealSeconds);
            Assert.Same(exceptions, result.Exceptions);
            Assert.Equal(60, result.Scenarios[0].Seconds);
            Assert.Equal(ScenarioStatus.Failed, result.Scenarios[0].Status);
            Assert.False(result.Checks[0].Passed);
        }

        [Fact]
        public void ToUnhandledResult_BeforeTheMap_NamesThePhase()
        {
            HarnessRun run = NewRun(start: 0);
            run.Tick(Obs(1, menu: true));   // StartRequested

            Assert.Equal("unhandled:StartRequested", ToUnhandledResult(run, 2).Reason);
        }

        [Fact]
        public void ToUnhandledResult_DoesNotChangeTheRun()
        {
            HarnessRun run = NewRun(start: 0);
            DriveToRunning(run, 0);

            ToUnhandledResult(run, 10);

            Assert.Equal(RunStatus.Running, run.Status);
            Assert.Null(run.Reason);
            Assert.Equal(HarnessPhase.Running, run.Phase);
        }

        [Fact]
        public void ToUnhandledResult_AfterCompletion_KeepsTheFinalStatus()
        {
            HarnessRun run = NewRun(days: 1, start: 0);
            DriveToRunning(run, 0);
            run.Tick(Obs(10, map: true, inGame: true, days: 1));   // Completed -> Ending

            RunResult result = ToUnhandledResult(run, 20);

            Assert.Equal(RunStatus.Completed, result.Status);
            Assert.Equal(string.Empty, result.Reason);
            Assert.Equal(ScenarioStatus.Passed, result.Scenarios[0].Status);
        }

        [Fact]
        public void ToUnhandledResult_AfterCompletion_KeepsTheTimeOfTheCompletion()
        {
            HarnessRun run = NewRun(days: 1, start: 0);
            DriveToRunning(run, 0);
            run.Tick(Obs(30, map: true, inGame: true, days: 1));   // Completed -> Ending at 30 s
            run.Tick(Obs(90, map: true, inGame: true, days: 1));   // still Ending
            ExceptionSummary exceptions = new ExceptionSummary(4, 1, 1, new ExceptionKeyCount[0]);

            RunResult result = run.ToUnhandledResult(200, SomeModules, exceptions);

            Assert.Equal(30, result.RealSeconds);
            Assert.Equal(2.0, result.GameDaysPerRealMinute);
            Assert.Equal(30, result.Scenarios[0].Seconds);
            Assert.Same(exceptions, result.Exceptions);
        }

        [Fact]
        public void ToUnhandledResult_AfterAnAbort_KeepsTheTimeOfTheAbort()
        {
            HarnessRun run = NewRun(stallMinutes: 5, start: 0);
            run.Tick(Obs(300));   // stall:Armed -> Ending at 300 s

            RunResult result = ToUnhandledResult(run, 450);

            Assert.Equal(300, result.RealSeconds);
            Assert.Equal(300, result.Scenarios[0].Seconds);
        }

        [Fact]
        public void ToUnhandledResult_AfterAnEndStall_KeepsTheTimeOfTheEndStall()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 5, start: 0);
            DriveToRunning(run, 0);
            run.Tick(Obs(10, map: true, inGame: true, days: 1));         // Completed -> Ending
            run.Tick(Obs(10 + 300, map: true, inGame: true, days: 1));   // end-stall -> Quit at 310 s

            RunResult result = ToUnhandledResult(run, 500);

            Assert.Equal("end-stall", result.Reason);
            Assert.Equal(310, result.RealSeconds);
            Assert.Equal(310, result.Scenarios[0].Seconds);
        }

        [Fact]
        public void ToUnhandledResult_AfterAnAbort_KeepsTheAbortReason()
        {
            HarnessRun run = NewRun(stallMinutes: 5, start: 0);
            run.Tick(Obs(300));   // stall:Armed -> Ending

            RunResult result = ToUnhandledResult(run, 301);

            Assert.Equal(RunStatus.Aborted, result.Status);
            Assert.Equal("stall:Armed", result.Reason);
            Assert.Equal(ScenarioStatus.Timeout, result.Scenarios[0].Status);
        }

        private static RunResult ToUnhandledResult(HarnessRun run, double realSeconds)
        {
            return run.ToUnhandledResult(realSeconds, SomeModules, new ExceptionStats().Summary());
        }

        [Fact]
        public void ToResult_EndStallAfterCompletion_IsTimeout()
        {
            HarnessRun run = NewRun(days: 1, stallMinutes: 5);
            DriveToRunning(run, 0);
            run.Tick(Obs(10, map: true, inGame: true, days: 1));        // Completed -> Ending
            run.Tick(Obs(10 + 300, map: true, inGame: true, days: 1));  // end-stall -> Quit

            RunResult result = ToResult(run, 400);

            Assert.Equal("end-stall", result.Reason);
            Assert.Equal(ScenarioStatus.Timeout, result.Scenarios[0].Status);
            Assert.True(result.Checks[0].Passed);
        }

        // ------------------------------------------------- ownAssemblies config key

        [Fact]
        public void Parse_OwnAssemblies_Missing_IsEmpty()
        {
            Assert.Empty(ValidConfig(MinimalCfg).OwnAssemblies);
        }

        [Fact]
        public void Parse_OwnAssemblies_CommaSeparated_ReturnsTrimmedNamesInOrder()
        {
            RunConfig config = ValidConfig(MinimalCfg + "\nownAssemblies=CoherentWarAI, SmithingSuite ,AutoTraderSpeed");

            Assert.Equal(new[] { "CoherentWarAI", "SmithingSuite", "AutoTraderSpeed" }, config.OwnAssemblies);
        }

        [Theory]
        [InlineData("ownAssemblies=")]
        [InlineData("ownAssemblies=   ")]
        [InlineData("ownAssemblies= , ,,")]
        public void Parse_OwnAssemblies_EmptyOrBlank_IsEmpty(string line)
        {
            Assert.Empty(ValidConfig(MinimalCfg + "\n" + line).OwnAssemblies);
        }

        [Fact]
        public void Parse_OwnAssemblies_IgnoresEmptyEntriesAndWhitespace()
        {
            RunConfig config = ValidConfig(MinimalCfg + "\nOWNASSEMBLIES = , A ,, B ,");

            Assert.Equal(new[] { "A", "B" }, config.OwnAssemblies);
        }

        [Fact]
        public void Parse_OwnAssemblies_DuplicateKey_IsInvalid()
        {
            RunConfigResult result = RunConfig.Parse(MinimalCfg + "\nownAssemblies=A\nownAssemblies=B");

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains("ownAssemblies", result.Error);
        }

        [Fact]
        public void Parse_OwnAssemblies_ControlCharacter_IsInvalid()
        {
            RunConfigResult result = RunConfig.Parse(MinimalCfg + "\nownAssemblies=A\u0000B");

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains("ownAssemblies", result.Error);
        }

        [Fact]
        public void Parse_OwnAssembliesTypo_IsStillRejectedAsUnknownKey()
        {
            RunConfigResult result = RunConfig.Parse(MinimalCfg + "\nownAssembly=A");

            Assert.Equal(RunConfigStatus.Invalid, result.Status);
            Assert.Contains("unknown key 'ownAssembly'", result.Error);
        }
    }
}
