using System;
using System.Collections.Generic;
using System.Globalization;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.Party;

namespace TestRig.Harness
{
    /// <summary>
    /// Engine glue for the soak harness: parks the player party, counts in-game days and leaves
    /// breadcrumbs (first campaign ticks, first hourly ticks, every daily tick) in harness.log.
    /// No decisions here - those live in Logic/HarnessRun.cs.
    /// </summary>
    public sealed class HarnessCampaignBehavior : CampaignBehaviorBase
    {
        // Crash localization: the harness is the last module, so its listeners run after the
        // other behaviours' listeners of the same event [A: subscription order]; a "done" line
        // means everything registered before it survived that event.
        private const int CampaignTicksToTrace = 120;
        private const int HourlyTicksToTrace = 72;

        private readonly Action<string> _log;
        private readonly HashSet<string> _logged = new HashSet<string>();
        private int _campaignTicks;
        private int _hourlyTicks;

        public HarnessCampaignBehavior(Action<string> log)
        {
            _log = log;
        }

        /// <summary>DailyTickEvent firings since OnSessionLaunched.</summary>
        public int DaysElapsed { get; private set; }

        /// <summary>Live query; false when there is no campaign or main party.</summary>
        public bool PlayerInMapEvent
        {
            get
            {
                try
                {
                    return Campaign.Current != null && MobileParty.MainParty?.MapEvent != null;
                }
                catch (Exception ex)
                {
                    LogOnce("PlayerInMapEvent failed: " + ex.Message);
                    return false;
                }
            }
        }

        public override void RegisterEvents()
        {
            CampaignEvents.OnSessionLaunchedEvent.AddNonSerializedListener(this, OnSessionLaunched);
            CampaignEvents.DailyTickEvent.AddNonSerializedListener(this, OnDailyTick);
            CampaignEvents.HourlyTickEvent.AddNonSerializedListener(this, OnHourlyTick);
            CampaignEvents.TickEvent.AddNonSerializedListener(this, OnTick);
        }

        /// <summary>The harness never saves; nothing to persist.</summary>
        public override void SyncData(IDataStore dataStore)
        {
        }

        /// <summary>
        /// Makes the player party ignored by all other parties and holds it in place.
        /// Idempotent; safe to call every tick.
        /// </summary>
        public void Park()
        {
            try
            {
                if (Campaign.Current == null)
                {
                    return;
                }

                MobileParty party = MobileParty.MainParty;
                if (party == null)
                {
                    return;
                }

                party.IgnoreByOtherPartiesTill(CampaignTime.Never);
                party.SetMoveModeHold();
                LogOnce("Park: main party held and ignored by other parties");

                if (party.CurrentSettlement != null)
                {
                    // No verified leave sequence exists (RUN-VERIFIED 2: OPEN), so only report it.
                    LogOnce("Park: main party is inside settlement '" + party.CurrentSettlement.StringId
                        + "'; not leaving it automatically (leave sequence unverified).");
                }
            }
            catch (Exception ex)
            {
                LogOnce("Park failed: " + ex.Message);
            }
        }

        private void OnSessionLaunched(CampaignGameStarter starter)
        {
            DaysElapsed = 0;
            Log("OnSessionLaunched (harness listener)");
            Park();
        }

        private void OnDailyTick()
        {
            DaysElapsed++;
            Log("DailyTick " + DaysElapsed + " done (" + Hours() + ")");
        }

        private void OnHourlyTick()
        {
            if (_hourlyTicks >= HourlyTicksToTrace)
            {
                return;
            }

            _hourlyTicks++;
            Log("HourlyTick " + _hourlyTicks + " done (" + Hours() + ")");
        }

        private void OnTick(float dt)
        {
            if (_campaignTicks >= CampaignTicksToTrace)
            {
                return;
            }

            _campaignTicks++;
            Log("CampaignTick " + _campaignTicks + " done (dt=" + dt.ToString("F4", CultureInfo.InvariantCulture)
                + ", " + Hours() + ")");
        }

        private static string Hours()
        {
            return "hours=" + CampaignTime.Now.ToHours.ToString("F2", CultureInfo.InvariantCulture);
        }

        private void Log(string message)
        {
            try
            {
                _log?.Invoke(message);
            }
            catch (Exception)
            {
                // A failing log sink must never reach the game.
            }
        }

        private void LogOnce(string message)
        {
            if (_logged.Add(message))
            {
                Log(message);
            }
        }
    }
}
