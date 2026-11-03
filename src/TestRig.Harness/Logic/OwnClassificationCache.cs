using System;
using System.Collections.Generic;

namespace TestRig.Harness.Logic
{
    /// <summary>Answer of <see cref="OwnClassificationCache.Lookup"/>.</summary>
    public enum OwnLookup
    {
        /// <summary>Walk budget spent, the key was classified before: the cached answer applies, no stack walk.</summary>
        Cached,

        /// <summary>A walk was granted: walk the stack and <see cref="OwnClassificationCache.Store"/> the result.</summary>
        Walk,

        /// <summary>Walk budget spent and the key is unknown: count the exception as not own.</summary>
        Unknown,
    }

    /// <summary>
    /// Bounds the cost of the own-assembly stack walk on first-chance exceptions. Every exception is
    /// classified by its own stack walk until <c>maxWalks</c> walks are spent (F-S6-4); after that
    /// the cache answers per exception key (type and throw site, see <see cref="ExceptionKey.Own"/>)
    /// with the first stored walk result for that key. The game can throw thousands of exceptions,
    /// so the budget caps both the walk cost and the number of cached keys.
    /// <para>
    /// Within the budget "own" is exact. After it, "own" is an estimate (<see cref="OwnExact"/> turns
    /// false): a repeat inherits the classification of the first walked occurrence of its key even if
    /// it was reached through a different call chain (too high or too low), and keys never walked
    /// count as not own (too low). A failed walk (<see cref="MarkInexact"/>) also counts as not own
    /// and makes "own" an estimate. Not thread-safe; the caller serializes.
    /// </para>
    /// </summary>
    public sealed class OwnClassificationCache
    {
        public const int DefaultMaxWalks = 1000;

        private readonly Dictionary<string, bool> _byKey = new Dictionary<string, bool>(StringComparer.Ordinal);
        private readonly int _maxWalks;

        public OwnClassificationCache(int maxWalks = DefaultMaxWalks)
        {
            if (maxWalks < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(maxWalks), "Must not be negative.");
            }

            _maxWalks = maxWalks;
            OwnExact = true;
        }

        /// <summary>Stack walks granted so far, stored or not.</summary>
        public int Walks { get; private set; }

        /// <summary>
        /// True while every lookup was granted a walk and no walk failed; false from the first lookup
        /// after the budget or the first <see cref="MarkInexact"/>.
        /// </summary>
        public bool OwnExact { get; private set; }

        /// <summary>A granted walk could not classify (the exception counts as not own): "own" is no longer exact.</summary>
        public void MarkInexact()
        {
            OwnExact = false;
        }

        /// <summary>
        /// Classification of one exception with <paramref name="key"/>: a granted walk while the budget
        /// lasts (counted now, so the budget holds even when two threads look up before either stores),
        /// afterwards the cached answer or unknown. <paramref name="own"/> is the cached answer, otherwise false.
        /// </summary>
        public OwnLookup Lookup(string key, out bool own)
        {
            if (Walks < _maxWalks)
            {
                Walks++;
                own = false;
                return OwnLookup.Walk;
            }

            OwnExact = false;
            if (_byKey.TryGetValue(key ?? string.Empty, out own))
            {
                return OwnLookup.Cached;
            }

            own = false;
            return OwnLookup.Unknown;
        }

        /// <summary>Caches the result of a granted walk; the first stored answer for a key wins.</summary>
        public void Store(string key, bool own)
        {
            string safeKey = key ?? string.Empty;
            if (!_byKey.ContainsKey(safeKey))
            {
                _byKey[safeKey] = own;
            }
        }
    }
}
