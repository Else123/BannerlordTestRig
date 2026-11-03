using System;
using System.Collections.Generic;
using System.Diagnostics;
using Helpers;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.Actions;
using TaleWorlds.CampaignSystem.Encounters;
using TaleWorlds.CampaignSystem.Party;
using TaleWorlds.CampaignSystem.Settlements;
using TaleWorlds.Library;
using TestRig.Harness.Logic;

namespace TestRig.Harness.Fixtures
{
    /// <summary>
    /// Puts the player into a town and back out for scenarios, without moving over the map and without
    /// saving. Methods that need game ticks to pass return steps to <c>yield return</c>
    /// (<c>foreach (ScenarioStep s in ...) yield return s;</c>). A failed precondition throws
    /// <see cref="InvalidOperationException"/>, which ends the scenario as Error (setup problem, not a failed check).
    /// </summary>
    public static class TownFixture
    {
        private const string TownMenuId = "town";
        private const double EnterTimeoutSeconds = 30;
        private const double LeaveTimeoutSeconds = 10;
        private const double HardTimeoutMarginSeconds = 5;
        private const int DeniedStableTicks = 10;

        /// <summary>
        /// The town nearest to the main party that is not besieged, has no map event and satisfies
        /// <paramref name="accept"/> (null accepts all); null when there is none.
        /// </summary>
        public static Settlement FindTown(Predicate<Settlement> accept)
        {
            Settlement best = null;
            float bestDistance = float.MaxValue;
            Vec2 from = MobileParty.MainParty.Position.ToVec2();
            foreach (Settlement settlement in Settlement.All)
            {
                if (!settlement.IsTown || settlement.SiegeEvent != null || settlement.Party.MapEvent != null
                    || (accept != null && !accept(settlement)))
                {
                    continue;
                }

                float distance = from.DistanceSquared(settlement.GatePosition.ToVec2());
                if (distance < bestDistance)
                {
                    best = settlement;
                    bestDistance = distance;
                }
            }

            return best;
        }

        /// <summary>True when the faction of <paramref name="settlement"/> is not at war with the player hero's faction; false without a faction.</summary>
        public static bool IsAtPeaceWithPlayer(Settlement settlement)
        {
            return settlement.MapFaction != null && !FactionManager.IsAtWarAgainstFaction(settlement.MapFaction, Hero.MainHero.MapFaction);
        }

        /// <summary>Makes the player hero the owner of <paramref name="town"/>; throws when the player clan does not own it afterwards.</summary>
        public static void GiveTownToPlayer(Settlement town)
        {
            ChangeOwnerOfSettlementAction.ApplyByDefault(Hero.MainHero, town);
            if (town.OwnerClan != Clan.PlayerClan)
            {
                throw new InvalidOperationException("GiveTownToPlayer: " + town.StringId + " is owned by "
                    + (town.OwnerClan == null ? "nobody" : town.OwnerClan.StringId) + " after the transfer");
            }
        }

        /// <summary>
        /// Starts the settlement encounter of the main party with <paramref name="town"/> (the party is not
        /// moved) and waits up to 30 s for the "town" menu. Throws <see cref="InvalidOperationException"/>
        /// when the player is already in an encounter, and, as a setup error, when the town denies access
        /// (war, crime rating): the game then stays on "town_outside", "naval_town_outside" or
        /// "town_inside_criminal" (vanilla 1.4.8 game_menu_town_outside_on_init switches to "town" only on
        /// full direct access). Denial counts once such a menu was current for 10 consecutive ticks; the
        /// throw happens inside the iterator when the runner resumes it, so the scenario ends as Error.
        /// </summary>
        public static IEnumerable<ScenarioStep> EnterTown(Settlement town)
        {
            if (PlayerEncounter.Current != null)
            {
                throw new InvalidOperationException("EnterTown: the player is already in an encounter");
            }

            EncounterManager.StartSettlementEncounter(MobileParty.MainParty, town);

            // The condition is evaluated once per tick, so the counter counts ticks.
            int deniedTicks = 0;
            yield return ScenarioStep.Until(
                () =>
                {
                    if (IsInTownMenu())
                    {
                        return true;
                    }

                    deniedTicks = IsInAccessDeniedMenu() ? deniedTicks + 1 : 0;
                    return deniedTicks >= DeniedStableTicks;
                },
                EnterTimeoutSeconds,
                "menu '" + TownMenuId + "' or access denied");

            if (!IsInTownMenu())
            {
                throw new InvalidOperationException("EnterTown: " + town.StringId + " denies access, the game stays on menu '"
                    + CurrentMenuId() + "'");
            }
        }

