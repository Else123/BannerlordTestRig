using System;
using System.Collections.Generic;
using System.Linq;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.CharacterCreationContent;
using TaleWorlds.CampaignSystem.GameState;
using TaleWorlds.Core;
using TaleWorlds.Localization;
using TaleWorlds.MountAndBlade;

namespace TestRig.Harness
{
    /// <summary>
    /// Drives the vanilla Sandbox character creation with fixed choices, one step per call.
    /// Engine glue only: it replicates the model-level effect each stage's Gauntlet view/VM applies
    /// on "Next" and then calls <see cref="CharacterCreationManager.NextStage"/>, like the view does.
    /// The vanilla screen stays up; nothing is patched.
    /// </summary>
    /// <remarks>
    /// Call <see cref="Advance"/> once per application tick from the moment the new game was started
    /// until it returns true. Outside the intro video and character creation it only waits.
    /// Post-creation inquiries (NavalDLC "Call of the Oceans") are NOT handled here; they appear on the
    /// map and are the caller's job.
    /// </remarks>
    public sealed class CharacterCreationDriver
    {
        private const string CultureId = "empire";
        private const string HarnessName = "Harness";

        // Fixed narrative choice per vanilla menu: the first vanilla option (declaration order in
        // CharacterCreationCampaignBehavior, v1.4.8) whose OnCondition holds for culture "empire" and
        // the choices before it. Matched by StringId, never by index, because NavalDLC appends options.
        // "empire_lanlord_option" is the vanilla spelling. It sets parent occupation "retainer", which is
        // not urban, so the non-urban education/adulthood options are available.
        private static readonly Dictionary<string, string> OptionIdByMenuId = new Dictionary<string, string>
        {
            { "narrative_parent_menu", "empire_lanlord_option" },
            { "narrative_childhood_menu", "childhood_leadership_option" },
            { "narrative_education_menu", "education_herder_option" },
            { "narrative_youth_menu", "youth_staff_first_option" },
            { "narrative_adulthood_menu", "adulthood_defeated_enemy_option" },
            { "narrative_age_selection_menu", "age_selection_young_adult_option" },
        };

        private VideoPlaybackState _observedVideo;
        private VideoPlaybackState _skippedVideo;
        private CharacterCreationStageBase _observedStage;
        private bool _completed;

        /// <summary>Last error message, or null if none occurred.</summary>
        public string LastError { get; private set; }

        /// <summary>Description of the last step taken, for the harness log.</summary>
        public string LastStep { get; private set; }

        /// <summary>
        /// Performs at most one step. Returns true once character creation is over and the map state
        /// is active. Never throws; failures are recorded in <see cref="LastError"/> and the step is
        /// retried on the next call.
        /// </summary>
        public bool Advance()
        {
            if (_completed)
            {
                return true;
            }

            try
            {
                return AdvanceOneStep();
            }
            catch (Exception e)
            {
                LastError = "Character creation step failed: " + e;
                return false;
            }
        }

        private bool AdvanceOneStep()
        {
            GameState activeState = GameStateManager.Current == null ? null : GameStateManager.Current.ActiveState;

            if (activeState is MapState)
            {
                return MarkCompleted();
            }

            VideoPlaybackState video = activeState as VideoPlaybackState;
            if (video != null)
            {
                SkipIntroVideo(video);
                return false;
            }

            CharacterCreationState creationState = activeState as CharacterCreationState;
            if (creationState == null)
            {
                return false; // Still loading, or not started yet.
            }

            CharacterCreationManager manager = creationState.CharacterCreationManager;
            CharacterCreationStageBase stage = manager.CurrentStage;
            if (stage == null)
            {
                return false; // The first stage is activated with the state (OnStateActivated).
            }

            // Act one frame after a stage became current, so its view (built in
            // CharacterCreationScreen.OnStageCreated) exists, as for a player clicking "Next".
            if (!ReferenceEquals(stage, _observedStage))
            {
                _observedStage = stage;
                LastStep = "Stage active: " + stage.GetType().Name;
                return false;
            }

            if (!ApplyFixedChoice(manager, stage))
            {
                return false;
            }

            manager.NextStage();
            LastStep = "Completed stage: " + stage.GetType().Name;

            // After the last stage NextStage finalizes synchronously and pushes the MapState.
            return GameStateManager.Current.ActiveState is MapState && MarkCompleted();
        }

        private bool MarkCompleted()
        {
            _completed = true;
            LastStep = "Character creation complete, map active";
            return true;
        }

        // Ends the campaign intro the way the video screen does at its natural end
        // (VideoPlaybackScreen.OnFrameTick -> VideoPlaybackState.OnVideoFinished, whose delegate is
        // SandBoxGameManager.LaunchSandboxCharacterCreation). Waits one frame so the screen's
        // OnInitialize (PlayVideo, OnVideoStarted) has run, and fires at most once per video state.
        // The screen itself cannot fire a second time: the delegate replaces the state synchronously
        // (GameStateManager.CleanAndPushState -> DoGameStateJobs), which removes the screen.
        private void SkipIntroVideo(VideoPlaybackState video)
        {
            if (ReferenceEquals(video, _skippedVideo))
            {
                return;
            }

            if (!ReferenceEquals(video, _observedVideo))
            {
                _observedVideo = video;
                LastStep = "Intro video active";
                return;
            }

            _skippedVideo = video;
            LastStep = "Skipped intro video";
            video.OnVideoFinished();
        }

