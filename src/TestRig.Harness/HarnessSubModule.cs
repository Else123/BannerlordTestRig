using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.ExceptionServices;
using System.Text;
using System.Threading;
using TestRig.Harness.Logic;
using TaleWorlds.CampaignSystem;
using TaleWorlds.CampaignSystem.CharacterCreationContent;
using TaleWorlds.CampaignSystem.GameState;
using TaleWorlds.Core;
using TaleWorlds.Library;
using TaleWorlds.MountAndBlade;

namespace TestRig.Harness
{
    /// <summary>
    /// Entry point of the debug-only soak harness. Inert unless the runner left a run.cfg in
    /// Documents\Mount and Blade II Bannerlord\TestRig\harness. When armed it samples the game
    /// once per application tick, asks <see cref="HarnessRun"/> what to do and executes that action;
    /// it makes no decisions of its own. Progress goes to harness.log, the outcome to run-result.json.
    /// </summary>
    public class HarnessSubModule : MBSubModuleBase
    {
        // The setter is unclamped (15 is the vanilla non-dev ceiling of the speed cheat). Measured on the
        // test PC 2026-11-01 (L1, 10 days, all four mods): running phase 58.7 s at 15, 33.9 s at 30,
        // 27.5 s at 60 - above 30 the CPU is the limit while each campaign step keeps growing.
        private const float SpeedUpMultiplier = 30f;

        private const string NavalDlcModuleId = "NavalDLC";

        private const string ResultFileName = "run-result.json";

        // Writing the temp file or replacing the target fails with an IOException (or, for a target
        // pending delete or held by a scanner, UnauthorizedAccessException) while a reader (the
        // agent, a scanner) has it open; that is transient, so retry briefly (see IoRetry).
        private const int ResultReplaceAttempts = 4;
        private const int ResultReplaceDelayMilliseconds = 75;

        // Crash localization (2026-10-31: the first live run died within ~1 s of reaching the map
        // with no managed trace anywhere). Per-tick lines for the first map ticks, then quiet.
        private const int MapTicksToTrace = 120;
        private const int HarnessEffectsToTrace = 20;

        private static readonly Encoding Utf8NoBom = new UTF8Encoding(false);

        // Set while this thread is inside the first-chance handler: an exception thrown by the
        // handler itself (or by Log) must not recurse into it.
        [ThreadStatic]
        private static bool _inExceptionHandler;

        // Distinct LogError messages already logged; guarded by _logLock (LogError also runs from
        // the unhandled-exception handler on any thread).
        private readonly HashSet<string> _loggedErrors = new HashSet<string>();
        private readonly System.Diagnostics.Stopwatch _clock = new System.Diagnostics.Stopwatch();

        // Serializes harness.log appends: first-chance exceptions also arrive on background threads.
        private readonly object _logLock = new object();
        private readonly ExceptionLogBudget _exceptionBudget = new ExceptionLogBudget(
            maxDistinctFull: 100, repeatsPerKey: 3, maxLines: 400);

        // Run-wide counters for run-result.json; guarded by _logLock like the budget.
        private readonly ExceptionStats _exceptionStats = new ExceptionStats();

        // Bounds the own-exception stack walks (see OwnClassificationCache), keyed by exception type
        // and throw site without the message (ExceptionKey.Own); guarded by _logLock.
        private readonly OwnClassificationCache _ownCache = new OwnClassificationCache();

        // Simple-name cache for the own-exception stack walk; guarded by _logLock.
        private readonly Dictionary<Assembly, string> _assemblyNames = new Dictionary<Assembly, string>();
        private bool _ownCheckFailureLogged;

        // Serializes run-result.json writes: the unhandled-exception handler can write on any thread.
        private readonly object _resultLock = new object();

        // Null until a valid config is loaded; immutable afterwards, so the handler reads it unlocked.
        private OwnAssemblyClassifier _ownAssemblies;
        private IReadOnlyList<ModuleEntry> _modules = new ModuleEntry[0];

