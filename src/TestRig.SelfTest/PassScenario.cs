using System.Collections.Generic;
using TaleWorlds.CampaignSystem;
using TestRig.Harness.Logic;

namespace TestRig.SelfTest
{
    /// <summary>The control run: a campaign exists and the scenario passes, so the rig can tell a healthy run from the broken ones.</summary>
    public sealed class PassScenario : IScenario
    {
        public string Id => "rig.selftest-pass";

        public IEnumerable<ScenarioStep> Run(IScenarioContext ctx)
        {
            bool campaign = Campaign.Current != null;
            ctx.Check("campaign", campaign, "Campaign.Current != null", campaign ? "ok" : "null");

            yield break;
        }
    }
}
