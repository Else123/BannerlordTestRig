using System;
using System.Collections.Generic;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Run-wide exception counters for run-result.json. Unlike <see cref="ExceptionLogBudget"/> it
    /// never starts a new window: it covers the whole run. Not thread-safe; the caller serializes.
    /// </summary>
    public sealed class ExceptionStats
    {
        public const int TopCount = 5;

        /// <summary>
        /// Keys embed the exception message, so a message with varying content could create a new
        /// key per exception. Beyond this many distinct keys new keys are counted in the totals only.
        /// </summary>
        public const int DefaultMaxTrackedKeys = 10000;

        private readonly Dictionary<string, int> _counts = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly int _maxTrackedKeys;
        private int _total;
        private int _own;
        private int _unhandled;

        public ExceptionStats(int maxTrackedKeys = DefaultMaxTrackedKeys)
        {
            if (maxTrackedKeys < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(maxTrackedKeys), "Must not be negative.");
            }

            _maxTrackedKeys = maxTrackedKeys;
        }

        /// <summary>Records one first-chance exception; <paramref name="own"/> per <see cref="OwnAssemblyClassifier"/>.</summary>
        public void RecordFirstChance(string key, bool own)
        {
            _total++;
            if (own)
            {
                _own++;
            }

            string safeKey = key ?? string.Empty;
            int previous;
            if (_counts.TryGetValue(safeKey, out previous))
            {
                _counts[safeKey] = previous + 1;
            }
            else if (_counts.Count < _maxTrackedKeys)
            {
                _counts[safeKey] = 1;
            }
        }

        public void RecordUnhandled()
        {
            _unhandled++;
        }

        /// <summary>Snapshot: later records do not change the returned summary.</summary>
        public ExceptionSummary Summary()
        {
            var entries = new List<KeyValuePair<string, int>>(_counts);
            entries.Sort((a, b) =>
            {
                int byCount = b.Value.CompareTo(a.Value);
                return byCount != 0 ? byCount : string.CompareOrdinal(a.Key, b.Key);
            });

            int count = Math.Min(TopCount, entries.Count);
            var top = new ExceptionKeyCount[count];
            for (int i = 0; i < count; i++)
            {
                top[i] = new ExceptionKeyCount(entries[i].Key, entries[i].Value);
            }

            return new ExceptionSummary(_total, _own, _unhandled, top);
        }
    }

    /// <summary>
    /// Decides whether an exception belongs to a mod under test: true when any frame of the
    /// throwing thread's stack comes from one of the configured assemblies (simple names without
    /// ".dll", matched case-insensitively). Immutable, so safe to share across threads.
    /// </summary>
    public sealed class OwnAssemblyClassifier
    {
        private readonly HashSet<string> _own = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        public OwnAssemblyClassifier(IEnumerable<string> ownAssemblies)
        {
            if (ownAssemblies == null)
            {
                throw new ArgumentNullException(nameof(ownAssemblies));
            }

            foreach (string name in ownAssemblies)
            {
                if (!string.IsNullOrWhiteSpace(name))
                {
                    _own.Add(name.Trim());
                }
            }
        }

        /// <summary>No own assemblies configured: every exception is foreign, no stack walk needed.</summary>
        public bool IsEmpty
        {
            get { return _own.Count == 0; }
        }

        /// <param name="frameAssemblyNames">Simple assembly names of the stack frames; null entries are ignored.</param>
        public bool IsOwn(IEnumerable<string> frameAssemblyNames)
        {
            if (frameAssemblyNames == null || _own.Count == 0)
            {
                return false;
            }

            foreach (string name in frameAssemblyNames)
            {
                if (name != null && _own.Contains(name))
                {
                    return true;
                }
            }

            return false;
        }
    }
}