        private int _mapTicksTraced;
        private HarnessAction _lastMapAction = HarnessAction.None;
        private int _speedChangesTraced;
        private int _inquiriesClosedTraced;
        private int _timeStopBlockedTraced;
        private bool _timeStopBlocked;
        private bool? _timeRunLogged;
        private int _scenariosFinishedWritten;

        private string _harnessDirectory;
        private RunConfig _config;
        private string _configError;
        private HarnessRun _run;
        private CharacterCreationDriver _driver;
        private HarnessCampaignBehavior _behavior;

        private bool _gameEnded;
        private bool _endGameCalled;
        private bool _quitCalled;
        private string _lastDriverStep;
        private string _lastDriverError;
        private int _lastHeartbeatDay = -1;

        private double RealSeconds
        {
            get { return _clock.Elapsed.TotalSeconds; }
        }

        protected override void OnSubModuleLoad()
        {
            base.OnSubModuleLoad();

            try
            {
                LoadConfig();
                if (_config != null)
                {
                    InstallExceptionTrail();
                }
            }
            catch (Exception e)
            {
                LogError("OnSubModuleLoad", e);
            }
        }

        public override void OnInitialState()
        {
            base.OnInitialState();

            try
            {
                // Also called when the game returns to the main menu after EndGame: arm only once.
                if (_config == null || _run != null || _configError != null)
                {
                    return;
                }

                _clock.Start();
                if (_config.Scenarios.Count == 0)
                {
                    _run = new HarnessRun(_config, RealSeconds);
                }
                else
                {
                    ScenarioRunner runner = PrepareScenarios();
                    if (runner == null)
                    {
                        return;
                    }

                    _run = new HarnessRun(_config, RealSeconds, runner);
                }

                Log("Armed, phase " + _run.Phase);
            }
            catch (Exception e)
            {
                LogError("OnInitialState", e);
            }
        }

        // Discovery runs here, not in OnSubModuleLoad: by the initial state every module's assemblies
        // are loaded. Any failure is a config error, so the process quits on the next tick instead of
        // idling until the runner's hard timeout.
        private ScenarioRunner PrepareScenarios()
        {
            try
            {
                ScenarioDiscoveryResult discovery = ScenarioDiscovery.Discover(AppDomain.CurrentDomain.GetAssemblies());
                foreach (string note in discovery.Notes)
                {
                    Log("Scenario discovery: " + OneLine(note));
                }

                foreach (IScenario scenario in discovery.Scenarios)
                {
                    Log("Scenario discovered: " + scenario.Id + " (" + scenario.GetType().FullName
                        + ", assembly " + scenario.GetType().Assembly.GetName().Name + ")");
                }

                Log("Scenario discovery: " + discovery.Scenarios.Count + " found, requested " + string.Join(",", _config.Scenarios));

                ScenarioResolution resolution = ScenarioRunner.Resolve(_config.Scenarios, discovery.Scenarios);
                if (!resolution.IsValid)
                {
                    FailScenarioConfig(discovery.WithNotes(resolution.Error));
                    return null;
                }

                return new ScenarioRunner(resolution.Scenarios, m => Log(OneLine(m)));
            }
            catch (Exception e)
            {
                FailScenarioConfig("scenario discovery threw " + e.GetType().Name + ": " + e.Message);
                return null;
            }
        }

        private void FailScenarioConfig(string error)
        {
            _configError = error;
            Log("Invalid scenarios (config:" + OneLine(error) + "); quitting on the next tick");
            WriteResult(RunResult.ForConfigError(error, _modules, _config.Scenarios));
        }

        protected override void InitializeGameStarter(Game game, IGameStarter gameStarterObject)
        {
            base.InitializeGameStarter(game, gameStarterObject);

            try
            {
                if (_run != null && game.GameType is Campaign && gameStarterObject is CampaignGameStarter campaignStarter)
                {
                    _behavior = new HarnessCampaignBehavior(Log);
                    campaignStarter.AddBehavior(_behavior);
                    Log("Registered harness campaign behavior");
                }
            }
            catch (Exception e)
            {
                LogError("InitializeGameStarter", e);
            }
        }

        public override void OnGameEnd(Game game)
        {
            base.OnGameEnd(game);

            try
            {
                if (_run != null)
                {
                    _gameEnded = true;
                    Log("OnGameEnd fired");
                }
            }
            catch (Exception e)
            {
                LogError("OnGameEnd", e);
            }
        }