        /// <summary>
        /// Leaves the settlement like vanilla's town_leave option (gate position, LeaveSettlement, Finish,
        /// hold) but without its SignalAutoSave, parks the party and waits for the encounter to end. The
        /// wait is soft: after 10 s it returns without failing the scenario, so the caller checks the
        /// outcome itself: <c>PlayerEncounter.Current == null &amp;&amp; MobileParty.MainParty.CurrentSettlement == null</c>.
        /// Throws when the main party is not in a settlement.
        /// </summary>
        public static IEnumerable<ScenarioStep> LeaveTown()
        {
            MobileParty party = MobileParty.MainParty;
            if (party.CurrentSettlement == null)
            {
                throw new InvalidOperationException("LeaveTown: the main party is not in a settlement");
            }

            ExitSettlementEncounter(party);
            Stopwatch softDeadline = Stopwatch.StartNew();
            yield return ScenarioStep.Until(
                () => IsOutside() || softDeadline.Elapsed.TotalSeconds >= LeaveTimeoutSeconds,
                LeaveTimeoutSeconds + HardTimeoutMarginSeconds,
                "player outside the settlement");
        }

        /// <summary>
        /// Synchronous cleanup for a scenario's finally block: closes an open inventory screen like Cancel,
        /// then ends a running player encounter like <see cref="LeaveTown"/> (without waiting, without
        /// autosave) and parks the party. A no-op when nothing is open; never yields and never throws.
        /// Failures are swallowed on purpose: the fixtures have no logger, and a cleanup error must not
        /// hide the scenario's own outcome.
        /// </summary>
        public static void LeaveTownNow()
        {
            try
            {
                if (ScreenFixture.IsInventoryOpen)
                {
                    InventoryScreenHelper.CloseScreen(true);
                }

                if (PlayerEncounter.Current != null)
                {
                    ExitSettlementEncounter(MobileParty.MainParty);
                }
            }
            catch (Exception)
            {
                // Best effort, see the summary.
            }
        }

        // Shared by LeaveTown and LeaveTownNow. Without a current settlement (access denied, still on the
        // outside menu) there is nothing to leave, the encounter is only finished.
        private static void ExitSettlementEncounter(MobileParty party)
        {
            Settlement settlement = party.CurrentSettlement;
            if (settlement != null)
            {
                party.Position = settlement.GatePosition;
                PlayerEncounter.LeaveSettlement();
            }

            PlayerEncounter.Finish();
            party.SetMoveModeHold();
            Campaign.Current.GetCampaignBehavior<HarnessCampaignBehavior>()?.Park();
        }

        private static bool IsOutside()
        {
            return PlayerEncounter.Current == null && MobileParty.MainParty.CurrentSettlement == null;
        }

        private static string CurrentMenuId()
        {
            var context = Campaign.Current.CurrentMenuContext;
            return context == null || context.GameMenu == null ? null : context.GameMenu.StringId;
        }

        /// <summary>True while the current game menu is the town menu ('town').</summary>
        public static bool IsInTownMenu()
        {
            return CurrentMenuId() == TownMenuId;
        }

        private static bool IsInAccessDeniedMenu()
        {
            string id = CurrentMenuId();
            return id == "town_outside" || id == "naval_town_outside" || id == "town_inside_criminal";
        }
    }
}
