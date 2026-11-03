using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using TestRig.Harness.Logic;

namespace TestRig.SelfTest
{
    /// <summary>
    /// Exception storm for the harness' first-chance classification (R2): throws and catches
    /// <see cref="ExceptionCount"/> exceptions in a single tick, each from <see cref="Depth"/> frames
    /// deep. R2 is judged from run-result.json (<c>exceptions.classification</c>: <c>walkMs / walks</c>
    /// per walked exception, <c>(handlerMs - walkMs) / (total - walks)</c> per other exception), which
    /// times the harness handler alone. The times this scenario logs are end-to-end upper bounds per
    /// exception: they include the throw, the unwind of <see cref="Depth"/> frames, the catch and the
    /// harness' log write. They are split into the first <see cref="FirstCount"/> exceptions and the rest;
    /// the first part matches the walked ones only when no earlier exception of the run spent part of
    /// the walk budget, so the split is indicative, not exact.
    /// The throw site lies in this assembly: with TestRig.SelfTest in ownAssemblies every exception
    /// counts as own (own wins over the harness classification of "TestRig.*" throw sites).
    /// The message is constant, so all exceptions share one key.
    /// </summary>
    public sealed class ExceptionStormScenario : IScenario
    {
        internal const string ScenarioId = "rig.selftest-exception-storm";

        internal const int ExceptionCount = 10000;

        // Size of the first timing bucket: the harness' default walk budget (OwnClassificationCache.DefaultMaxWalks).
        internal const int FirstCount = OwnClassificationCache.DefaultMaxWalks;

        internal const int Depth = 50;

        public string Id => ScenarioId;

        public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
        {
            int caught = 0;
            long firstTicks = 0;
            long restTicks = 0;

            for (int i = 0; i < ExceptionCount; i++)
            {
                long started = Stopwatch.GetTimestamp();
                try
                {
                    ThrowFromDepth(Depth);
                }
                catch (InvalidOperationException)
                {
                    caught++;
                }

                long elapsed = Stopwatch.GetTimestamp() - started;
                if (i < FirstCount)
                {
                    firstTicks += elapsed;
                }
                else
                {
                    restTicks += elapsed;
                }
            }

            ctx.Log("first " + FirstCount + ": <= " + MicrosecondsPer(firstTicks, FirstCount)
                + " us/exception (upper bound incl. throw/unwind/catch/log; walked if the walk budget was untouched)");
            ctx.Log("rest " + (ExceptionCount - FirstCount) + ": <= " + MicrosecondsPer(restTicks, ExceptionCount - FirstCount)
                + " us/exception (upper bound incl. throw/unwind/catch/log)");
            ctx.Check("caught", caught == ExceptionCount, ExceptionCount.ToString(), caught.ToString());

            yield break;
        }

        private static string MicrosecondsPer(long ticks, int count)
        {
            double microseconds = ticks * 1000000.0 / Stopwatch.Frequency / count;
            return microseconds.ToString("F1", System.Globalization.CultureInfo.InvariantCulture);
        }

        // NoInlining keeps the frames real; the return value after the call stops tail-call elimination.
        [MethodImpl(MethodImplOptions.NoInlining)]
        private static int ThrowFromDepth(int remaining)
        {
            if (remaining <= 0)
            {
                throw new InvalidOperationException(ScenarioId);
            }

            return ThrowFromDepth(remaining - 1) + 1;
        }
    }
}