        private bool ApplyFixedChoice(CharacterCreationManager manager, CharacterCreationStageBase stage)
        {
            CharacterCreationContent content = manager.CharacterCreationContent;

            if (stage is CharacterCreationCultureStage)
            {
                return SelectCulture(manager, content);
            }

            if (stage is CharacterCreationNarrativeStage)
            {
                return CompleteNarrativeMenus(manager);
            }

            if (stage is CharacterCreationBannerEditorStage)
            {
                AcceptDefaultBanner(content);
                return true;
            }

            if (stage is CharacterCreationClanNamingStage)
            {
                NameClan();
                return true;
            }

            if (stage is CharacterCreationReviewStage)
            {
                NameHero();
                return true;
            }

            // Face generator: the view's NextStage only invokes the affirmative action; the face stays
            // at its default. Options: the VM's OnNextStage only invokes the affirmative action; the
            // campaign keeps the default options created with the Campaign.
            if (stage is CharacterCreationFaceGeneratorStage || stage is CharacterCreationOptionsStage)
            {
                return true;
            }

            LastError = "Unknown character creation stage: " + stage.GetType().FullName;
            return false;
        }

        // Mirrors CharacterCreationCultureStageVM.OnNextStage (SetSelectedCulture) and
        // CharacterCreationCultureStageView.NextStage (SetMainCharacterName, fixed instead of generated).
        private bool SelectCulture(CharacterCreationManager manager, CharacterCreationContent content)
        {
            CultureObject culture = content.GetCultures().FirstOrDefault(c => c.StringId == CultureId);
            if (culture == null)
            {
                LastError = "Culture '" + CultureId + "' is not offered in character creation.";
                return false;
            }

            content.SetSelectedCulture(culture, manager);
            content.SetMainCharacterName(HarnessName);
            return true;
        }

        // Mirrors the narrative stage: the view ctor calls StartNarrativeStage, each click calls
        // OnNarrativeMenuOptionSelected, and CharacterCreationNarrativeStageVM.OnNextStage calls
        // TrySwitchToNextMenu until it returns false (it applies the last menu's consequence too).
        private bool CompleteNarrativeMenus(CharacterCreationManager manager)
        {
            if (manager.CurrentMenu == null)
            {
                manager.StartNarrativeStage();
            }

            // Bound the walk by the menu count so a malformed menu chain cannot loop forever.
            int remainingMenus = manager.CharacterCreationMenuCount;
            do
            {
                if (manager.CurrentMenu == null || remainingMenus-- <= 0)
                {
                    LastError = "Narrative menu chain is broken or longer than the menu count.";
                    return false;
                }

                NarrativeMenuOption option = FindFixedOption(manager);
                if (option == null)
                {
                    return false;
                }

                manager.OnNarrativeMenuOptionSelected(option);
            }
            while (manager.TrySwitchToNextMenu());

            return true;
        }

        private NarrativeMenuOption FindFixedOption(CharacterCreationManager manager)
        {
            string menuId = manager.CurrentMenu.StringId;
            string optionId;
            if (!OptionIdByMenuId.TryGetValue(menuId, out optionId))
            {
                LastError = "No fixed option for narrative menu '" + menuId + "'.";
                return null;
            }

            NarrativeMenuOption option = manager.GetSuitableNarrativeMenuOptions()
                .FirstOrDefault(o => o.StringId == optionId);
            if (option == null)
            {
                LastError = "Option '" + optionId + "' is not available in narrative menu '" + menuId + "'.";
            }

            return option;
        }

        // Mirrors CharacterCreationBannerEditorView.AffirmativeAction with the untouched default banner
        // (the view is constructed with Clan.PlayerClan.Banner).
        private static void AcceptDefaultBanner(CharacterCreationContent content)
        {
            Clan playerClan = Clan.PlayerClan;
            Banner banner = playerClan.Banner;
            uint primaryColor = banner.GetPrimaryColor();
            uint firstIconColor = banner.GetFirstIconColor();
            playerClan.Color = primaryColor;
            playerClan.Color2 = firstIconColor;
            playerClan.UpdateBannerColor(primaryColor, firstIconColor);
            content.SetMainClanBanner(banner);
        }

        // Mirrors CharacterCreationClanNamingStageView.NextStage with a fixed clan name.
        private static void NameClan()
        {
            TextObject clanName = GameTexts.FindText("str_generic_clan_name");
            clanName.SetTextVariable("CLAN_NAME", new TextObject(HarnessName));
            Clan.PlayerClan.ChangeClanName(clanName, clanName);
        }

        // Mirrors CharacterCreationReviewStageView.NextStage with a fixed hero name.
        private static void NameHero()
        {
            int gender = Hero.MainHero.IsFemale ? 1 : 0;
            TextObject firstName = GameTexts.FindText("str_generic_character_firstname");
            firstName.SetTextVariable("CHARACTER_FIRSTNAME", new TextObject(HarnessName));
            firstName.SetTextVariable("CHARACTER_GENDER", gender);
            TextObject fullName = GameTexts.FindText("str_generic_character_name");
            fullName.SetTextVariable("CHARACTER_NAME", new TextObject(HarnessName));
            fullName.SetTextVariable("CHARACTER_GENDER", gender);
            Hero.MainHero.SetName(fullName, firstName);
        }
    }
}
