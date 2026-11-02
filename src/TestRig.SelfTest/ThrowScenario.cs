using System.Collections.Generic;
using TestRig.Harness.Logic;

namespace TestRig.SelfTest
{
    /// <summary>
    /// Arms the module tick to throw (see <see cref="SelfTestSubModule"/>) and then waits. The rig
    /// expects the game to crash; if it does not, the endless wait ends as Timeout, which shows up
    /// in the result instead of a silent pass.
    /// </summary>
    public sealed class ThrowScenario : IScenario
    {
        internal const string ScenarioId = "rig.selftest-throw";

        private const double NeverTrueTimeoutSeconds = 60;

        public string Id => ScenarioId;

        public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
        {
            ctx.Check("armed", true, "throw armed", "armed");
            SelfTestSubModule.ArmThrow();

            yield return ScenarioStep.Until(() => false, NeverTrueTimeoutSeconds, "game crash from the module tick");
        }
    }
}
