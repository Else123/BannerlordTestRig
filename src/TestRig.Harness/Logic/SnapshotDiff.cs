using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Engine-free comparison of two inventory snapshots (see <c>InventorySnapshot</c>): item counts per
    /// key and plain key-to-value maps such as equipment slots.
    /// </summary>
    public static class SnapshotDiff
    {
        /// <summary>
        /// Per key, <c>after - before</c>; a key missing on one side counts as 0. Keys whose count did
        /// not change are left out. Ordinal key comparison.
        /// </summary>
        public static IReadOnlyDictionary<string, int> CountDelta(
            IReadOnlyDictionary<string, int> before, IReadOnlyDictionary<string, int> after)
        {
            if (before == null)
            {
                throw new ArgumentNullException(nameof(before));
            }

            if (after == null)
            {
                throw new ArgumentNullException(nameof(after));
            }

            var delta = new Dictionary<string, int>(StringComparer.Ordinal);
            foreach (string key in before.Keys.Union(after.Keys, StringComparer.Ordinal))
            {
                int b;
                int a;
                before.TryGetValue(key, out b);
                after.TryGetValue(key, out a);
                if (a != b)
                {
                    delta[key] = a - b;
                }
            }

            return delta;
        }

        /// <summary>
        /// One line "key: before -> after" per key whose value differs; a key missing on one side is
        /// shown as "(none)". Sorted by key (ordinal), empty when the maps are equal.
        /// </summary>
        public static IReadOnlyList<string> ValueChanges(
            IReadOnlyDictionary<string, string> before, IReadOnlyDictionary<string, string> after)
        {
            if (before == null)
            {
                throw new ArgumentNullException(nameof(before));
            }

            if (after == null)
            {
                throw new ArgumentNullException(nameof(after));
            }

            var lines = new List<string>();
            foreach (string key in before.Keys.Union(after.Keys, StringComparer.Ordinal).OrderBy(k => k, StringComparer.Ordinal))
            {
                string b;
                string a;
                if (!before.TryGetValue(key, out b))
                {
                    b = "(none)";
                }

                if (!after.TryGetValue(key, out a))
                {
                    a = "(none)";
                }

                if (!string.Equals(a, b, StringComparison.Ordinal))
                {
                    lines.Add(string.Format(CultureInfo.InvariantCulture, "{0}: {1} -> {2}", key, b, a));
                }
            }

            return lines;
        }
    }
}
