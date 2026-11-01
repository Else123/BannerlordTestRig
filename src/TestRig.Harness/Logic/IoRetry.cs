using System;
using System.IO;

namespace TestRig.Harness.Logic
{
    /// <summary>
    /// Retries a file operation that can fail transiently while another process (the agent reading
    /// run-result.json, a virus scanner) holds the file open. Retried are <see cref="IOException"/>
    /// with its subclasses and <see cref="UnauthorizedAccessException"/>, which Windows raises for a
    /// target that is pending delete or held by a scanner (ERROR_ACCESS_DENIED); any other exception
    /// propagates on the first attempt. The last failure propagates once all attempts are spent.
    /// </summary>
    public static class IoRetry
    {
        /// <param name="attempts">Total attempts, at least 1.</param>
        /// <param name="delayMilliseconds">Wait between two attempts.</param>
        /// <param name="sleep">Waits the given milliseconds (Thread.Sleep in production).</param>
        public static void Run(Action action, int attempts, int delayMilliseconds, Action<int> sleep)
        {
            if (action == null)
            {
                throw new ArgumentNullException(nameof(action));
            }

            if (sleep == null)
            {
                throw new ArgumentNullException(nameof(sleep));
            }

            if (attempts < 1)
            {
                throw new ArgumentOutOfRangeException(nameof(attempts), "At least one attempt is required.");
            }

            if (delayMilliseconds < 0)
            {
                throw new ArgumentOutOfRangeException(nameof(delayMilliseconds), "Must not be negative.");
            }

            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    action();
                    return;
                }
                catch (Exception e) when (attempt < attempts && IsTransient(e))
                {
                    sleep(delayMilliseconds);
                }
            }
        }

        private static bool IsTransient(Exception e)
        {
            return e is IOException || e is UnauthorizedAccessException;
        }
    }
}
