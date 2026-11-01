using System;
using System.Collections.Generic;

namespace TestRig.Harness.Logic
{
    /// <summary>How much of one observed exception goes to the harness log.</summary>
    public enum ExceptionLogDecision
    {
        /// <summary>First occurrence of this key: log message and stack trace.</summary>
        Full,

        /// <summary>A repeat within the per-key allowance: log a one-line marker.</summary>
        Short,

        /// <summary>Budget exhausted: count it, write nothing.</summary>
        Drop,
    }

    /// <summary>
    /// Bounds the first-chance exception trail in harness.log. The game throws and handles
    /// exceptions routinely (asset probing, background prefab compilation), so every exception
    /// is counted but only distinct ones are logged in full, repeats only briefly, and the whole
    /// trail is capped. The exception that kills the process is then still the last line of the
    /// log - unless the budget is exhausted, which the caller avoids by starting a new window
    /// at the interesting moment (the campaign map). Not thread-safe; the caller serializes.
    /// </summary>
    public sealed class ExceptionLogBudget
    {
        private readonly Dictionary<string, int> _occurrences = new Dictionary<string, int>(StringComparer.Ordinal);
        private readonly int _maxDistinctFull;
        private readonly int _repeatsPerKey;
        private readonly int _maxLines;
        private int _fullCount;
        private int _lines;

        public ExceptionLogBudget(int maxDistinctFull, int repeatsPerKey, int maxLines)
        {
            if (maxDistinctFull < 0 || repeatsPerKey < 0 || maxLines < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(maxDistinctFull), "Budget limits must not be negative.");
            }

            _maxDistinctFull = maxDistinctFull;
            _repeatsPerKey = repeatsPerKey;
            _maxLines = maxLines;
        }

        /// <summary>Exceptions observed in the current window, logged or not.</summary>
        public int Observed { get; private set; }

        /// <summary>
        /// Records one exception and says how much of it to log. <paramref name="occurrence"/> is
        /// its 1-based count for this key in the current window.
        /// </summary>
        public ExceptionLogDecision Next(string key, out int occurrence)
        {
            Observed++;
            string safeKey = key ?? string.Empty;

            int previous;
            _occurrences.TryGetValue(safeKey, out previous);
            occurrence = previous + 1;
            _occurrences[safeKey] = occurrence;

            if (_lines >= _maxLines)
            {
                return ExceptionLogDecision.Drop;
            }

            ExceptionLogDecision decision;
            if (occurrence == 1)
            {
                if (_fullCount >= _maxDistinctFull)
                {
                    return ExceptionLogDecision.Drop;
                }

                _fullCount++;
                decision = ExceptionLogDecision.Full;
            }
            else if (occurrence - 1 <= _repeatsPerKey)
            {
                decision = ExceptionLogDecision.Short;
            }
            else
            {
                return ExceptionLogDecision.Drop;
            }

            _lines++;
            return decision;
        }

        /// <summary>Forgets all keys and counts, so the next window logs from scratch.</summary>
        public void StartWindow()
        {
            _occurrences.Clear();
            _fullCount = 0;
            _lines = 0;
            Observed = 0;
        }
    }
}
