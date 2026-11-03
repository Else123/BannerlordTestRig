using System;
using System.Collections.Generic;
using System.Diagnostics;
using Helpers;
using TaleWorlds.CampaignSystem.GameState;
using TaleWorlds.Core;
using TestRig.Harness.Logic;

namespace TestRig.Harness.Fixtures
{
    /// <summary>
    /// Waiting for and closing the inventory screen from a scenario. Methods that need game ticks to
    /// pass return steps to <c>yield return</c> (<c>foreach (ScenarioStep s in ...) yield return s;</c>).
    /// </summary>
    public static class ScreenFixture
    {
        private const double CloseTimeoutSeconds = 10;
        private const double HardTimeoutMarginSeconds = 5;

        /// <summary>
        /// True while the active game state is an <see cref="InventoryState"/>. Safe to call at any time;
        /// <c>InventoryScreenHelper.GetActiveInventoryState</c> asserts when no inventory is open.
        /// </summary>
        public static bool IsInventoryOpen
        {
            get { return GameStateManager.Current != null && GameStateManager.Current.ActiveState is InventoryState; }
        }

        /// <summary>
        /// Closes the open inventory like the Done (<paramref name="cancel"/> false) or Cancel (true)
        /// button, then waits up to 10 s for the screen to be gone. The wait is soft: when the screen
        /// refuses to close (gold missing, item preview running) this returns after 10 s without failing
        /// the scenario, so the caller checks <see cref="IsInventoryOpen"/> itself. Throws when none is open.
        /// </summary>
        public static IEnumerable<ScenarioStep> CloseInventory(bool cancel)
        {
            if (!IsInventoryOpen)
            {
                throw new InvalidOperationException("CloseInventory: no inventory screen is open");
            }

            InventoryScreenHelper.CloseScreen(cancel);
            Stopwatch softDeadline = Stopwatch.StartNew();
            yield return ScenarioStep.Until(
                () => !IsInventoryOpen || softDeadline.Elapsed.TotalSeconds >= CloseTimeoutSeconds,
                CloseTimeoutSeconds + HardTimeoutMarginSeconds,
                "inventory screen closed");
        }
    }
}
