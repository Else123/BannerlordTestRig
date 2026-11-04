using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using AutoTrader;
using CompanionSuite.Core;
using CompanionSuite.Diagnostics;
using CompanionSuite.Integration;
using CompanionSuite.Persistence;
using CompanionSuite.UI;
using Helpers;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.Actions;
using TaleWorlds.CampaignSystem.Encounters;
using TaleWorlds.CampaignSystem.GameMenus;
using TaleWorlds.CampaignSystem.GameState;
using TaleWorlds.CampaignSystem.Party;
using TaleWorlds.CampaignSystem.Roster;
using TaleWorlds.CampaignSystem.Settlements;
using TaleWorlds.Core;
using TaleWorlds.ObjectSystem;
using TestRig.Harness.Fixtures;
using TestRig.Harness.Logic;
// Vanilla also defines an ItemCategory (trade goods); alias the suite's to keep both usable here.
using SuiteItemCategory = CompanionSuite.Equip.ItemCategory;

namespace CrossMod.Scenarios
{
    /// <summary>
    /// X-1 <c>crossmod.trade-with-autoequip.done</c>: the Done variant of <see cref="TradeWithAutoEquipScenario"/>.
    /// </summary>
    public sealed class TradeWithAutoEquipDoneScenario : TradeWithAutoEquipScenario
    {
        public TradeWithAutoEquipDoneScenario()
            : base(false)
        {
        }
    }

    /// <summary>
    /// X-1 <c>crossmod.trade-with-autoequip.cancel</c>: the Cancel variant of <see cref="TradeWithAutoEquipScenario"/>.
    /// </summary>
    public sealed class TradeWithAutoEquipCancelScenario : TradeWithAutoEquipScenario
    {
        public TradeWithAutoEquipCancelScenario()
            : base(true)
        {
        }
    }

    /// <summary>
    /// X-1: one AutoTrader town trade (live "autotrader_town" option) while CompanionSuite's
    /// inventory-open listener auto-equips a companion on the same trade screen. Both mods move items
    /// out of the main party's roster, so the invariant is item conservation over all containers: per
    /// item key, party + town + stash + equipped slots stay constant from before to the open screen and
    /// from before to after the close. Done keeps the trade (hero gold change mirrors the town's) and the
    /// new body armor; Cancel resets the screen to the state before the listener and the trade ran, so
    /// everything equals the snapshot before opening, the auto-equip included (measured vanilla behaviour,
    /// F24 of the S9 plan). The open-screen checks are mandatory so the test cannot pass with an equip or
    /// trade that never happened. Each variant runs in its own fresh campaign that is never saved, so
    /// only the MCM values (global, not per campaign) are restored and the town is left at the end.
    /// </summary>
    public abstract class TradeWithAutoEquipScenario : IScenario
    {
        private const string IdPrefix = "crossmod.trade-with-autoequip";

        // AutoTrader setup, as in AT-1 (autotrader.town-trade).
        private const string TownOptionId = "autotrader_town";
        private const int PlayerGold = 50000;
        private const string SurplusItemId = "pottery";
        private const int SurplusCount = 30;
        private const int FixedThresholdsIndex = 1;
        private const int BuyThreshold = 90;

        // Lowest value of the MCM sell threshold: every good with a positive price factor is sold, so the
        // trade does not depend on how the chosen town prices the surplus.
        private const int SellThreshold = 0;

        // CompanionSuite setup, the pair proven live by CS-1 (companion.equip-now).
        private const string WornItemId = "padded_leather_shirt";
        private const string BetterItemId = "lamellar_with_scale_skirt";

        // Hire fixture, copied from CompanionManagementSuite tests/InGame/.../CompanionFixture.cs (internal there).
        private const string TemplateId = "spc_wanderer_empire_0";
        private const string BirthCultureId = "empire";
        private const int AgeAboveComesOfAge = 10;

        // Longer than AutoTrader's 15-tick inventory display refresh: closing earlier breaks Gauntlet.
        private const int ScreenTicks = 30;
        private const double OpenTimeoutSeconds = 10;
        private const double OpenHardTimeoutMarginSeconds = 5;

        private const string AutoTraderLogFileName = "AutoTrader.log";
        private const string AutoTraderCrashMarker = "Something terrible happened";

        private readonly bool _cancel;

        protected TradeWithAutoEquipScenario(bool cancel)
        {
            _cancel = cancel;
        }

        public string Id => IdPrefix + (_cancel ? ".cancel" : ".done");

