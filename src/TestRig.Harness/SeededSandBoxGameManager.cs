using SandBox;
using TaleWorlds.CampaignSystem;
using TaleWorlds.Core;
using TaleWorlds.MountAndBlade;

namespace TestRig.Harness
{
    /// <summary>
    /// New-game Sandbox manager that creates the <see cref="Game"/> with a fixed RNG seed.
    /// Vanilla <see cref="SandBoxGameManager"/> uses the unseeded <c>Game.CreateGame</c> overload,
    /// whose <c>MBFastRandom</c> is seeded from <c>Environment.TickCount</c>. Subclassing keeps every
    /// <c>is SandBoxGameManager</c> check and the vanilla <c>OnLoadFinished</c> (intro video, then
    /// character creation) intact; only the loading step that creates the Game is replaced.
    /// </summary>
    public sealed class SeededSandBoxGameManager : SandBoxGameManager
    {
        private readonly int _seed;

        public SeededSandBoxGameManager(int seed)
            : base(CreateCampaign)
        {
            _seed = seed;
        }

        protected override void DoLoadingForGameManager(
            GameManagerLoadingSteps gameManagerLoadingStep,
            out GameManagerLoadingSteps nextStep)
        {
            if (gameManagerLoadingStep != GameManagerLoadingSteps.SecondInitializeThirdState)
            {
                base.DoLoadingForGameManager(gameManagerLoadingStep, out nextStep);
                return;
            }

            // Mirrors the new-game branch of SandBoxGameManager.DoLoadingForGameManager,
            // case SecondInitializeThirdState (v1.4.8). Only difference: the seeded CreateGame
            // overload. Debug prints and the saved-game branch are omitted (this manager never
            // loads a save). Re-diff against vanilla after every game update.
            MBGlobals.InitializeReferences();
            Campaign campaign = CreateCampaign();
            Game.CreateGame(campaign, this, _seed);
            campaign.SetLoadingParameters(Campaign.GameLoadingType.NewCampaign);
            Game.Current.DoLoading();
            nextStep = GameManagerLoadingSteps.PostInitializeFourthState;
        }

        // Same campaign the main-menu "SandBox" button creates (SandBoxViewSubModule.StartGame).
        private static Campaign CreateCampaign()
        {
            return new Campaign(CampaignGameMode.Campaign);
        }
    }
}
