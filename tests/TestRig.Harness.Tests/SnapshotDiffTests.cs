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
    }
}
