using System;
using TaleWorlds.MountAndBlade;

namespace TestRig.SelfTest
{
    /// <summary>
    /// Throws from the module's own application tick once <c>rig.selftest-throw</c> has armed it.
    /// The throw has to live here: the engine calls every submodule's OnApplicationTick without a
    /// try/catch, exactly as it would for a real mod bug, while the harness runs scenarios inside
    /// its own try/catch and would swallow it. Without the arming flag this module does nothing.
    /// </summary>
    public class SelfTestSubModule : MBSubModuleBase
    {
        // Written by the scenario and read by the tick, both on the main thread.
        private static bool _throwArmed;

        internal static void ArmThrow()
        {
            _throwArmed = true;
        }

        protected override void OnApplicationTick(float dt)
        {
            base.OnApplicationTick(dt);

            if (_throwArmed)
            {
                throw new InvalidOperationException(ThrowScenario.ScenarioId);
            }
        }
    }
}
