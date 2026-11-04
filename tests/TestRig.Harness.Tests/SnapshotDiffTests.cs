using System;
using System.Collections.Generic;
using TestRig.Harness.Logic;
using Xunit;

namespace TestRig.Harness.Tests
{
    public class SnapshotDiffTests
    {
        [Fact]
        public void CountDelta_ReportsGainsLossesAndKeysOnOnlyOneSide()
        {
            var before = new Dictionary<string, int> { ["wool"] = 5, ["iron"] = 3, ["grain"] = 2 };
            var after = new Dictionary<string, int> { ["wool"] = 2, ["iron"] = 3, ["salt"] = 4 };

            IReadOnlyDictionary<string, int> delta = SnapshotDiff.CountDelta(before, after);

            Assert.Equal(3, delta.Count);
            Assert.Equal(-3, delta["wool"]);
            Assert.Equal(-2, delta["grain"]);
            Assert.Equal(4, delta["salt"]);
        }

        [Fact]
        public void CountDelta_EqualSnapshots_AreEmpty()
        {
            var counts = new Dictionary<string, int> { ["wool"] = 5 };

            Assert.Empty(SnapshotDiff.CountDelta(counts, new Dictionary<string, int>(counts)));
        }

        [Fact]
        public void CountDelta_KeysAreCaseSensitive()
        {
            var before = new Dictionary<string, int> { ["Wool"] = 1 };
            var after = new Dictionary<string, int> { ["wool"] = 1 };

            Assert.Equal(2, SnapshotDiff.CountDelta(before, after).Count);
        }

        [Fact]
        public void CountDelta_NullArgument_Throws()
        {
            var empty = new Dictionary<string, int>();

            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.CountDelta(null, empty));
            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.CountDelta(empty, null));
        }

        [Fact]
        public void ValueChanges_ListsChangedAddedAndRemovedKeysSortedByKey()
        {
            var before = new Dictionary<string, string> { ["b/battle/0"] = "sword", ["a/civilian/5"] = "tunic", ["c/battle/1"] = "bow" };
            var after = new Dictionary<string, string> { ["b/battle/0"] = "axe", ["a/civilian/5"] = "tunic", ["d/battle/2"] = "spear" };

            IReadOnlyList<string> changes = SnapshotDiff.ValueChanges(before, after);

            Assert.Equal(
                new[] { "b/battle/0: sword -> axe", "c/battle/1: bow -> (none)", "d/battle/2: (none) -> spear" },
                changes);
        }

        [Fact]
        public void ValueChanges_EqualMaps_AreEmpty()
        {
            var map = new Dictionary<string, string> { ["a"] = "x" };

            Assert.Empty(SnapshotDiff.ValueChanges(map, new Dictionary<string, string>(map)));
        }

        [Fact]
        public void ValueChanges_NullArgument_Throws()
        {
            var empty = new Dictionary<string, string>();

            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.ValueChanges(null, empty));
            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.ValueChanges(empty, null));
        }

        private static IReadOnlyDictionary<string, int> Counts(params object[] keyValues)
        {
            var map = new Dictionary<string, int>();
            for (int i = 0; i < keyValues.Length; i += 2)
            {
                map[(string)keyValues[i]] = (int)keyValues[i + 1];
            }

            return map;
        }

        [Fact]
        public void EquipmentCounts_CountsDuplicatesAndSkipsEmptyValues()
        {
            var equipment = new Dictionary<string, string>
            {
                ["Head"] = "helm",
                ["Body"] = "mail",
                ["Ring1"] = "ring",
                ["Ring2"] = "ring",
                ["Cape"] = "",
                ["Gloves"] = null,
            };

            IReadOnlyDictionary<string, int> counts = SnapshotDiff.EquipmentCounts(equipment);

            Assert.Equal(3, counts.Count);
            Assert.Equal(1, counts["helm"]);
            Assert.Equal(1, counts["mail"]);
            Assert.Equal(2, counts["ring"]);
        }

        [Fact]
        public void EquipmentCounts_EmptyMap_IsEmpty()
        {
            Assert.Empty(SnapshotDiff.EquipmentCounts(new Dictionary<string, string>()));
        }

        [Fact]
        public void EquipmentCounts_NullArgument_Throws()
        {
            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.EquipmentCounts(null));
        }

        [Fact]
        public void ConservationDelta_ArmorMovedFromRosterToSlot_BalancesToEmpty()
        {
            var before = new[] { Counts("mail", 1), Counts() };
            var after = new[] { Counts(), Counts("mail", 1) };

            Assert.Empty(SnapshotDiff.ConservationDelta(before, after));
        }

        [Fact]
        public void ConservationDelta_Duplication_GivesPlusOne()
        {
            var before = new[] { Counts("mail", 1), Counts() };
            var after = new[] { Counts("mail", 1), Counts("mail", 1) };

            IReadOnlyDictionary<string, int> delta = SnapshotDiff.ConservationDelta(before, after);

            Assert.Single(delta);
            Assert.Equal(1, delta["mail"]);
        }

        [Fact]
        public void ConservationDelta_Loss_GivesMinusOne()
        {
            var before = new[] { Counts("mail", 1), Counts("helm", 1) };
            var after = new[] { Counts(), Counts("helm", 1) };

            IReadOnlyDictionary<string, int> delta = SnapshotDiff.ConservationDelta(before, after);

            Assert.Single(delta);
            Assert.Equal(-1, delta["mail"]);
        }

        [Fact]
        public void ConservationDelta_SwapWithModifierKeys_ReportsBothKeys()
        {
            var before = new[] { Counts("mail#fine", 1), Counts("mail", 1) };
            var after = new[] { Counts("mail", 2), Counts() };

            IReadOnlyDictionary<string, int> delta = SnapshotDiff.ConservationDelta(before, after);

            Assert.Equal(2, delta.Count);
            Assert.Equal(-1, delta["mail#fine"]);
            Assert.Equal(1, delta["mail"]);
        }

        [Fact]
        public void ConservationDelta_EmptyMapsAndSequences_AreEmpty()
        {
            Assert.Empty(SnapshotDiff.ConservationDelta(new IReadOnlyDictionary<string, int>[0], new IReadOnlyDictionary<string, int>[0]));
            Assert.Empty(SnapshotDiff.ConservationDelta(new[] { Counts() }, new[] { Counts(), Counts() }));
        }

        [Fact]
        public void ConservationDelta_NullArgumentOrElement_Throws()
        {
            var ok = new[] { Counts("a", 1) };
            var withNull = new IReadOnlyDictionary<string, int>[] { Counts("a", 1), null };

            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.ConservationDelta(null, ok));
            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.ConservationDelta(ok, null));
            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.ConservationDelta(withNull, ok));
            Assert.Throws<ArgumentNullException>(() => SnapshotDiff.ConservationDelta(ok, withNull));
        }
    }
}
