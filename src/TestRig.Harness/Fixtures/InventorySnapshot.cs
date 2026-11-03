using System.Collections.Generic;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.Party;
using TaleWorlds.CampaignSystem.Roster;
using TaleWorlds.CampaignSystem.Settlements;
using TaleWorlds.Core;
using TestRig.Harness.Logic;

namespace TestRig.Harness.Fixtures
{
    /// <summary>
    /// Copy of the trade-relevant state of the player and one town at one moment: item counts of the
    /// party, the town and its stash, gold of the hero and the town, and the battle and civilian
    /// equipment of every hero in the party. Compare two snapshots with <see cref="SnapshotDiff"/>.
    /// </summary>
    public sealed class InventorySnapshot
    {
        private InventorySnapshot()
        {
        }

        /// <summary>Item count per item key (see <see cref="ItemKey"/>) in the main party's item roster.</summary>
        public IReadOnlyDictionary<string, int> PartyItems { get; private set; }

        /// <summary>Same for the town's trade roster; empty when the settlement has no town.</summary>
        public IReadOnlyDictionary<string, int> TownItems { get; private set; }

        /// <summary>Same for <see cref="Settlement.Stash"/>.</summary>
        public IReadOnlyDictionary<string, int> StashItems { get; private set; }

        public int HeroGold { get; private set; }

        /// <summary>Gold of the town; 0 when the settlement has no town.</summary>
        public int TownGold { get; private set; }

        /// <summary>Item key per "&lt;heroId&gt;/battle|civilian/&lt;slot&gt;" over all heroes in the party; empty slots are left out.</summary>
        public IReadOnlyDictionary<string, string> Equipment { get; private set; }

        /// <summary>Takes the snapshot now; <paramref name="settlement"/> may be any settlement, town data is empty for non-towns.</summary>
        public static InventorySnapshot Capture(Settlement settlement)
        {
            var snapshot = new InventorySnapshot
            {
                PartyItems = CountItems(MobileParty.MainParty.ItemRoster),
                StashItems = CountItems(settlement.Stash),
                HeroGold = Hero.MainHero.Gold,
                Equipment = CaptureEquipment(MobileParty.MainParty.MemberRoster),
            };

            Town town = settlement.Town;
            snapshot.TownItems = CountItems(town == null ? null : settlement.Party.ItemRoster);
            snapshot.TownGold = town == null ? 0 : town.Gold;
            return snapshot;
        }

        /// <summary>Item id, plus "#" and the modifier id when the item has one.</summary>
        public static string ItemKey(EquipmentElement element)
        {
            if (element.IsEmpty)
            {
                return "(empty)";
            }

            return element.ItemModifier == null
                ? element.Item.StringId
                : element.Item.StringId + "#" + element.ItemModifier.StringId;
        }

        private static IReadOnlyDictionary<string, int> CountItems(ItemRoster roster)
        {
            var counts = new Dictionary<string, int>();
            if (roster == null)
            {
                return counts;
            }

            foreach (ItemRosterElement element in roster)
            {
                string key = ItemKey(element.EquipmentElement);
                int sum;
                counts.TryGetValue(key, out sum);
                counts[key] = sum + element.Amount;
            }

            return counts;
        }

        private static IReadOnlyDictionary<string, string> CaptureEquipment(TroopRoster members)
        {
            var equipment = new Dictionary<string, string>();
            foreach (TroopRosterElement element in members.GetTroopRoster())
            {
                Hero hero = element.Character.HeroObject;
                if (hero == null)
                {
                    continue;
                }

                AddSlots(equipment, hero.StringId + "/battle/", hero.BattleEquipment);
                AddSlots(equipment, hero.StringId + "/civilian/", hero.CivilianEquipment);
            }

            return equipment;
        }

        private static void AddSlots(Dictionary<string, string> target, string prefix, Equipment equipment)
        {
            for (int slot = 0; slot < (int)EquipmentIndex.NumEquipmentSetSlots; slot++)
            {
                EquipmentElement element = equipment.GetEquipmentFromSlot((EquipmentIndex)slot);
                if (!element.IsEmpty)
                {
                    target[prefix + ((EquipmentIndex)slot)] = ItemKey(element);
                }
            }
        }
    }
}
