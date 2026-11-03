using System;
using System.Collections.Generic;
using System.Linq;
using Helpers;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.Encounters;
using TaleWorlds.CampaignSystem.Party;
using TaleWorlds.CampaignSystem.Settlements;
using TaleWorlds.Core;
using TestRig.Harness.Fixtures;
using TestRig.Harness.Logic;

namespace TestRig.SelfTest
{
    /// <summary>
    /// The spike for the town and screen fixtures: enter a foreign town, open the trade inventory
    /// without a click, close it with Done, leave the town again, and leave no save file behind.
    /// </summary>
    public sealed class TownScreenScenario : IScenario
    {
        // The Gauntlet screen needs frames of its own before it may be closed (AutoTrader refreshes after 15 ticks).
        private const int ScreenOpenTicks = 30;
        private const int SaveSettleTicks = 60;

        public string Id => "rig.town-screen";

        public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
        {
            Settlement town = TownFixture.FindTown(TownFixture.IsAtPeaceWithPlayer);
            if (town == null)
            {
                throw new InvalidOperationException("no town that is not besieged, has no map event and is not at war with the player");
            }

            string savesBefore = SaveSnapshot();

            try
            {
                foreach (ScenarioStep step in TownFixture.EnterTown(town))
                {
                    yield return step;
                }

                Settlement current = MobileParty.MainParty.CurrentSettlement;
                var menu = Campaign.Current.CurrentMenuContext;
                ctx.Check("menu-town", current == town && TownFixture.IsInTownMenu(),
                    "in " + town.StringId + " on menu 'town'",
                    (current == null ? "no settlement" : current.StringId)
                        + " on menu '" + (menu == null || menu.GameMenu == null ? "none" : menu.GameMenu.StringId) + "'");

                InventoryScreenHelper.OpenScreenAsTrade(town.ItemRoster, town.SettlementComponent);
                ctx.Check("screen-open", ScreenFixture.IsInventoryOpen, "inventory screen open", ScreenFixture.IsInventoryOpen ? "open" : "closed");
                yield return ScenarioStep.Ticks(ScreenOpenTicks);

                foreach (ScenarioStep step in ScreenFixture.CloseInventory(false))
                {
                    yield return step;
                }

                ctx.Check("screen-closed", !ScreenFixture.IsInventoryOpen, "inventory screen closed", ScreenFixture.IsInventoryOpen ? "open" : "closed");

                foreach (ScenarioStep step in TownFixture.LeaveTown())
                {
                    yield return step;
                }

                bool outside = PlayerEncounter.Current == null && MobileParty.MainParty.CurrentSettlement == null;
                ctx.Check("party-outside", outside, "no encounter, no settlement", outside ? "outside" : "still in encounter or settlement");

                // An autosave runs on its own schedule; give it map ticks to show up before comparing.
                yield return ScenarioStep.Ticks(SaveSettleTicks);
                string savesAfter = SaveSnapshot();
                ctx.Check("saves-unchanged", savesAfter == savesBefore, savesBefore, savesAfter);
            }
            finally
            {
                // Timeout or Error can end the scenario with the screen open or the party in the encounter.
                TownFixture.LeaveTownNow();
            }
        }

        // Save file names with their creation time: a rotating autosave (saveauto1..3) keeps its name but gets a new time.
        private static string SaveSnapshot()
        {
            return string.Join("; ", MBSaveLoad.GetSaveFiles()
                .Select(file => file.Name + "@" + file.MetaData.GetCreationTime().Ticks)
                .OrderBy(entry => entry, StringComparer.Ordinal));
        }
    }
}
