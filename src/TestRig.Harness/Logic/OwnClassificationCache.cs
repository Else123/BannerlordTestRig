using System;
using System.Collections.Generic;

namespace TestRig.Harness.Logic
{
    /// <summary>Answer of <see cref="OwnClassificationCache.Lookup"/>.</summary>
    public enum OwnLookup
    {
        /// <summary>The key was classified before; the cached answer applies, no stack walk.</summary>
        Cached,

        /// <summary>Unknown key, a walk was granted: walk the stack and <see cref="OwnClassificationCache.Store"/> the result.</summary>
        Walk,

        /// <summary>Unknown key and the walk budget is spent: count the exception as not own.</summary>
        Unknown,
    }

    /// <summary>
    /// Bounds the cost of the own-assembly stack walk on first-chance exceptions. The game can throw
    /// thousands of them, so each exception key (type, message and throw site) is classified by one
    /// stack walk at its first occurrence and the answer reused for every repeat; at most
    /// <c>maxWalks</c> walks happen per run, which also caps the number of cached keys.
    /// <para>
    /// This makes "own" an estimate in two ways: a repeat inherits the classification of the first
    /// occurrence of its key even if it was reached through a different call chain, and keys first
    /// seen after the walk budget is spent count as not own. Not thread-safe; the caller serializes.
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
        }

        /// <summary>Stack walks granted so far, stored or not.</summary>
        public int Walks { get; private set; }

        /// <summary>
        /// Classification of <paramref name="key"/>: cached, or a granted walk (counted now, so the
        /// budget holds even when two threads miss the same key before either stores it), or unknown.
        /// <paramref name="own"/> is the cached answer, otherwise false.
        /// </summary>
        public OwnLookup Lookup(string key, out bool own)
        {
            if (_byKey.TryGetValue(key ?? string.Empty, out own))
            {
                return OwnLookup.Cached;
            }

            own = false;
            if (Walks >= _maxWalks)
            {
                return OwnLookup.Unknown;
            }

            Walks++;
            return OwnLookup.Walk;
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