        public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
        {
            AutoTraderMcmSettings settings = AutoTraderMcmSettings.Instance;
            ctx.Check("setup.mcm", settings != null, "AutoTraderMcmSettings.Instance != null", settings != null ? "ok" : "null");
            TradeBehavior trade = Campaign.Current.GetCampaignBehavior<TradeBehavior>();
            ctx.Check("setup.trade-behavior", trade != null, "TradeBehavior registered", trade != null ? "ok" : "null");
            CompanionSuiteBehavior suite = Campaign.Current.GetCampaignBehavior<CompanionSuiteBehavior>();
            bool suiteReady = suite != null && SuiteServices.EquipService != null;
            ctx.Check("setup.companion-suite", suiteReady, "CompanionSuiteBehavior registered and SuiteServices.EquipService set",
                suite == null ? "behavior null" : SuiteServices.EquipService == null ? "EquipService null" : "ok");
            int autoSaveInterval = Campaign.Current.SaveHandler.AutoSaveInterval;
            ctx.Check("setup.autosave-off", autoSaveInterval == -1, "AutoSaveInterval == -1", autoSaveInterval.ToString());
            if (settings == null || trade == null || !suiteReady || autoSaveInterval != -1)
            {
                yield break;
            }

            ItemObject surplus = MBObjectManager.Instance.GetObject<ItemObject>(SurplusItemId);
            ItemObject worn = MBObjectManager.Instance.GetObject<ItemObject>(WornItemId);
            ItemObject better = MBObjectManager.Instance.GetObject<ItemObject>(BetterItemId);
            bool itemsExist = surplus != null && worn != null && better != null;
            ctx.Check("setup.items", itemsExist, SurplusItemId + ", " + WornItemId + " and " + BetterItemId + " exist",
                itemsExist ? "ok" : "item not found");
            if (!itemsExist)
            {
                yield break;
            }

            // CompanionSuite ranks armor by Effectiveness; without this the listener would keep the worn piece.
            bool betterRanksHigher = better.Effectiveness > worn.Effectiveness;
            ctx.Check("setup.effectiveness", betterRanksHigher, BetterItemId + " Effectiveness > " + WornItemId,
                better.Effectiveness + " vs " + worn.Effectiveness);
            if (!betterRanksHigher)
            {
                yield break;
            }

            CharacterObject template = MBObjectManager.Instance.GetObject<CharacterObject>(TemplateId);
            Settlement birthTown = FindBirthTown();
            bool hirable = template != null && birthTown != null;
            ctx.Check("setup.template", hirable, TemplateId + " and a " + BirthCultureId + " town exist",
                (template == null ? "template missing" : "template ok") + ", " + (birthTown == null ? "town missing" : "town ok"));
            if (!hirable)
            {
                yield break;
            }

            // Foreign and at peace, so AutoTrader's warehouse deposit stays out and the town grants trade access.
            Settlement town = TownFixture.FindTown(s => s.OwnerClan != Clan.PlayerClan && TownFixture.IsAtPeaceWithPlayer(s));
            if (town == null)
            {
                throw new InvalidOperationException("no foreign town at peace with the player");
            }

            ctx.Log("variant " + (_cancel ? "Cancel" : "Done") + ", trade town " + town.StringId + " (gold " + town.Town.Gold + ")");
            ctx.Log("companion suite log " + (SuiteLog.LogPath ?? "(none)"));

            int originalPricing = settings.PricingMode.SelectedIndex;
            int originalBuy = settings.BuyThreshold;
            int originalSell = settings.SellThreshold;
            try
            {
                settings.PricingMode.SelectedIndex = FixedThresholdsIndex;
                settings.BuyThreshold = BuyThreshold;
                settings.SellThreshold = SellThreshold;
                AutoTraderMcmSettings.Apply();
                ctx.Check("setup.sell-threshold", AutoTraderConfig.SellThresholdValue == SellThreshold && !AutoTraderConfig.SimpleTradingAI,
                    "fixed thresholds, effective sell threshold " + SellThreshold,
                    (AutoTraderConfig.SimpleTradingAI ? "rumours" : "thresholds") + ", sell " + AutoTraderConfig.SellThresholdValue);

                Hero.MainHero.ChangeHeroGold(PlayerGold - Hero.MainHero.Gold);
                MobileParty.MainParty.ItemRoster.AddToCounts(surplus, SurplusCount);

                // As CS-1: any other gear in the roster could be picked instead of the better armor.
                ItemRoster roster = MobileParty.MainParty.ItemRoster;
                int gearRows = CountGearRows(roster);
                int pairInStock = CountOf(roster, worn) + CountOf(roster, better);
                bool cleanInventory = gearRows == 0 && pairInStock == 0;
                ctx.Check("setup.clean-inventory", cleanInventory,
                    "no armor, weapon or mount rows and 0 x " + WornItemId + " / " + BetterItemId,
                    gearRows + " gear row(s), " + pairInStock + " x " + WornItemId + " / " + BetterItemId);
                if (!cleanInventory)
                {
                    yield break;
                }

                Hero companion = Hire(ctx, template, birthTown);
                bool joined = companion.PartyBelongedTo == MobileParty.MainParty && suite.ManagedHeroes().Contains(companion);
                ctx.Check("setup.joined", joined, "PartyBelongedTo == MainParty and in ManagedHeroes", joined ? "ok" : "not joined or not managed");
                if (!joined)
                {
                    yield break;
                }

                ClearBattleEquipment(companion);
                companion.BattleEquipment.AddEquipmentToSlotWithoutAgent(EquipmentIndex.Body, new EquipmentElement(worn));
                MobileParty.MainParty.ItemRoster.AddToCounts(better, 1);

                CompanionProfile profile = suite.GetProfile(companion);
                profile.EquipAutomation = AutomationLevel.Auto;
                profile.SetManualArchetype(CombatArchetype.Infantry);
                suite.SetProfile(companion, profile);
                AutomationLevel equipLevel = suite.GetProfile(companion).EquipAutomation;
                ctx.Check("setup.profile", equipLevel == AutomationLevel.Auto, "equip automation Auto, archetype Infantry",
                    "equip automation " + equipLevel);

                foreach (ScenarioStep step in TownFixture.EnterTown(town))
                {
                    yield return step;
                }

                MenuContext menu = Campaign.Current.CurrentMenuContext;
                GameMenuOption option = menu.GameMenu.MenuOptions.FirstOrDefault(o => o.IdString == TownOptionId);
                ctx.Check("menu.option-present", option != null, TownOptionId + " in menu '" + menu.GameMenu.StringId + "'",
                    option != null ? "ok" : "missing");
                bool usable = option != null && option.GetConditionsHold(Game.Current, menu);
                if (option != null)
                {
                    ctx.Check("menu.option-condition", usable, "condition holds", usable ? "ok" : "false");
                }

                InventorySnapshot before = InventorySnapshot.Capture(town);
                string wornKey = InventorySnapshot.ItemKey(new EquipmentElement(worn));
                string betterKey = InventorySnapshot.ItemKey(new EquipmentElement(better));
                string bodyBefore = BodyKey(before, companion);
                int betterBefore = ValueOrZero(before.PartyItems, betterKey);
                // The swap must happen on the trade screen, not earlier.
                ctx.Check("before.setup-state", bodyBefore == wornKey && betterBefore == 1,
                    "companion body slot " + wornKey + ", 1 x " + betterKey + " in the party roster",
                    "body slot " + bodyBefore + ", " + betterBefore + " x " + betterKey);

                long suiteLogOffset = LogLength(SuiteLog.LogPath);
                string autoTraderLogPath = AutoTraderLogPath();
                long autoTraderLogOffset = LogLength(autoTraderLogPath);
                if (usable)
                {
                    option.RunConsequence(menu);
                }
                else
                {
                    // Keeps "wiring broken" apart from "trading broken": the failed menu checks already fail the run.
                    ctx.Log("menu option unusable, trading through TradeBehavior.AutoTradeGoodsConsequence");
                    trade.AutoTradeGoodsConsequence(null);
                }

                // Soft wait, so a screen that never opens fails screen.opened instead of ending as Timeout. A crash
                // in PerformAutoTrade may keep the screen from opening, so stop on its marker too.
                Stopwatch openDeadline = Stopwatch.StartNew();
                yield return ScenarioStep.Until(
                    () => ScreenFixture.IsInventoryOpen
                        || HasAutoTraderCrashSince(autoTraderLogPath, autoTraderLogOffset)
                        || openDeadline.Elapsed.TotalSeconds >= OpenTimeoutSeconds,
                    OpenTimeoutSeconds + OpenHardTimeoutMarginSeconds,
                    "inventory screen open or '" + AutoTraderCrashMarker + "' logged");

                // AutoTrader catches every exception of the trade and only logs it, so a trade aborted after a
                // partial sale would otherwise still pass the conservation checks.
                bool crashed = HasAutoTraderCrashSince(autoTraderLogPath, autoTraderLogOffset);
                ctx.Check("log.no-crash", !crashed, "no '" + AutoTraderCrashMarker + "' in " + autoTraderLogPath,
                    crashed ? "found" : File.Exists(autoTraderLogPath) ? "none" : "none (no log file)");

                bool opened = ScreenFixture.IsInventoryOpen;
                ctx.Check("screen.opened", opened, "inventory state active", opened ? "open" : "not open");
                if (opened)
                {
                    yield return ScenarioStep.Ticks(ScreenTicks);

                    InventorySnapshot open = InventorySnapshot.Capture(town);

                    // Gold the closing DoneLogic will book: the hero receives -TotalAmount, the town +TotalAmount.
                    int totalAmountAtOpen = InventoryScreenHelper.GetActiveInventoryState().InventoryLogic.TotalAmount;
                    ctx.Check("open.logic-traded", totalAmountAtOpen != 0, "InventoryLogic.TotalAmount != 0",
                        "TotalAmount " + totalAmountAtOpen);

                    string bodyKey = BodyKey(open, companion);
                    ctx.Check("open.autoequip-ran", bodyKey == betterKey, "companion body slot " + betterKey, bodyKey);

                    string surplusKey = InventorySnapshot.ItemKey(new EquipmentElement(surplus));
                    int surplusDelta = ValueOrZero(SnapshotDiff.CountDelta(before.PartyItems, open.PartyItems), surplusKey);
                    ctx.Check("open.traded", surplusDelta < 0, surplusKey + " party delta < 0", surplusDelta.ToString());

                    CheckConserved(ctx, "open.conserved", before, open);
                    ctx.Check("open.gold-unbooked", open.HeroGold == before.HeroGold && open.TownGold == before.TownGold,
                        "hero " + before.HeroGold + ", town " + before.TownGold,
                        "hero " + open.HeroGold + ", town " + open.TownGold);

                    foreach (ScenarioStep step in ScreenFixture.CloseInventory(_cancel))
                    {
                        yield return step;
                    }

                    // CloseInventory only waits; DoneLogic may refuse and keep the screen open.
                    bool closed = !ScreenFixture.IsInventoryOpen;
                    ctx.Check("screen.closed", closed, "no inventory state", closed ? "closed" : "still open");
                    if (closed)
                    {
                        InventorySnapshot after = InventorySnapshot.Capture(town);
                        if (_cancel)
                        {
                            CheckCancelled(ctx, before, after);
                        }
                        else
                        {
                            CheckDone(ctx, before, after, totalAmountAtOpen, BodyKey(after, companion), betterKey);
                        }
                    }
                }

                // EquipApplier's section summary "-> <n> slot(s) changed for <name>"; the section header is also
                // written when nothing changed, so only the summary with n >= 1 proves the pass.
                string changeSuffix = " slot(s) changed for " + companion.Name;
                string suiteLog = ReadLogSince(SuiteLog.LogPath, suiteLogOffset);
                int slotsLogged = suiteLog == null ? 0 : MaxChangedSlots(suiteLog, changeSuffix);
                ctx.Check("log.equip-pass", slotsLogged >= 1, "'<n>" + changeSuffix + "' with n >= 1 appended to the companion suite log",
                    suiteLog == null ? "log unavailable" : slotsLogged >= 1 ? slotsLogged + changeSuffix : "no change line");

                // Leave the town even when the screen got stuck: LeaveTownNow cancels an open screen first.
                if (ScreenFixture.IsInventoryOpen)
                {
                    TownFixture.LeaveTownNow();
                }
                else
                {
                    foreach (ScenarioStep step in TownFixture.LeaveTown())
                    {
                        yield return step;
                    }
                }

                // LeaveTown only waits; check the outcome itself.
                bool outside = PlayerEncounter.Current == null && MobileParty.MainParty.CurrentSettlement == null;
                ctx.Check("town.left", outside, "no encounter, party outside any settlement",
                    outside ? "outside" : "encounter " + (PlayerEncounter.Current != null ? "open" : "none")
                        + ", settlement " + (MobileParty.MainParty.CurrentSettlement != null ? MobileParty.MainParty.CurrentSettlement.StringId : "none"));
            }
            finally
            {
                settings.PricingMode.SelectedIndex = originalPricing;
                settings.BuyThreshold = originalBuy;
                settings.SellThreshold = originalSell;
                AutoTraderMcmSettings.Apply();
                TownFixture.LeaveTownNow();
            }
        }

