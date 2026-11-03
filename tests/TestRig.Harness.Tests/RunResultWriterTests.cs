using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class RunResultWriterTests
    {
        private static readonly ModuleEntry[] NoModules = new ModuleEntry[0];

        private static RunResult SampleResult(string reason = "", double? rate = 2.41)
        {
            return new RunResult(
                RunStatus.Completed,
                reason,
                seed: 1,
                mode: "WarSails",
                daysRequested: 1,
                daysReached: 1,
                realSeconds: 25,
                gameDaysPerRealMinute: rate,
                runningDaysPerRealMinute: 3.6,
                playerMapEvents: 0,
                modules: new[] { new ModuleEntry("Native", "v1.4.8"), new ModuleEntry("SandBox", "v1.4.8") },
                exceptions: new ExceptionSummary(
                    total: 7,
                    own: 2,
                    harness: 1,
                    unhandled: 1,
                    top: new[] { new ExceptionKeyCount("k1", 3), new ExceptionKeyCount("k2", 1) },
                    classification: new ClassificationSummary(walks: 7, walkMs: 9.8765, handlerMs: 12.3456, maxHandlerMs: 4.5, ownExact: true)),
                scenarios: new[] { new ScenarioResult("soak", ScenarioStatus.Passed, 25) },
                checks: new[] { new CheckResult("soak", "daysReached", ">= 1", "1", true) });
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

        [Fact]
        public void Write_FullRecord_MatchesContractExactly()
        {
            string json = RunResultWriter.Write(SampleResult());

            Assert.Equal(
                "{\n" +
                "  \"schema\": 1,\n" +
                "  \"status\": \"Completed\",\n" +
                "  \"reason\": \"\",\n" +
                "  \"seed\": 1,\n" +
                "  \"mode\": \"WarSails\",\n" +
                "  \"daysRequested\": 1,\n" +
                "  \"daysReached\": 1,\n" +
                "  \"realSeconds\": 25,\n" +
                "  \"gameDaysPerRealMinute\": 2.41,\n" +
                "  \"runningDaysPerRealMinute\": 3.60,\n" +
                "  \"playerMapEvents\": 0,\n" +
                "  \"modules\": [\n" +
                "    {\n" +
                "      \"id\": \"Native\",\n" +
                "      \"version\": \"v1.4.8\"\n" +
                "    },\n" +
                "    {\n" +
                "      \"id\": \"SandBox\",\n" +
                "      \"version\": \"v1.4.8\"\n" +
                "    }\n" +
                "  ],\n" +
                "  \"exceptions\": {\n" +
                "    \"total\": 7,\n" +
                "    \"own\": 2,\n" +
                "    \"harness\": 1,\n" +
                "    \"vanilla\": 4,\n" +
                "    \"unhandled\": 1,\n" +
                "    \"classification\": {\n" +
                "      \"walks\": 7,\n" +
                "      \"walkMs\": 9.88,\n" +
                "      \"handlerMs\": 12.35,\n" +
                "      \"maxHandlerMs\": 4.50,\n" +
                "      \"ownExact\": true\n" +
                "    },\n" +
                "    \"top\": [\n" +
                "      {\n" +
                "        \"key\": \"k1\",\n" +
                "        \"count\": 3\n" +
                "      },\n" +
                "      {\n" +
                "        \"key\": \"k2\",\n" +
                "        \"count\": 1\n" +
                "      }\n" +
                "    ]\n" +
                "  },\n" +
                "  \"scenarios\": [\n" +
                "    {\n" +
                "      \"id\": \"soak\",\n" +
                "      \"status\": \"Passed\",\n" +
                "      \"seconds\": 25\n" +
                "    }\n" +
                "  ],\n" +
                "  \"checks\": [\n" +
                "    {\n" +
                "      \"scenario\": \"soak\",\n" +
                "      \"name\": \"daysReached\",\n" +
                "      \"expected\": \">= 1\",\n" +
                "      \"actual\": \"1\",\n" +
                "      \"passed\": true\n" +
                "    }\n" +
                "  ]\n" +
                "}\n",
                json);
        }

        [Fact]
        public void Write_TopLevelFieldOrder_IsTheContractOrder()
        {
            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(SampleResult())))
            {
                string[] names = doc.RootElement.EnumerateObject().Select(p => p.Name).ToArray();

                Assert.Equal(
                    new[]
                    {
                        "schema", "status", "reason", "seed", "mode", "daysRequested", "daysReached",
                        "realSeconds", "gameDaysPerRealMinute", "runningDaysPerRealMinute", "playerMapEvents",
                        "modules", "exceptions", "scenarios", "checks",
                    },
                    names);
            }
        }

        [Fact]
        public void Write_ExceptionsFieldOrder_IsTheContractOrder()
        {
            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(SampleResult())))
            {
                JsonElement exceptions = doc.RootElement.GetProperty("exceptions");

                Assert.Equal(
                    new[] { "total", "own", "harness", "vanilla", "unhandled", "classification", "top" },
                    exceptions.EnumerateObject().Select(p => p.Name).ToArray());
                Assert.Equal(
                    new[] { "walks", "walkMs", "handlerMs", "maxHandlerMs", "ownExact" },
                    exceptions.GetProperty("classification").EnumerateObject().Select(p => p.Name).ToArray());
            }
        }

        [Fact]
        public void Write_OwnNotExact_IsJsonFalse()
        {
            var result = new RunResult(
                RunStatus.Completed, "", 1, "NoDlc", 1, 1, 60, 1, 1, 0, NoModules,
                new ExceptionSummary(2, 0, 0, 0, new ExceptionKeyCount[0], new ClassificationSummary(1, 0.5, 0.5, 0.5, false)),
                new ScenarioResult[0], new CheckResult[0]);

            Assert.Contains("\"ownExact\": false\n", RunResultWriter.Write(result));
        }

        [Fact]
        public void Write_ConfigError_MatchesContractExactly()
        {
            string json = RunResultWriter.Write(RunResult.ForConfigError("missing required key 'seed'", NoModules));

            Assert.Equal(
                "{\n" +
                "  \"schema\": 1,\n" +
                "  \"status\": \"Aborted\",\n" +
                "  \"reason\": \"config:missing required key 'seed'\",\n" +
                "  \"seed\": null,\n" +
                "  \"mode\": null,\n" +
                "  \"daysRequested\": null,\n" +
                "  \"daysReached\": null,\n" +
                "  \"realSeconds\": null,\n" +
                "  \"gameDaysPerRealMinute\": null,\n" +
                "  \"runningDaysPerRealMinute\": null,\n" +
                "  \"playerMapEvents\": null,\n" +
                "  \"modules\": [],\n" +
                "  \"exceptions\": {\n" +
                "    \"total\": 0,\n" +
                "    \"own\": 0,\n" +
                "    \"harness\": 0,\n" +
                "    \"vanilla\": 0,\n" +
                "    \"unhandled\": 0,\n" +
                "    \"classification\": {\n" +
                "      \"walks\": 0,\n" +
                "      \"walkMs\": 0.00,\n" +
                "      \"handlerMs\": 0.00,\n" +
                "      \"maxHandlerMs\": 0.00,\n" +
                "      \"ownExact\": true\n" +
                "    },\n" +
                "    \"top\": []\n" +
                "  },\n" +
                "  \"scenarios\": [\n" +
                "    {\n" +
                "      \"id\": \"soak\",\n" +
                "      \"status\": \"Error\",\n" +
                "      \"seconds\": null\n" +
                "    }\n" +
                "  ],\n" +
                "  \"checks\": []\n" +
                "}\n",
                json);
        }

        [Fact]
        public void ForConfigError_KeepsKnownModules()
        {
            RunResult result = RunResult.ForConfigError("x", new[] { new ModuleEntry("Native", "v1.4.8") });

            Assert.Single(result.Modules);
            Assert.Equal("Native", result.Modules[0].Id);
        }

        [Fact]
        public void ForConfigError_ReplacesEachCrAndLfWithOneSpace()
        {
            RunResult result = RunResult.ForConfigError("a\r\nb\nc\rd", NoModules);

            Assert.Equal("config:a  b c d", result.Reason);
            Assert.Equal(RunStatus.Aborted, result.Status);
        }

        [Fact]
        public void ForConfigError_NullError_GivesBareConfigReason()
        {
            Assert.Equal("config:", RunResult.ForConfigError(null, NoModules).Reason);
        }

        [Fact]
        public void ForConfigError_WithRequestedScenarios_ListsEachOnceAsErrorInRequestedOrder()
        {
            RunResult result = RunResult.ForConfigError("unknown scenario id 'b'", NoModules, new[] { "b", "a", "b" });

            Assert.Equal(new[] { "b", "a" }, result.Scenarios.Select(s => s.Id));
            Assert.All(result.Scenarios, s => Assert.Equal(ScenarioStatus.Error, s.Status));
            Assert.All(result.Scenarios, s => Assert.Null(s.Seconds));
            Assert.Empty(result.Checks);
            Assert.Equal("config:unknown scenario id 'b'", result.Reason);
        }

        [Fact]
        public void ForConfigError_WithNoRequestedScenarios_ListsTheSoakError()
        {
            RunResult result = RunResult.ForConfigError("x", NoModules, new string[0]);

            ScenarioResult only = Assert.Single(result.Scenarios);
            Assert.Equal(RunResult.SoakScenarioId, only.Id);
            Assert.Equal(ScenarioStatus.Error, only.Status);
        }

        [Fact]
        public void ForConfigError_NullRequestedScenarios_Throws()
        {
            Assert.Throws<ArgumentNullException>(() => RunResult.ForConfigError("x", NoModules, null));
        }

        [Fact]
        public void Write_EscapesQuoteBackslashAndControlCharacters()
        {
            string json = RunResultWriter.Write(SampleResult(reason: "a\"b\\c\nd\te\u0001f\u001f"));

            Assert.Contains("\"reason\": \"a\\\"b\\\\c\\u000ad\\u0009e\\u0001f\\u001f\",", json);
        }

        [Fact]
        public void Write_KeepsNonAsciiUnescaped()
        {
            string json = RunResultWriter.Write(SampleResult(reason: "Schlüssel € 中"));

            Assert.Contains("\"reason\": \"Schlüssel € 中\",", json);
        }

        [Fact]
        public void Write_HostileStrings_RoundTripThroughAStandardJsonParser()
        {
            string hostile = "\"\\/\b\f\n\r\t\u0000\u007fü\u2028}{],";
            var result = new RunResult(
                RunStatus.Aborted, hostile, 1, hostile, 1, 0, 1, 0, 0, 0,
                new[] { new ModuleEntry(hostile, hostile) },
                new ExceptionSummary(1, 0, 0, 0, new[] { new ExceptionKeyCount(hostile, 1) }, ClassificationSummary.None),
                new[] { new ScenarioResult(hostile, ScenarioStatus.Error, null) },
                new[] { new CheckResult(hostile, hostile, hostile, hostile, false) });

            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(result)))
            {
                JsonElement root = doc.RootElement;
                Assert.Equal(hostile, root.GetProperty("reason").GetString());
                Assert.Equal(hostile, root.GetProperty("mode").GetString());
                Assert.Equal(hostile, root.GetProperty("modules")[0].GetProperty("version").GetString());
                Assert.Equal(hostile, root.GetProperty("exceptions").GetProperty("top")[0].GetProperty("key").GetString());
                Assert.Equal(hostile, root.GetProperty("checks")[0].GetProperty("scenario").GetString());
                Assert.Equal(hostile, root.GetProperty("checks")[0].GetProperty("actual").GetString());
                Assert.Equal(JsonValueKind.False, root.GetProperty("checks")[0].GetProperty("passed").ValueKind);
            }
        }

        [Fact]
        public void Write_NullStrings_AreWrittenAsJsonNull()
        {
            var result = new RunResult(
                RunStatus.Aborted, null, null, null, null, null, null, null, null, null,
                NoModules, ExceptionSummary.Empty,
                new ScenarioResult[0], new CheckResult[0]);

            string json = RunResultWriter.Write(result);

            Assert.Contains("\"reason\": null,", json);
            Assert.Contains("\"mode\": null,", json);
            Assert.Contains("\"scenarios\": [],", json);
        }

        [Fact]
        public void Write_UnderGermanCulture_UsesInvariantNumbers()
        {
            WithCulture("de-DE", () =>
            {
                string json = RunResultWriter.Write(SampleResult(rate: 1.5));

                Assert.Contains("\"gameDaysPerRealMinute\": 1.50,", json);
            });
        }

        [Theory]
        [InlineData(double.NaN)]
        [InlineData(double.PositiveInfinity)]
        [InlineData(double.NegativeInfinity)]
        public void Write_NonFiniteRate_IsJsonNull(double rate)
        {
            string json = RunResultWriter.Write(SampleResult(rate: rate));

            Assert.Contains("\"gameDaysPerRealMinute\": null,", json);
        }

        [Theory]
        [InlineData(double.NaN)]
        [InlineData(double.PositiveInfinity)]
        [InlineData(double.NegativeInfinity)]
        public void Write_NonFiniteRate_StaysValidJson(double rate)
        {
            WithCulture("de-DE", () =>
            {
                string json = RunResultWriter.Write(SampleResult(rate: rate));

                using (JsonDocument doc = JsonDocument.Parse(json))
                {
                    Assert.Equal(JsonValueKind.Null, doc.RootElement.GetProperty("gameDaysPerRealMinute").ValueKind);
                }
            });
        }

        [Fact]
        public void Write_UsesLineFeedOnlyAndHasNoTrailingCommas()
        {
            string json = RunResultWriter.Write(SampleResult());

            Assert.DoesNotContain("\r", json);
            Assert.DoesNotContain(",\n}", json.Replace(" ", string.Empty));
            Assert.DoesNotContain(",\n]", json.Replace(" ", string.Empty));
        }

        [Fact]
        public void Write_RunningStatus_IsAllowed()
        {
            var result = new RunResult(
                RunStatus.Running, "", 1, "NoDlc", 1, 0, 0, 0, null, 0,
                NoModules, ExceptionSummary.Empty,
                new ScenarioResult[0], new CheckResult[0]);

            Assert.Contains("\"status\": \"Running\",", RunResultWriter.Write(result));
        }

        // ------------------------------------------------- scenario runner fields

        private static RunResult ScenarioRecord(IReadOnlyList<ScenarioResult> scenarios, IReadOnlyList<CheckResult> checks)
        {
            return new RunResult(
                RunStatus.Aborted, "tainted:b", 1, "NoDlc", 1, 0, 9, 0, null, 0,
                NoModules, ExceptionSummary.Empty, scenarios, checks);
        }

        [Fact]
        public void Write_CheckFieldOrder_StartsWithScenario()
        {
            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(SampleResult())))
            {
                string[] names = doc.RootElement.GetProperty("checks")[0].EnumerateObject().Select(p => p.Name).ToArray();

                Assert.Equal(new[] { "scenario", "name", "expected", "actual", "passed" }, names);
            }
        }

        [Fact]
        public void Write_ChecksOfSeveralScenarios_CarryTheirScenarioId()
        {
            RunResult result = ScenarioRecord(
                new[] { new ScenarioResult("a", ScenarioStatus.Passed, 3), new ScenarioResult("b", ScenarioStatus.Failed, 4) },
                new[] { new CheckResult("a", "c1", "1", "1", true), new CheckResult("b", "c2", "2", "3", false) });

            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(result)))
            {
                JsonElement checks = doc.RootElement.GetProperty("checks");
                Assert.Equal("a", checks[0].GetProperty("scenario").GetString());
                Assert.Equal("c1", checks[0].GetProperty("name").GetString());
                Assert.Equal("b", checks[1].GetProperty("scenario").GetString());
                Assert.Equal(JsonValueKind.False, checks[1].GetProperty("passed").ValueKind);
            }
        }

        [Fact]
        public void Write_NullCheckScenario_IsJsonNull()
        {
            RunResult result = ScenarioRecord(new ScenarioResult[0], new[] { new CheckResult(null, "c", "e", "a", true) });

            Assert.Contains("\"scenario\": null,", RunResultWriter.Write(result));
        }

        [Fact]
        public void Write_SkippedStatus_IsSerializedByName()
        {
            RunResult result = ScenarioRecord(
                new[] { new ScenarioResult("a", ScenarioStatus.Timeout, 300), new ScenarioResult("b", ScenarioStatus.Skipped, null) },
                new CheckResult[0]);

            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(result)))
            {
                JsonElement scenarios = doc.RootElement.GetProperty("scenarios");
                Assert.Equal("Timeout", scenarios[0].GetProperty("status").GetString());
                Assert.Equal("Skipped", scenarios[1].GetProperty("status").GetString());
                Assert.Equal(JsonValueKind.Null, scenarios[1].GetProperty("seconds").ValueKind);
            }
        }

        [Fact]
        public void CheckResult_ExposesScenarioId()
        {
            var check = new CheckResult("smithing.smelt-then-refine", "smelted", "> 0", "5", true);

            Assert.Equal("smithing.smelt-then-refine", check.Scenario);
            Assert.Equal("smelted", check.Name);
            Assert.Equal("> 0", check.Expected);
            Assert.Equal("5", check.Actual);
            Assert.True(check.Passed);
        }

        [Fact]
        public void ScenarioStatus_KeepsExistingValuesAndAppendsSkipped()
        {
            Assert.Equal(
                new[] { "Passed", "Failed", "Timeout", "Error", "Skipped" },
                Enum.GetNames(typeof(ScenarioStatus)));
        }
    }

    public class ExceptionStatsTests
    {
        [Fact]
        public void Summary_CountsTotalOwnAndUnhandled()
        {
            var stats = new ExceptionStats();
            stats.RecordFirstChance("a", own: false);
            stats.RecordFirstChance("a", own: true);
            stats.RecordFirstChance("b", own: true);
            stats.RecordUnhandled();

            ExceptionSummary summary = stats.Summary();

            Assert.Equal(3, summary.Total);
            Assert.Equal(2, summary.Own);
            Assert.Equal(1, summary.Unhandled);
        }

        [Fact]
        public void Summary_Top_IsAtMostFiveByCountDescThenKeyOrdinal()
        {
            var stats = new ExceptionStats();
            Record(stats, "f", 1);
            Record(stats, "a", 2);
            Record(stats, "b", 4);
            Record(stats, "B", 2);   // ordinal: 'B' < 'a'
            Record(stats, "c", 2);
            Record(stats, "z", 5);
            Record(stats, "d", 1);

            IReadOnlyList<ExceptionKeyCount> top = stats.Summary().Top;

            Assert.Equal(new[] { "z", "b", "B", "a", "c" }, top.Select(t => t.Key).ToArray());
            Assert.Equal(new[] { 5, 4, 2, 2, 2 }, top.Select(t => t.Count).ToArray());
        }

        [Fact]
        public void Summary_FewerThanFiveKeys_ListsAll()
        {
            var stats = new ExceptionStats();
            Record(stats, "x", 1);

            IReadOnlyList<ExceptionKeyCount> top = stats.Summary().Top;

            Assert.Single(top);
            Assert.Equal("x", top[0].Key);
        }

        [Fact]
        public void Summary_Empty_IsAllZerosAndExact()
        {
            ExceptionSummary summary = new ExceptionStats().Summary();

            Assert.Equal(0, summary.Total);
            Assert.Equal(0, summary.Own);
            Assert.Equal(0, summary.Harness);
            Assert.Equal(0, summary.Vanilla);
            Assert.Equal(0, summary.Unhandled);
            Assert.Empty(summary.Top);
            Assert.Equal(0, summary.Classification.Walks);
            Assert.Equal(0, summary.Classification.HandlerMs);
            Assert.Equal(0, summary.Classification.MaxHandlerMs);
            Assert.True(summary.Classification.OwnExact);
        }

        [Fact]
        public void Summary_OwnHarnessAndVanilla_PartitionTheTotal()
        {
            var stats = new ExceptionStats();
            stats.RecordFirstChance("own", own: true);
            stats.RecordFirstChance("own-through-harness", own: true, harness: true);   // own wins
            stats.RecordFirstChance("harness", own: false, harness: true);
            stats.RecordFirstChance("vanilla", own: false);
            stats.RecordFirstChance("vanilla", own: false, harness: false);

            ExceptionSummary summary = stats.Summary();

            Assert.Equal(5, summary.Total);
            Assert.Equal(2, summary.Own);
            Assert.Equal(1, summary.Harness);
            Assert.Equal(2, summary.Vanilla);
            Assert.Equal(summary.Total, summary.Own + summary.Harness + summary.Vanilla);
        }

        [Fact]
        public void Summary_Classification_SumsHandlerTimeAndKeepsTheMaximum()
        {
            var stats = new ExceptionStats();
            stats.RecordHandlerTime(1.0);
            stats.RecordHandlerTime(2.5);
            stats.RecordHandlerTime(0);

            ClassificationSummary classification = stats.Summary().Classification;

            Assert.Equal(3.5, classification.HandlerMs, 10);
            Assert.Equal(2.5, classification.MaxHandlerMs, 10);
            Assert.Equal(0, classification.WalkMs, 10);
        }

        [Fact]
        public void Summary_Classification_WalkMsSumsOnlyTheWalkedHandlerCallsWhichStayInHandlerMs()
        {
            var stats = new ExceptionStats();
            stats.RecordHandlerTime(1.0, walked: true);
            stats.RecordHandlerTime(0.25);
            stats.RecordHandlerTime(2.0, walked: true);

            ClassificationSummary classification = stats.Summary().Classification;

            Assert.Equal(3.0, classification.WalkMs, 10);
            Assert.Equal(3.25, classification.HandlerMs, 10);
            Assert.Equal(2.0, classification.MaxHandlerMs, 10);
        }

        [Theory]
        [InlineData(-0.001)]
        [InlineData(double.NaN)]
        [InlineData(double.PositiveInfinity)]
        public void RecordHandlerTime_NegativeOrNonFinite_Throws(double milliseconds)
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => new ExceptionStats().RecordHandlerTime(milliseconds));
        }

        [Fact]
        public void Summary_Classification_ReportsWalksAndExactnessOfTheOwnCache()
        {
            var stats = new ExceptionStats(maxWalks: 1);
            bool own;

            stats.OwnCache.Lookup("k", out own);
            ClassificationSummary withinBudget = stats.Summary().Classification;
            stats.OwnCache.Lookup("k", out own);
            ClassificationSummary afterBudget = stats.Summary().Classification;

            Assert.Equal(1, withinBudget.Walks);
            Assert.True(withinBudget.OwnExact);
            Assert.Equal(1, afterBudget.Walks);
            Assert.False(afterBudget.OwnExact);
        }

        [Fact]
        public void OwnCache_DefaultsToTheDefaultWalkBudget()
        {
            var stats = new ExceptionStats();
            bool own;
            for (int i = 0; i < OwnClassificationCache.DefaultMaxWalks; i++)
            {
                Assert.Equal(OwnLookup.Walk, stats.OwnCache.Lookup("k", out own));
            }

            Assert.NotEqual(OwnLookup.Walk, stats.OwnCache.Lookup("k", out own));
        }

        [Theory]
        [InlineData("TestRig.Harness", true)]
        [InlineData("TestRig.SelfTest", true)]
        [InlineData("testrig.harness", true)]
        [InlineData("TestRig", false)]
        [InlineData("TestRigX", false)]
        [InlineData("SmithingSuite.Scenarios", false)]
        [InlineData("", false)]
        [InlineData(null, false)]
        public void IsHarnessAssembly_MatchesTestRigDotPrefixCaseInsensitively(string simpleName, bool expected)
        {
            Assert.Equal(expected, ExceptionStats.IsHarnessAssembly(simpleName));
        }

        [Fact]
        public void RecordFirstChance_NullKey_CountsAsEmptyKey()
        {
            var stats = new ExceptionStats();
            stats.RecordFirstChance(null, own: false);

            Assert.Equal(string.Empty, stats.Summary().Top[0].Key);
        }

        [Fact]
        public void RecordFirstChance_BeyondTrackedKeyCap_StillCountsTotalButNotNewKeys()
        {
            var stats = new ExceptionStats(maxTrackedKeys: 2);
            Record(stats, "a", 1);
            Record(stats, "b", 1);
            Record(stats, "c", 3);
            Record(stats, "a", 1);

            ExceptionSummary summary = stats.Summary();

            Assert.Equal(6, summary.Total);
            Assert.Equal(new[] { "a", "b" }, summary.Top.Select(t => t.Key).ToArray());
            Assert.Equal(2, summary.Top[0].Count);
        }

        [Fact]
        public void Summary_IsASnapshot_NotALiveView()
        {
            var stats = new ExceptionStats();
            Record(stats, "a", 1);
            ExceptionSummary before = stats.Summary();

            Record(stats, "a", 1);

            Assert.Equal(1, before.Total);
            Assert.Equal(1, before.Top[0].Count);
        }

        private static void Record(ExceptionStats stats, string key, int times)
        {
            for (int i = 0; i < times; i++)
            {
                stats.RecordFirstChance(key, own: false);
            }
        }
    }

    public class OwnAssemblyClassifierTests
    {
        [Fact]
        public void IsOwn_EmptyOwnSet_IsAlwaysFalse()
        {
            var classifier = new OwnAssemblyClassifier(new string[0]);

            Assert.True(classifier.IsEmpty);
            Assert.False(classifier.IsOwn(new[] { "CoherentWarAI", "mscorlib" }));
        }

        [Fact]
        public void IsOwn_AnyFrameFromAnOwnAssembly_IsTrue()
        {
            var classifier = new OwnAssemblyClassifier(new[] { "CoherentWarAI" });

            Assert.False(classifier.IsEmpty);
            Assert.True(classifier.IsOwn(new[] { "mscorlib", "TaleWorlds.CampaignSystem", "CoherentWarAI", "TaleWorlds.Engine" }));
        }

        [Fact]
        public void IsOwn_MatchIsCaseInsensitive()
        {
            var classifier = new OwnAssemblyClassifier(new[] { "coherentwarai" });

            Assert.True(classifier.IsOwn(new[] { "CoherentWarAI" }));
        }

        [Fact]
        public void IsOwn_NoFrameFromAnOwnAssembly_IsFalse()
        {
            var classifier = new OwnAssemblyClassifier(new[] { "CoherentWarAI", "SmithingSuite" });

            Assert.False(classifier.IsOwn(new[] { "mscorlib", "TaleWorlds.CampaignSystem", "CoherentWarAI.Tests" }));
        }

        [Fact]
        public void IsOwn_NullOrEmptyFrameNames_AreIgnored()
        {
            var classifier = new OwnAssemblyClassifier(new[] { "A" });

            Assert.False(classifier.IsOwn(new[] { null, string.Empty }));
            Assert.False(classifier.IsOwn(new string[0]));
        }

        [Fact]
        public void Constructor_IgnoresNullAndBlankEntriesAndTrims()
        {
            var classifier = new OwnAssemblyClassifier(new[] { null, " ", "  A  " });

            Assert.False(classifier.IsEmpty);
            Assert.True(classifier.IsOwn(new[] { "a" }));
            Assert.False(classifier.IsOwn(new[] { " " }));
        }
    }
}
