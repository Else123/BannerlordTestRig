using System.Collections.Generic;
using System.Threading;
using TestRig.Harness.Logic;

namespace TestRig.SelfTest
{
    /// <summary>
    /// Blocks the main thread for good, so the harness stops writing its liveness line and the rig
    /// has to detect the silence and end the game.
    /// </summary>
    public sealed class HangScenario : IScenario
    {
        public string Id => "rig.selftest-hang";

        public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
        {
            ctx.Check("armed", true, "hang armed", "armed");
            Thread.Sleep(Timeout.Infinite);

            yield break;
        }
    }
}