        // Done keeps the trade and the auto-equip: items conserved, gold moves between hero and town only.
        private static void CheckDone(IScenarioContext ctx, InventorySnapshot before, InventorySnapshot after, int totalAmountAtOpen,
            string bodyKey, string betterKey)
        {
            CheckConserved(ctx, "done.conserved", before, after);

            int heroDelta = after.HeroGold - before.HeroGold;
            int townDelta = after.TownGold - before.TownGold;
            ctx.Check("done.gold-mirrored", heroDelta == -townDelta, "hero delta = -(town delta), no tax",
                "hero " + heroDelta + ", town " + townDelta);

            // Vanilla DoneLogic pays the hero Min(-TotalAmount, town gold) and sets the town to gold + TotalAmount.
            ctx.Check("done.gold-booked", heroDelta == -totalAmountAtOpen,
                "hero delta " + (-totalAmountAtOpen) + " (-TotalAmount at open)", "hero delta " + heroDelta);

            ctx.Check("done.equip-kept", bodyKey == betterKey, "companion body slot " + betterKey, bodyKey);
        }

        // Cancel restores the screen's initial state, taken before the listener and the trade ran (F22-F24).
        private static void CheckCancelled(IScenarioContext ctx, InventorySnapshot before, InventorySnapshot after)
        {
            CheckConserved(ctx, "cancel.conserved", before, after);

            var changes = new List<string>();
            AddCountChanges(changes, "party", SnapshotDiff.CountDelta(before.PartyItems, after.PartyItems));
            AddCountChanges(changes, "town", SnapshotDiff.CountDelta(before.TownItems, after.TownItems));
            AddCountChanges(changes, "stash", SnapshotDiff.CountDelta(before.StashItems, after.StashItems));
            changes.AddRange(SnapshotDiff.ValueChanges(before.Equipment, after.Equipment).Select(line => "equipment " + line));
            ctx.Check("cancel.state-restored", changes.Count == 0, "party, town, stash and equipment equal before",
                changes.Count == 0 ? "equal" : string.Join("; ", changes));

            int heroDelta = after.HeroGold - before.HeroGold;
            int townDelta = after.TownGold - before.TownGold;
            ctx.Check("cancel.gold-zero", heroDelta == 0 && townDelta == 0, "hero 0, town 0",
                "hero " + heroDelta + ", town " + townDelta);
        }

