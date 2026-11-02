using System;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Timing of the liveness line: due once per interval of real time, the first one an interval
    /// after the start. The caller owns the clock and passes the current seconds in, so this stays
    /// engine-free. A late tick beats once and restarts the window; beats are never queued up.
    /// </summary>
    public sealed class AliveClock
    {
        private readonly double _intervalSeconds;
        private double _lastBeatSeconds;

        public AliveClock(double intervalSeconds, double startSeconds)
        {
            if (intervalSeconds <= 0)
            {
                throw new ArgumentOutOfRangeException(nameof(intervalSeconds), intervalSeconds, "must be > 0");
            }

            _intervalSeconds = intervalSeconds;
            _lastBeatSeconds = startSeconds;
        }

        /// <summary>True (and the window restarts) when a full interval has passed since the last beat or the start.</summary>
        public bool TryBeat(double nowSeconds)
        {
            if (nowSeconds - _lastBeatSeconds < _intervalSeconds)
            {
                return false;
            }

            _lastBeatSeconds = nowSeconds;
            return true;
        }
    }
}
