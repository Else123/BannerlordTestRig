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
                playerMapEvents: 0,
                modules: new[] { new ModuleEntry("Native", "v1.4.8"), new ModuleEntry("SandBox", "v1.4.8") },
                exceptions: new ExceptionSummary(7, 2, 1, new[] { new ExceptionKeyCount("k1", 3), new ExceptionKeyCount("k2", 1) }),
                scenarios: new[] { new ScenarioResult("soak", ScenarioStatus.Passed, 25) },
                checks: new[] { new CheckResult("daysReached", ">= 1", "1", true) });
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
                "    \"unhandled\": 1,\n" +
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
                        "realSeconds", "gameDaysPerRealMinute", "playerMapEvents", "modules", "exceptions",
                        "scenarios", "checks",
                    },
                    names);
            }
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
                "  \"playerMapEvents\": null,\n" +
                "  \"modules\": [],\n" +
                "  \"exceptions\": {\n" +
                "    \"total\": 0,\n" +
                "    \"own\": 0,\n" +
                "    \"unhandled\": 0,\n" +
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
                RunStatus.Aborted, hostile, 1, hostile, 1, 0, 1, 0, 0,
                new[] { new ModuleEntry(hostile, hostile) },
                new ExceptionSummary(1, 0, 0, new[] { new ExceptionKeyCount(hostile, 1) }),
                new[] { new ScenarioResult(hostile, ScenarioStatus.Error, null) },
                new[] { new CheckResult(hostile, hostile, hostile, false) });

            using (JsonDocument doc = JsonDocument.Parse(RunResultWriter.Write(result)))
            {
                JsonElement root = doc.RootElement;
                Assert.Equal(hostile, root.GetProperty("reason").GetString());
                Assert.Equal(hostile, root.GetProperty("mode").GetString());
                Assert.Equal(hostile, root.GetProperty("modules")[0].GetProperty("version").GetString());
                Assert.Equal(hostile, root.GetProperty("exceptions").GetProperty("top")[0].GetProperty("key").GetString());
                Assert.Equal(hostile, root.GetProperty("checks")[0].GetProperty("actual").GetString());
                Assert.Equal(JsonValueKind.False, root.GetProperty("checks")[0].GetProperty("passed").ValueKind);
            }
        }

        [Fact]
        public void Write_NullStrings_AreWrittenAsJsonNull()
        {
            var result = new RunResult(
                RunStatus.Aborted, null, null, null, null, null, null, null, null,
                NoModules, new ExceptionSummary(0, 0, 0, new ExceptionKeyCount[0]),
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
                RunStatus.Running, "", 1, "NoDlc", 1, 0, 0, 0, 0,
                NoModules, new ExceptionSummary(0, 0, 0, new ExceptionKeyCount[0]),
                new ScenarioResult[0], new CheckResult[0]);

            Assert.Contains("\"status\": \"Running\",", RunResultWriter.Write(result));
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
        public void Summary_Empty_IsAllZeros()
        {
            ExceptionSummary summary = new ExceptionStats().Summary();

            Assert.Equal(0, summary.Total);
            Assert.Equal(0, summary.Own);
            Assert.Equal(0, summary.Unhandled);
            Assert.Empty(summary.Top);
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