        // Per item key, party + town + stash + equipped slots must not change.
        private static void CheckConserved(IScenarioContext ctx, string name, InventorySnapshot before, InventorySnapshot now)
        {
            IReadOnlyDictionary<string, int> unbalanced = SnapshotDiff.ConservationDelta(Containers(before), Containers(now));
            ctx.Check(name, unbalanced.Count == 0, "party + town + stash + equipped slots unchanged per item",
                unbalanced.Count == 0 ? "ok" : "off by " + Describe(unbalanced));
        }

        private static IEnumerable<IReadOnlyDictionary<string, int>> Containers(InventorySnapshot snapshot)
        {
            return new[]
            {
                snapshot.PartyItems,
                snapshot.TownItems,
                snapshot.StashItems,
                SnapshotDiff.EquipmentCounts(snapshot.Equipment),
            };
        }

        private static void AddCountChanges(List<string> target, string container, IReadOnlyDictionary<string, int> delta)
        {
            if (delta.Count > 0)
            {
                target.Add(container + " " + Describe(delta));
            }
        }

        private static string Describe(IReadOnlyDictionary<string, int> delta)
        {
            return string.Join(", ", delta.OrderBy(pair => pair.Key, StringComparer.Ordinal)
                .Select(pair => pair.Key + " " + (pair.Value > 0 ? "+" : string.Empty) + pair.Value));
        }