        protected override void OnApplicationTick(float dt)
        {
            base.OnApplicationTick(dt);

            try
            {
                if (_configError != null)
                {
                    // Invalid config: the result is already written; do not let the runner wait for its timeout.
                    Quit();
                }
                else if (_run != null && _run.Phase != HarnessPhase.Quit)
                {
                    TickRun();
                }
            }
            catch (Exception e)
            {
                LogError("OnApplicationTick", e);
            }
        }

        private void LoadConfig()
        {
            // No reference to any mod assembly by design; the folder is shared by all mods under test.
            _harnessDirectory = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments),
                "Mount and Blade II Bannerlord",
                "TestRig",
                "harness");
            string configPath = Path.Combine(_harnessDirectory, "run.cfg");

            RunConfigResult result;
            try
            {
                // run.cfg belongs to the runner: read it, never delete it.
                string text = File.Exists(configPath) ? File.ReadAllText(configPath, Encoding.UTF8) : null;
                result = RunConfig.Parse(text);
            }
            catch (Exception e)
            {
                result = null;
                _configError = "read failed: " + e.Message;
            }

            if (result != null && result.Status == RunConfigStatus.Inert)
            {
                // Normal play: one line, no files, no directory.
                TaleWorlds.Library.Debug.Print("[TestRig.Harness] No run.cfg - harness inert.");
                return;
            }

            if (result != null && result.Status == RunConfigStatus.Invalid)
            {
                _configError = result.Error;
            }

            _modules = ReadLoadedModules();

            if (_configError != null)
            {
                Log("Invalid run.cfg (config:" + OneLine(_configError) + "); quitting on the first tick");
                WriteResult(RunResult.ForConfigError(_configError, _modules));
                return;
            }