        private static string BodyKey(InventorySnapshot snapshot, Hero hero)
        {
            string key;
            return snapshot.Equipment.TryGetValue(hero.StringId + "/battle/" + EquipmentIndex.Body, out key) ? key : "(empty)";
        }

        private static int ValueOrZero(IReadOnlyDictionary<string, int> counts, string key)
        {
            int value;
            return counts.TryGetValue(key, out value) ? value : 0;
        }

        // Copied from CompanionManagementSuite tests/InGame/CompanionManagementSuite.Scenarios/CompanionFixture.Hire
        // (internal there): the vanilla wanderer spawn and hire dialog.
        private static Hero Hire(IScenarioContext ctx, CharacterObject template, Settlement birthTown)
        {
            int age = Campaign.Current.Models.AgeModel.HeroComesOfAge + AgeAboveComesOfAge;
            Hero hero = HeroCreator.CreateSpecialHero(template, birthTown, null, null, age);
            hero.ChangeState(Hero.CharacterStates.Active);
            AddCompanionAction.Apply(Clan.PlayerClan, hero);
            AddHeroToPartyAction.Apply(hero, MobileParty.MainParty, false);
            ctx.Log("hired companion " + hero.StringId);
            return hero;
        }

        // CreateSpecialHero picks gear at random; only the worn body armor may be equipped before the trade.
        private static void ClearBattleEquipment(Hero hero)
        {
            for (int slot = 0; slot < (int)EquipmentIndex.NumEquipmentSetSlots; slot++)
            {
                hero.BattleEquipment.AddEquipmentToSlotWithoutAgent((EquipmentIndex)slot, new EquipmentElement());
            }
        }