            _config = result.Config;
            _ownAssemblies = new OwnAssemblyClassifier(_config.OwnAssemblies);
            Log(string.Format(
                CultureInfo.InvariantCulture,
                "Start: seed={0} days={1} mode={2} stallMinutes={3} budgetMinutes={4} navalDlcLoaded={5}",
                _config.Seed,
                _config.Days,
                _config.Mode,
                _config.StallMinutes,
                _config.BudgetMinutes,
                IsNavalDlcLoaded()));
            Log("Own assemblies: " + (_config.OwnAssemblies.Count == 0 ? "none" : string.Join(",", _config.OwnAssemblies)));
        }

        // Ids in load order with the version as SubModule.xml states it ("v1.4.8"). Never fails the run.
        private IReadOnlyList<ModuleEntry> ReadLoadedModules()
        {
            try
            {
                var modules = new List<ModuleEntry>();
                foreach (string id in TaleWorlds.Engine.Utilities.GetModulesNames())
                {
                    if (string.IsNullOrEmpty(id))
                    {
                        continue;
                    }

                    // One broken module must not drop the whole list: keep its id, version unknown.
                    string version;
                    try
                    {
                        TaleWorlds.ModuleManager.ModuleInfo info = TaleWorlds.ModuleManager.ModuleHelper.GetModuleInfo(id);
                        version = info == null ? null : FormatVersion(info.Version);
                    }
                    catch (Exception e)
                    {
                        version = null;
                        Log("Modules: reading module " + id + " failed, version unknown: " + OneLine(e.Message));
                    }

                    modules.Add(new ModuleEntry(id, version));
                }

                Log("Modules: " + modules.Count + " loaded");
                return modules;
            }
            catch (Exception e)
            {
                Log("Modules: reading the loaded modules failed, run-result.json lists none: " + OneLine(e.Message));
                return new ModuleEntry[0];
            }
        }

        // ApplicationVersion.ToString() appends the change set ("v1.4.8.0"); SubModule.xml states
        // prefix + major.minor.revision only.
        private static string FormatVersion(ApplicationVersion version)
        {
            if (version.ApplicationVersionType == ApplicationVersionType.Invalid)
            {
                return null;
            }

            return ApplicationVersion.GetPrefix(version.ApplicationVersionType)
                + version.Major.ToString(CultureInfo.InvariantCulture) + "."
                + version.Minor.ToString(CultureInfo.InvariantCulture) + "."
                + version.Revision.ToString(CultureInfo.InvariantCulture);
        }

        private void TickRun()
        {
            double now = RealSeconds;
            HarnessObservation observation = Observe(now);

            if (_run.Phase == HarnessPhase.Running)
            {
                LogHeartbeat(observation.DaysElapsed);
            }

            HarnessPhase before = _run.Phase;
            int mapEventsBefore = _run.PlayerMapEvents;
            HarnessAction action = _run.Tick(observation);
            RecordFinishedScenarios(action, now);
            if (_run.Phase != before)
            {
                Log("Phase " + before + " -> " + _run.Phase + " (action " + action
                    + ", status " + _run.Status + ", reason " + (_run.Reason ?? "-") + ")");

                if (_run.Phase == HarnessPhase.Map)
                {
                    StartMapExceptionWindow();
                }
            }

            // HarnessRun owns the rising-edge detection; log the tick on which it counted a new event.
            if (_run.PlayerMapEvents > mapEventsBefore)
            {
                Log("Map event: player entered a map event (day=" + observation.DaysElapsed
                    + ", phase " + _run.Phase + ", playerMapEvents=" + _run.PlayerMapEvents + ")");
            }

            Execute(action, now);

            if (_run.Phase == HarnessPhase.Map || _run.Phase == HarnessPhase.Running)
            {
                TraceMapTick(action);
            }

            // The driver needs a call every tick from the start request on, whatever Tick returned
            // (it also skips the intro video, which HarnessRun does not observe).
            if (_driver != null
                && (_run.Phase == HarnessPhase.StartRequested || _run.Phase == HarnessPhase.CharacterCreation))
            {
                AdvanceCreation();
            }
        }

        private HarnessObservation Observe(double now)
        {
            GameState active = GameStateManager.Current == null ? null : GameStateManager.Current.ActiveState;
            return new HarnessObservation
            {
                RealSeconds = now,
                MainMenuActive = active is InitialState,
                CharacterCreationActive = active is CharacterCreationState,
                MapActive = active is MapState,
                InGame = Game.Current != null,
                GameEnded = _gameEnded,
                DaysElapsed = _behavior == null ? 0 : _behavior.DaysElapsed,
                PlayerInMapEvent = _behavior != null && _behavior.PlayerInMapEvent,
            };
        }

        private void Execute(HarnessAction action, double now)
        {
            switch (action)
            {
                case HarnessAction.StartNewGame:
                    _driver = new CharacterCreationDriver();
                    MBGameManager.StartNewGame(new SeededSandBoxGameManager(_config.Seed));
                    break;

                case HarnessAction.SetupMap:
                    if (_behavior == null)
                    {
                        Log("SetupMap: harness campaign behavior is not registered; player not parked");
                    }
                    else
                    {
                        _behavior.Park();
                    }

                    CloseInquiry();
                    break;

                case HarnessAction.KeepRunning:
                    LogTimeTransition();
                    if (_run.TimeShouldRun)
                    {
                        KeepTimeRunning();
                    }
                    else
                    {
                        KeepTimeStopped();
                    }

                    break;

                case HarnessAction.RequestEndGame:
                    // Record first, so a crash inside EndGame still leaves a result behind.
                    WriteResult(BuildResult(now));
                    RequestEndGame();
                    break;

                case HarnessAction.QuitProcess:
                    WriteResult(BuildResult(now));
                    Quit();
                    break;
            }
        }

        private void AdvanceCreation()
        {
            _driver.Advance();

            if (_driver.LastStep != _lastDriverStep)
            {
                _lastDriverStep = _driver.LastStep;
                Log("Creation: " + _lastDriverStep);
            }

            if (_driver.LastError != _lastDriverError)
            {
                _lastDriverError = _driver.LastError;
                Log("Creation error: " + _lastDriverError);
            }
        }

        // Re-asserted every tick: menus and behaviours set Stop, and the setter is a no-op while locked.
        private void KeepTimeRunning()
        {
            CloseInquiry();

            Campaign campaign = Campaign.Current;
            if (campaign == null)
            {
                return;
            }

            CampaignTimeControlMode modeBefore = campaign.TimeControlMode;
            float speedBefore = campaign.SpeedUpMultiplier;

            campaign.SpeedUpMultiplier = SpeedUpMultiplier;
            campaign.TimeControlMode = CampaignTimeControlMode.UnstoppableFastForward;

            if ((modeBefore != CampaignTimeControlMode.UnstoppableFastForward || speedBefore != SpeedUpMultiplier)
                && _speedChangesTraced < HarnessEffectsToTrace)
            {
                _speedChangesTraced++;
                Log("KeepRunning: timeControl " + modeBefore + " -> " + campaign.TimeControlMode
                    + ", speed " + speedBefore.ToString(CultureInfo.InvariantCulture)
                    + " -> " + campaign.SpeedUpMultiplier.ToString(CultureInfo.InvariantCulture)
                    + ", timeLock=" + campaign.TimeControlModeLock
                    + ", mapScreen=" + MapScreenProbe.Describe());
            }
        }

        // Scenario mode between Days(n) steps. Stop makes Campaign.TickMapTime advance by 0; re-asserted
        // every tick because menus, hotkeys and behaviours set other modes. The setter is a no-op while
        // TimeControlModeLock is set; that is only reported, the lock is not overridden.
        private void KeepTimeStopped()
        {
            CloseInquiry();

            Campaign campaign = Campaign.Current;
            if (campaign == null)
            {
                return;
            }

            campaign.TimeControlMode = CampaignTimeControlMode.Stop;

            bool stopped = campaign.TimeControlMode == CampaignTimeControlMode.Stop;
            if (!stopped && !_timeStopBlocked && _timeStopBlockedTraced < HarnessEffectsToTrace)
            {
                _timeStopBlockedTraced++;
                Log("KeepStopped: time could not be stopped, timeControl=" + campaign.TimeControlMode
                    + ", timeLock=" + campaign.TimeControlModeLock);
            }

            _timeStopBlocked = !stopped;
        }

        // One line per change between running and stopped time, not per tick.
        private void LogTimeTransition()
        {
            bool shouldRun = _run.TimeShouldRun;
            if (_timeRunLogged.HasValue && _timeRunLogged.Value == shouldRun)
            {
                return;
            }

            _timeRunLogged = shouldRun;
            Log(shouldRun
                ? "Time: run (" + CampaignTimeControlMode.UnstoppableFastForward + ", speed "
                    + SpeedUpMultiplier.ToString(CultureInfo.InvariantCulture) + ")"
                : "Time: stop (" + CampaignTimeControlMode.Stop + ")");
        }

        // run-result.json after every ended scenario; the final actions write it themselves.
        private void RecordFinishedScenarios(HarnessAction action, double now)
        {
            int finished = _run.ScenariosFinished;
            if (finished == _scenariosFinishedWritten)
            {
                return;
            }

            _scenariosFinishedWritten = finished;
            if (action != HarnessAction.RequestEndGame && action != HarnessAction.QuitProcess)
            {
                WriteResult(BuildResult(now));
            }
        }

        // Closes one inquiry per call; the query manager then shows the next queued one.
        private void CloseInquiry()
        {
            if (InformationManager.IsAnyInquiryActive())
            {
                if (_inquiriesClosedTraced < HarnessEffectsToTrace)
                {
                    _inquiriesClosedTraced++;
                    Log("HideInquiry: closing the active inquiry");
                }

                InformationManager.HideInquiry();
            }
        }

        // One line per harness tick for the first map ticks, plus every change of the harness
        // action on the map. Written before the next frame runs, so after a crash the last line
        // says how far the map got and what the harness had just done.
        private void TraceMapTick(HarnessAction action)
        {
            if (action != _lastMapAction)
            {
                Log("Map action: " + _lastMapAction + " -> " + action);
                _lastMapAction = action;
            }

            if (_mapTicksTraced >= MapTicksToTrace)
            {
                return;
            }

            _mapTicksTraced++;
            Campaign campaign = Campaign.Current;
            string campaignState = campaign == null
                ? "campaign=none"
                : "hours=" + CampaignTime.Now.ToHours.ToString("F2", CultureInfo.InvariantCulture)
                    + " timeControl=" + campaign.TimeControlMode
                    + " speed=" + campaign.SpeedUpMultiplier.ToString(CultureInfo.InvariantCulture)
                    + " campaignDt=" + campaign.CampaignDt.ToString("F4", CultureInfo.InvariantCulture)
                    + " campaignTicks=" + campaign.CurrentTickCount;
            Log("Map tick " + _mapTicksTraced + ": action=" + action
                + " frame=" + TaleWorlds.Engine.Utilities.EngineFrameNo
                + " " + campaignState
                + " mapScreen=" + MapScreenProbe.Describe()
                + " loadingWindow=" + TaleWorlds.Engine.LoadingWindow.IsLoadingWindowActive
                + " inquiryActive=" + InformationManager.IsAnyInquiryActive());
        }

        private void InstallExceptionTrail()
        {
            AppDomain.CurrentDomain.FirstChanceException += OnFirstChanceException;
            AppDomain.CurrentDomain.UnhandledException += OnUnhandledException;
            Log("Exception trail armed (first-chance + unhandled, all threads)");
        }

        // Map exceptions must not be lost to a budget spent during module loading and creation.
        private void StartMapExceptionWindow()
        {
            int before;
            lock (_logLock)
            {
                before = _exceptionBudget.Observed;
                _exceptionBudget.StartWindow();
            }

            Log("Exception trail: new window for the map (" + before + " first-chance exceptions before)");
        }

        // FirstChanceException runs on the throwing thread before any handler: it sees the exception
        // even when the engine's native crash handler (Watchdog debugger) takes the process down
        // afterwards and no managed handler or UnhandledException ever runs.
        private void OnFirstChanceException(object sender, FirstChanceExceptionEventArgs args)
        {
            if (_inExceptionHandler)
            {
                return;
            }

            _inExceptionHandler = true;
            try
            {
                Exception e = args.Exception;
                string site = ThrowSite(e);
                string typeName = e.GetType().FullName;
                string key = ExceptionKey.Full(typeName, e.Message, site);

                // Read once: the handler runs on any thread and must see one consistent classifier.
                OwnAssemblyClassifier classifier = _ownAssemblies;
                bool classify = classifier != null && !classifier.IsEmpty;

                int occurrence;
                ExceptionLogDecision decision;
                OwnLookup lookup = OwnLookup.Unknown;
                bool own = false;
                string ownKey = classify ? ExceptionKey.Own(typeName, site) : null;
                lock (_logLock)
                {
                    decision = _exceptionBudget.Next(key, out occurrence);
                    if (classify)
                    {
                        lookup = _ownCache.Lookup(ownKey, out own);
                    }
                }

                // At most one stack capture per exception, shared by the own check and the full log
                // line; repeats of an already classified key and dropped exceptions capture nothing.
                System.Diagnostics.StackTrace callers = lookup == OwnLookup.Walk || decision == ExceptionLogDecision.Full
                    ? new System.Diagnostics.StackTrace(1, false)
                    : null;

                lock (_logLock)
                {
                    if (lookup == OwnLookup.Walk && TryClassifyOwn(classifier, callers, out own))
                    {
                        _ownCache.Store(ownKey, own);
                    }

                    _exceptionStats.RecordFirstChance(key, own);
                }

                if (decision == ExceptionLogDecision.Drop)
                {
                    return;
                }

                string thread = "thread " + Thread.CurrentThread.ManagedThreadId
                    + (Thread.CurrentThread.IsBackground ? " bg" : string.Empty);
                if (decision == ExceptionLogDecision.Full)
                {
                    // e.ToString() holds only the throwing frame at this point; the live stack
                    // below it shows who called into the throwing code.
                    Log("FirstChance #" + occurrence + " [" + thread + "]: " + OneLine(e.ToString())
                        + " || caller stack: " + OneLine(callers.ToString()));
                }
                else
                {
                    Log("FirstChance #" + occurrence + " (repeat) [" + thread + "]: " + key);
                }
            }
            catch (Exception)
            {
                // Never throw from an exception notification.
            }
            finally
            {
                _inExceptionHandler = false;
            }
        }

        // The process terminates right after this handler, before any tick could write the result,
        // so the record is written here (best effort): a run still Running becomes Aborted with reason
        // "unhandled:<phase>" (scenario Failed), a run that already has a final status is rewritten
        // with the updated exception counts and its timing as of the final transition. Nothing is written before the run is armed (no HarnessRun yet).
        private void OnUnhandledException(object sender, UnhandledExceptionEventArgs args)
        {
            try
            {
                ExceptionSummary exceptions;
                lock (_logLock)
                {
                    _exceptionStats.RecordUnhandled();
                    exceptions = _exceptionStats.Summary();
                }

                Log("UnhandledException (terminating=" + args.IsTerminating + "): "
                    + OneLine(Convert.ToString(args.ExceptionObject, CultureInfo.InvariantCulture)));

                HarnessRun run = _run;
                if (args.IsTerminating && run != null)
                {
                    WriteResult(run.ToUnhandledResult(RealSeconds, _modules, exceptions));
                }
            }
            catch (Exception)
            {
                // The process is going down; nothing else to do.
            }
        }

        // Classifies the captured live stack of the throwing thread (at first-chance time e.StackTrace
        // holds only the throw frame; the live stack holds the whole chain). Only the declaring types'
        // assemblies are read (no file/line info); harness frames (this handler) are skipped. Returns
        // false with own = false when the check throws: it must never take the handler down.
        // Caller holds _logLock.
        private bool TryClassifyOwn(OwnAssemblyClassifier classifier, System.Diagnostics.StackTrace callers, out bool own)
        {
            try
            {
                Assembly harness = typeof(HarnessSubModule).Assembly;
                var names = new List<string>();
                System.Diagnostics.StackFrame[] frames = callers.GetFrames();
                if (frames != null)
                {
                    foreach (System.Diagnostics.StackFrame frame in frames)
                    {
                        MethodBase method = frame.GetMethod();
                        Type type = method == null ? null : method.DeclaringType;
                        Assembly assembly = type == null ? null : type.Assembly;
                        if (assembly != null && assembly != harness)
                        {
                            names.Add(SimpleName(assembly));
                        }
                    }
                }

                own = classifier.IsOwn(names);
                return true;
            }
            catch (Exception e)
            {
                own = false;
                if (!_ownCheckFailureLogged)
                {
                    _ownCheckFailureLogged = true;
                    Log("Own-assembly check failed, counted as not own (logged once): " + OneLine(e.Message));
                }

                return false;
            }
        }

        // Caller holds _logLock.
        private string SimpleName(Assembly assembly)
        {
            string name;
            if (!_assemblyNames.TryGetValue(assembly, out name))
            {
                name = assembly.GetName().Name;
                _assemblyNames[assembly] = name;
            }

            return name;
        }

        private RunResult BuildResult(double now)
        {
            ExceptionSummary exceptions;
            lock (_logLock)
            {
                exceptions = _exceptionStats.Summary();
            }

            return _run.ToResult(now, _modules, exceptions);
        }

        private static string ThrowSite(Exception e)
        {
            MethodBase site = e.TargetSite;
            return site == null
                ? ExceptionKey.Site(null, null)
                : ExceptionKey.Site(site.DeclaringType == null ? null : site.DeclaringType.FullName, site.Name);
        }

        private void RequestEndGame()
        {
            if (_endGameCalled)
            {
                return;
            }

            _endGameCalled = true;

            // EndGame is async void: it awaits MBGameManager.Current.IsLoaded and then dereferences
            // Game.Current.GameStateManager unchecked. Called before the game is loaded (a watchdog
            // abort mid-load), that continuation throws outside our try/catch. Only with a loaded
            // manager and a game does it run synchronously up to CleanStates.
            MBGameManager manager = MBGameManager.Current;
            if (manager == null || !manager.IsLoaded || Game.Current == null)
            {
                // No OnGameEnd will follow and InGame may stay true: the result is already written,
                // so quit directly instead of waiting in Ending for the end-stall.
                Log("RequestEndGame: no loaded game (manager " + (manager == null ? "none" : "loaded=" + manager.IsLoaded)
                    + ", game " + (Game.Current != null) + "), skipping EndGame");
                Quit();
                return;
            }

            Log("Calling MBGameManager.EndGame");
            MBGameManager.EndGame();
        }

        private void Quit()
        {
            if (_quitCalled)
            {
                return;
            }

            _quitCalled = true;
            Log("Calling Utilities.QuitGame");
            TaleWorlds.Engine.Utilities.QuitGame();
        }

        private void LogHeartbeat(int day)
        {
            if (day == _lastHeartbeatDay)
            {
                return;
            }

            _lastHeartbeatDay = day;
            Campaign campaign = Campaign.Current;
            Log("Heartbeat: day=" + day
                + " timeControl=" + (campaign == null ? "n/a" : campaign.TimeControlMode.ToString())
                + " timeLock=" + (campaign == null ? "n/a" : campaign.TimeControlModeLock.ToString())
                + " inquiryActive=" + InformationManager.IsAnyInquiryActive()
                + " playerInMapEvent=" + (_behavior != null && _behavior.PlayerInMapEvent));
        }

        private static string IsNavalDlcLoaded()
        {
            try
            {
                return Array.IndexOf(TaleWorlds.Engine.Utilities.GetModulesNames(), NavalDlcModuleId) >= 0 ? "True" : "False";
            }
            catch (Exception e)
            {
                return "unknown (" + e.Message + ")";
            }
        }

        // Atomic for readers: the record goes to a temp file in the same folder, which then replaces
        // (or, on the first write, becomes) the target in one rename - never a half-written file.
        private void WriteResult(RunResult result)
        {
            if (_harnessDirectory == null)
            {
                return;
            }

            try
            {
                lock (_resultLock)
                {
                    Directory.CreateDirectory(_harnessDirectory);
                    string target = Path.Combine(_harnessDirectory, ResultFileName);
                    string temp = target + ".tmp";
                    string json = RunResultWriter.Write(result);

                    // The temp file is rewritten on every attempt: a failed Replace may leave it gone.
                    IoRetry.Run(
                        () =>
                        {
                            File.WriteAllText(temp, json, Utf8NoBom);
                            if (File.Exists(target))
                            {
                                File.Replace(temp, target, null);
                            }
                            else
                            {
                                File.Move(temp, target);
                            }
                        },
                        ResultReplaceAttempts,
                        ResultReplaceDelayMilliseconds,
                        Thread.Sleep);
                }
            }
            catch (Exception e)
            {
                LogError("WriteResult", e);
            }
        }

        private void Log(string message)
        {
            if (_harnessDirectory == null)
            {
                return;
            }

            try
            {
                string line = RealSeconds.ToString("F1", CultureInfo.InvariantCulture) + " " + message + "\n";

                // AppendAllText opens, writes and closes: each line reaches the OS before Log returns,
                // so it survives a process kill right after.
                lock (_logLock)
                {
                    Directory.CreateDirectory(_harnessDirectory);
                    File.AppendAllText(Path.Combine(_harnessDirectory, "harness.log"), line, Utf8NoBom);
                }
            }
            catch (Exception)
            {
                // A failing log must never reach the game.
            }
        }

        // Logs each distinct failure once, so an exception repeating every frame does not flood the log.
        // Callers must not hold _resultLock (lock order is _resultLock -> _logLock only); the set is
        // updated under _logLock, the output happens after it is released.
        private void LogError(string where, Exception e)
        {
            try
            {
                string message = where + " failed: " + OneLine(e.ToString());
                bool first;
                lock (_logLock)
                {
                    first = _loggedErrors.Add(message);
                }

                if (first)
                {
                    TaleWorlds.Library.Debug.Print("[TestRig.Harness] " + message);
                    Log(message);
                }
            }
            catch (Exception)
            {
                // Never throw into the engine.
            }
        }

        private static string OneLine(string text)
        {
            return text.Replace("\r", " ").Replace("\n", " ");
        }
    }
}