        private static Settlement FindBirthTown()
        {
            return Settlement.All
                .Where(s => s.IsTown && s.Culture != null && s.Culture.StringId == BirthCultureId)
                .OrderBy(s => s.StringId, StringComparer.Ordinal)
                .FirstOrDefault();
        }

        private static int CountGearRows(ItemRoster roster)
        {
            int rows = 0;
            for (int i = 0; i < roster.Count; i++)
            {
                ItemObject item = roster.GetElementCopyAtIndex(i).EquipmentElement.Item;
                if (item != null && ItemViewMapper.ToView(item).Category != SuiteItemCategory.Other)
                {
                    rows++;
                }
            }

            return rows;
        }

        // Amount of the item over all roster rows, whatever their modifier.
        private static int CountOf(ItemRoster roster, ItemObject item)
        {
            int count = 0;
            for (int i = 0; i < roster.Count; i++)
            {
                ItemRosterElement row = roster.GetElementCopyAtIndex(i);
                if (row.EquipmentElement.Item == item)
                {
                    count += row.Amount;
                }
            }

            return count;
        }

        // Highest n over the log lines ending in "<n><suffix>"; 0 when there is none.
        private static int MaxChangedSlots(string log, string suffix)
        {
            int max = 0;
            foreach (string rawLine in log.Split('\n'))
            {
                string line = rawLine.TrimEnd('\r');
                if (!line.EndsWith(suffix, StringComparison.Ordinal))
                {
                    continue;
                }

                string head = line.Substring(0, line.Length - suffix.Length);
                int start = head.Length;
                while (start > 0 && char.IsDigit(head[start - 1]))
                {
                    start--;
                }

                int n;
                if (start < head.Length && int.TryParse(head.Substring(start), out n) && n > max)
                {
                    max = n;
                }
            }

            return max;
        }

        // Copied from AutoTraderSpeed tests/InGame/AutoTraderSpeed.Scenarios/ModLogFile.Path (internal there):
        // EngineFilePaths.ConfigsPath is only the relative "Configs"; FileHelper resolves it to the absolute
        // Documents folder exactly as AutoTraderHelpers does when it writes the log.
        private static string AutoTraderLogPath()
        {
            return TaleWorlds.Library.FileHelper.GetFileFullPath(
                new TaleWorlds.Library.PlatformFilePath(TaleWorlds.Engine.EngineFilePaths.ConfigsPath, AutoTraderLogFileName));
        }

        private static bool HasAutoTraderCrashSince(string path, long offset)
        {
            string text = ReadLogSince(path, offset);
            return text != null && text.IndexOf(AutoTraderCrashMarker, StringComparison.Ordinal) >= 0;
        }

        // Current length of a log the game keeps open for writing; 0 when there is no file.
        private static long LogLength(string path)
        {
            if (path == null || !File.Exists(path))
            {
                return 0;
            }

            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                return stream.Length;
            }
        }

        // Log text appended after offset; null without a log file or when the offset lies beyond its end
        // (the log was replaced). Same reading as CompanionFixture.ReadLogSince in the CompanionSuite scenarios.
        private static string ReadLogSince(string path, long offset)
        {
            if (path == null || !File.Exists(path))
            {
                return null;
            }

            // The game keeps the file open for writing, hence ReadWrite sharing.
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            {
                if (offset < 0 || offset > stream.Length)
                {
                    return null;
                }

                stream.Seek(offset, SeekOrigin.Begin);
                using (var reader = new StreamReader(stream, Encoding.UTF8))
                {
                    return reader.ReadToEnd();
                }
            }
        }
    }
}
