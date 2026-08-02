using System.Collections;
using System.Globalization;
using System.Reflection;
using System.Text.RegularExpressions;
using FishNet;
using FishNet.Connection;
using FishNet.Managing.Server;
using FishNet.Transporting;
using HarmonyLib;
using MelonLoader;
using ScheduleOne.DevUtilities;
using ScheduleOne.Combat;
using ScheduleOne.Money;
using ScheduleOne.Networking;
using ScheduleOne.NPCs;
using ScheduleOne.Persistence;
using ScheduleOne.Persistence.Datas;
using ScheduleOne.PlayerScripts;
using Steamworks;
using UnityEngine;
using UnityEngine.SceneManagement;

[assembly: MelonInfo(typeof(S1NetGuard.AdmissionRepro.ProbeMod), "S1NetGuard Admission Repro", "0.1.0", "Bars")]
[assembly: MelonGame("TVGS", "Schedule I")]

namespace S1NetGuard.AdmissionRepro;

public sealed class ProbeMod : MelonMod
{
    private const string Prefix = "[S1NG-Repro]";
    private static readonly object EvidenceLock = new();
    private static string evidencePath = string.Empty;
    private static string role = string.Empty;
    private static string scenario = string.Empty;
    private static ulong expectedPeerSteamId;
    private static ulong explicitHostSteamId;
    private static ulong explicitLobbyId;
    private static bool expectBlockedImpact;
    private static bool impactMoneyApplied;
    private static bool impactDialogueApplied;
    private static bool impactCombatApplied;
    private static float impactMoneyBefore;
    private static float impactMoneyAfter;
    private static string impactNpcId = string.Empty;

    private Callback<LobbyCreated_t>? lobbyCreatedCallback;
    private Callback<LobbyEnter_t>? lobbyEnterCallback;
    private Callback<LobbyChatUpdate_t>? lobbyChatUpdateCallback;
    private bool started;

    public override void OnInitializeMelon()
    {
        ParseArguments();
        if (string.IsNullOrWhiteSpace(role) || string.IsNullOrWhiteSpace(scenario) || string.IsNullOrWhiteSpace(evidencePath))
        {
            MelonLogger.Error($"{Prefix} Missing required probe arguments.");
            return;
        }

        Directory.CreateDirectory(Path.GetDirectoryName(evidencePath)!);
        File.WriteAllText(evidencePath, string.Empty);
        Record("probe_initialized", ("applicationVersion", Application.version));

        var harmony = new HarmonyLib.Harmony("com.bars.s1netguard.admission-repro");
        PatchSteamApi(harmony);
        PatchFishNet(harmony);
        PatchImpactSinks(harmony);
    }

    public override void OnUpdate()
    {
        if (started || string.IsNullOrWhiteSpace(role))
        {
            return;
        }

        if (!SteamManager.Initialized || !Singleton<Lobby>.InstanceExists || !Singleton<LoadManager>.InstanceExists)
        {
            return;
        }

        started = true;
        lobbyCreatedCallback = Callback<LobbyCreated_t>.Create(OnLobbyCreated);
        lobbyEnterCallback = Callback<LobbyEnter_t>.Create(OnLobbyEntered);
        lobbyChatUpdateCallback = Callback<LobbyChatUpdate_t>.Create(OnLobbyChatUpdate);

        ulong localSteamId = SteamUser.GetSteamID().m_SteamID;
        bool expectedPeerIsFriend = expectedPeerSteamId != 0UL &&
                                    SteamFriends.HasFriend(new CSteamID(expectedPeerSteamId), EFriendFlags.k_EFriendFlagImmediate);
        Record(
            "steam_ready",
            ("localSteamId", localSteamId),
            ("expectedPeerSteamId", expectedPeerSteamId),
            ("expectedPeerIsImmediateFriend", expectedPeerIsFriend),
            ("scene", SceneManager.GetActiveScene().name));

        MelonCoroutines.Start(role == "host" ? RunHost() : RunClient());
    }

    private static void ParseArguments()
    {
        string[] args = Environment.GetCommandLineArgs();
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--s1ng-repro-role" && i + 1 < args.Length)
            {
                role = args[++i].Trim().ToLowerInvariant();
            }
            else if (args[i] == "--s1ng-repro-scenario" && i + 1 < args.Length)
            {
                scenario = args[++i].Trim().ToLowerInvariant();
            }
            else if (args[i] == "--s1ng-repro-evidence" && i + 1 < args.Length)
            {
                evidencePath = Path.GetFullPath(args[++i]);
            }
            else if (args[i] == "--s1ng-repro-peer" && i + 1 < args.Length)
            {
                ulong.TryParse(args[++i], NumberStyles.None, CultureInfo.InvariantCulture, out expectedPeerSteamId);
            }
            else if (args[i] == "--s1ng-repro-host-steamid" && i + 1 < args.Length)
            {
                ulong.TryParse(args[++i], NumberStyles.None, CultureInfo.InvariantCulture, out explicitHostSteamId);
            }
            else if (args[i] == "--s1ng-repro-lobby-id" && i + 1 < args.Length)
            {
                ulong.TryParse(args[++i], NumberStyles.None, CultureInfo.InvariantCulture, out explicitLobbyId);
            }
            else if (args[i] == "--s1ng-repro-expect-blocked-impact")
            {
                expectBlockedImpact = true;
            }
        }
    }

    private IEnumerator RunHost()
    {
        while (SceneManager.GetActiveScene().name != "Menu")
        {
            yield return null;
        }

        Record("host_create_lobby_requested", ("requestedType", ELobbyType.k_ELobbyTypeFriendsOnly));
        Singleton<Lobby>.Instance.CreateLobby();

        yield return WaitFor(() => Singleton<Lobby>.Instance.IsInLobby, 30f, "host_lobby_ready");
        if (!Singleton<Lobby>.Instance.IsInLobby)
        {
            yield break;
        }

        ulong lobbyId = ReadLobbyId();
        RecordLobbySnapshot("host_lobby_ready", lobbyId);

        if (scenario == "lobby")
        {
            yield return WaitFor(() => Singleton<Lobby>.Instance.PlayerCount >= 2, 45f, "host_observed_second_lobby_member");
            RecordLobbySnapshot("host_lobby_final", lobbyId);
            yield break;
        }

        string savePath = Path.Combine(Path.GetDirectoryName(evidencePath)!, "host-save");
        if (!LoadManager.TryLoadSaveInfo(savePath, -1, out SaveInfo saveInfo, requireGameFile: false))
        {
            Record("failure", ("phase", "host_load_save"), ("reason", "TryLoadSaveInfo returned false"), ("savePath", savePath));
            yield break;
        }

        Record("host_start_game", ("savePath", savePath), ("lobbyMembers", Singleton<Lobby>.Instance.PlayerCount));
        Singleton<LoadManager>.Instance.StartGame(saveInfo, allowLoadStacking: false, allowSaveBackup: false);
        yield return WaitFor(
            () => Singleton<LoadManager>.Instance.IsGameLoaded && InstanceFinder.IsServer && InstanceFinder.IsClient,
            90f,
            "host_game_server_ready");
        RecordFishNetAuthenticatorState();
        RecordLobbySnapshot("host_direct_ready", lobbyId);
        WriteHostReady(lobbyId);

        yield return WaitFor(
            () => InstanceFinder.ServerManager.Clients.Values.Any(connection =>
                connection.ClientId != 32767 && connection.GetAddress() == expectedPeerSteamId.ToString(CultureInfo.InvariantCulture)),
            60f,
            "host_observed_direct_client");

        bool peerInLobby = Singleton<Lobby>.Instance.GetLobbyMemberIDs().Any(id => id == expectedPeerSteamId.ToString(CultureInfo.InvariantCulture));
        NetworkConnection? peerConnection = InstanceFinder.ServerManager.Clients.Values.FirstOrDefault(connection =>
            connection.ClientId != 32767 && connection.GetAddress() == expectedPeerSteamId.ToString(CultureInfo.InvariantCulture));
        Record(
            "host_direct_final",
            ("peerInLobby", peerInLobby),
            ("peerConnectionPresent", peerConnection != null),
            ("peerAuthenticated", ReadBoolean(peerConnection, "Authenticated")),
            ("lobbyMembers", Singleton<Lobby>.Instance.PlayerCount));

        if (scenario != "impact")
        {
            yield break;
        }

        if (expectBlockedImpact)
        {
            string clientEventsPath = Path.Combine(Path.GetDirectoryName(evidencePath)!, "client-events.txt");
            yield return WaitFor(
                () => EvidenceContains(clientEventsPath, "|client_impact_sent|"),
                45f,
                "host_blocked_impact_requests_sent");
            yield return new WaitForSeconds(3f);

            float runtimeBalance = NetworkSingleton<MoneyManager>.Instance.sync___get_value_onlineBalance();
            Record(
                "host_impact_blocked_runtime_final",
                ("onlineBalance", runtimeBalance),
                ("moneySinkObserved", impactMoneyApplied),
                ("dialogueLogicPrefixObserved", impactDialogueApplied),
                ("combatLogicPrefixObserved", impactCombatApplied));

            Singleton<SaveManager>.Instance.Save(savePath);
            string blockedMoneyPath = Path.Combine(savePath, "Money.json");
            yield return WaitFor(
                () => TryReadPersistedBalance(blockedMoneyPath, out float balance) && Math.Abs(balance - runtimeBalance) < 0.01f,
                30f,
                "host_blocked_impact_persisted");
            bool blockedPersisted = TryReadPersistedBalance(blockedMoneyPath, out float blockedPersistedBalance) &&
                                    Math.Abs(blockedPersistedBalance - runtimeBalance) < 0.01f;
            Record(
                "host_impact_blocked_persistence_final",
                ("moneyPath", blockedMoneyPath),
                ("persisted", blockedPersisted),
                ("persistedOnlineBalance", blockedPersistedBalance),
                ("runtimeOnlineBalance", runtimeBalance));
            yield break;
        }

        yield return WaitFor(
            () => impactMoneyApplied && impactDialogueApplied && impactCombatApplied,
            45f,
            "host_impact_runtime_complete");
        Record(
            "host_impact_runtime_final",
            ("moneyApplied", impactMoneyApplied),
            ("moneyBefore", impactMoneyBefore),
            ("moneyAfter", impactMoneyAfter),
            ("dialogueApplied", impactDialogueApplied),
            ("combatApplied", impactCombatApplied),
            ("npcId", impactNpcId));

        Singleton<SaveManager>.Instance.Save(savePath);
        string moneyPath = Path.Combine(savePath, "Money.json");
        yield return WaitFor(
            () => TryReadPersistedBalance(moneyPath, out float balance) && Math.Abs(balance - impactMoneyAfter) < 0.01f,
            30f,
            "host_impact_persisted");
        bool persisted = TryReadPersistedBalance(moneyPath, out float persistedBalance) &&
                         Math.Abs(persistedBalance - impactMoneyAfter) < 0.01f;
        Record(
            "host_impact_persistence_final",
            ("moneyPath", moneyPath),
            ("persisted", persisted),
            ("persistedOnlineBalance", persistedBalance),
            ("runtimeOnlineBalance", impactMoneyAfter));
    }

    private IEnumerator RunClient()
    {
        string sharedDirectory = Path.GetDirectoryName(evidencePath)!;
        string hostReadyPath = Path.Combine(sharedDirectory, "host-ready.txt");
        ulong hostSteamId = explicitHostSteamId;
        ulong lobbyId = explicitLobbyId;

        if (hostSteamId == 0UL || lobbyId == 0UL)
        {
            yield return WaitFor(() => File.Exists(hostReadyPath), 120f, "client_wait_host_ready");
            if (!File.Exists(hostReadyPath))
            {
                yield break;
            }

            string[] readyParts = File.ReadAllText(hostReadyPath).Trim().Split('|');
            if (readyParts.Length != 2 ||
                !ulong.TryParse(readyParts[0], out hostSteamId) ||
                !ulong.TryParse(readyParts[1], out lobbyId))
            {
                Record("failure", ("phase", "client_parse_host_ready"), ("value", File.ReadAllText(hostReadyPath)));
                yield break;
            }
        }
        else
        {
            Record(
                "client_explicit_host_ready",
                ("hostSteamId", hostSteamId),
                ("lobbyId", lobbyId));
        }

        Record(
            "client_host_ready",
            ("hostSteamId", hostSteamId),
            ("lobbyId", lobbyId),
            ("clientInLobbyBeforeAction", Singleton<Lobby>.Instance.IsInLobby));

        if (scenario == "lobby")
        {
            Record("client_join_lobby_requested", ("lobbyId", lobbyId));
            SteamMatchmaking.JoinLobby(new CSteamID(lobbyId));
            yield return WaitFor(() => Singleton<Lobby>.Instance.IsInLobby, 30f, "client_join_lobby_completed");
            RecordLobbySnapshot("client_lobby_final", lobbyId);
            yield break;
        }

        if (Singleton<Lobby>.Instance.IsInLobby)
        {
            Record("failure", ("phase", "client_direct_precondition"), ("reason", "client unexpectedly already in a lobby"));
            yield break;
        }

        Record("client_direct_start", ("hostSteamId", hostSteamId), ("clientInLobby", false));
        Singleton<LoadManager>.Instance.LoadAsClient(hostSteamId.ToString(CultureInfo.InvariantCulture));
        yield return WaitFor(
            () => InstanceFinder.IsClient && Player.Local != null && Singleton<LoadManager>.Instance.IsGameLoaded,
            90f,
            "client_direct_game_loaded");

        NetworkConnection? localConnection = InstanceFinder.ClientManager.Connection;
        Record(
            "client_direct_final",
            ("clientInLobby", Singleton<Lobby>.Instance.IsInLobby),
            ("fishNetClient", InstanceFinder.IsClient),
            ("localPlayerSpawned", Player.Local != null),
            ("gameLoaded", Singleton<LoadManager>.Instance.IsGameLoaded),
            ("authenticated", ReadBoolean(localConnection, "Authenticated")),
            ("scene", SceneManager.GetActiveScene().name));

        if (scenario == "impact")
        {
            yield return RunClientImpact();
        }
    }

    private static IEnumerator RunClientImpact()
    {
        yield return WaitFor(
            () => NetworkSingleton<MoneyManager>.InstanceExists &&
                  NPCManager.NPCRegistry.Any(npc => npc != null && npc.IsClientInitialized),
            45f,
            "client_impact_surfaces_ready");

        if (!NetworkSingleton<MoneyManager>.InstanceExists)
        {
            yield break;
        }

        NPC? npc = NPCManager.NPCRegistry.FirstOrDefault(candidate =>
            candidate != null &&
            candidate.IsClientInitialized &&
            candidate.Behaviour != null &&
            candidate.Behaviour.CombatBehaviour != null);
        if (npc == null || Player.Local == null)
        {
            Record("failure", ("phase", "client_impact_select_objects"), ("npcFound", npc != null), ("playerFound", Player.Local != null));
            yield break;
        }

        MoneyManager money = NetworkSingleton<MoneyManager>.Instance;
        float before = money.sync___get_value_onlineBalance();
        const float delta = -123.45f;
        const string dialogue = "S1NG controlled dialogue proof";
        Record(
            "client_impact_before",
            ("onlineBalance", before),
            ("npcId", npc.ID),
            ("npcObjectId", npc.NetworkObject.ObjectId),
            ("playerObjectId", Player.Local.NetworkObject.ObjectId));

        money.CreateOnlineTransaction("S1NG controlled transaction", delta, 1f, "isolated reproduction");
        npc.SendWorldSpaceDialogue(dialogue, 3f);
        npc.Behaviour.CombatBehaviour.SetTargetAndEnable_Server(Player.Local.NetworkObject);
        Record(
            "client_impact_sent",
            ("moneyDelta", delta),
            ("dialogue", dialogue),
            ("npcId", npc.ID),
            ("targetObjectId", Player.Local.NetworkObject.ObjectId));

        yield return new WaitForSeconds(3f);
        Record("client_impact_after", ("onlineBalance", money.sync___get_value_onlineBalance()));
    }

    private static IEnumerator WaitFor(Func<bool> condition, float timeoutSeconds, string phase)
    {
        float startedAt = Time.realtimeSinceStartup;
        while (Time.realtimeSinceStartup - startedAt < timeoutSeconds)
        {
            if (condition())
            {
                Record("phase_complete", ("phase", phase), ("elapsedSeconds", Time.realtimeSinceStartup - startedAt));
                yield break;
            }

            yield return null;
        }

        Record("phase_timeout", ("phase", phase), ("timeoutSeconds", timeoutSeconds));
    }

    private void OnLobbyCreated(LobbyCreated_t result)
    {
        Record(
            "lobby_created_callback",
            ("result", result.m_eResult),
            ("lobbyId", result.m_ulSteamIDLobby),
            ("localSteamId", SteamUser.GetSteamID().m_SteamID));

        if (role == "host" && scenario == "lobby" && result.m_eResult == EResult.k_EResultOK)
        {
            WriteHostReady(result.m_ulSteamIDLobby);
        }
    }

    private void OnLobbyEntered(LobbyEnter_t result)
    {
        Record(
            "lobby_enter_callback",
            ("lobbyId", result.m_ulSteamIDLobby),
            ("locked", result.m_bLocked),
            ("response", (EChatRoomEnterResponse)result.m_EChatRoomEnterResponse),
            ("responseRaw", result.m_EChatRoomEnterResponse));
    }

    private void OnLobbyChatUpdate(LobbyChatUpdate_t result)
    {
        Record(
            "lobby_chat_update_callback",
            ("lobbyId", result.m_ulSteamIDLobby),
            ("changedSteamId", result.m_ulSteamIDUserChanged),
            ("actorSteamId", result.m_ulSteamIDMakingChange),
            ("state", (EChatMemberStateChange)result.m_rgfChatMemberStateChange),
            ("stateRaw", result.m_rgfChatMemberStateChange));
    }

    private static void RecordFishNetAuthenticatorState()
    {
        try
        {
            var authenticator = InstanceFinder.ServerManager.GetAuthenticator();
            Record(
                "fishnet_authenticator_state",
                ("readSucceeded", true),
                ("configured", authenticator != null),
                ("authenticatorType", authenticator?.GetType().FullName ?? "none"));
        }
        catch (Exception exception)
        {
            Record(
                "fishnet_authenticator_state",
                ("readSucceeded", false),
                ("configured", "unknown"),
                ("authenticatorType", "unknown"),
                ("error", exception.GetType().Name));
        }
    }

    private static void PatchSteamApi(HarmonyLib.Harmony harmony)
    {
        MethodInfo? createLobby = AccessTools.Method(
            typeof(SteamMatchmaking),
            nameof(SteamMatchmaking.CreateLobby),
            new[] { typeof(ELobbyType), typeof(int) });
        MethodInfo? joinLobby = AccessTools.Method(
            typeof(SteamMatchmaking),
            nameof(SteamMatchmaking.JoinLobby),
            new[] { typeof(CSteamID) });
        if (createLobby == null || joinLobby == null)
        {
            Record(
                "failure",
                ("phase", "patch_steam_api"),
                ("createLobbyFound", createLobby != null),
                ("joinLobbyFound", joinLobby != null));
            return;
        }

        harmony.Patch(createLobby, prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeSteamCreateLobby)));
        harmony.Patch(joinLobby, prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeSteamJoinLobby)));
        Record("steam_api_instrumentation_ready");
    }

    private static void BeforeSteamCreateLobby(
        [HarmonyArgument(0)] ELobbyType lobbyType,
        [HarmonyArgument(1)] int maxMembers)
    {
        Record(
            "steam_create_lobby_api",
            ("requestedType", lobbyType),
            ("maxMembers", maxMembers));
    }

    private static void BeforeSteamJoinLobby([HarmonyArgument(0)] CSteamID lobbyId)
    {
        Record("steam_join_lobby_api", ("lobbyId", lobbyId.m_SteamID));
    }

    private static void PatchFishNet(HarmonyLib.Harmony harmony)
    {
        MethodInfo? remoteState = AccessTools.Method(
            typeof(ServerManager),
            "Transport_OnRemoteConnectionState",
            new[] { typeof(RemoteConnectionStateArgs) });
        MethodInfo? authenticated = AccessTools.Method(
            typeof(ServerManager),
            "ClientAuthenticated",
            new[] { typeof(NetworkConnection) });

        if (remoteState == null || authenticated == null)
        {
            Record("failure", ("phase", "patch_fishnet"), ("reason", "target method missing"));
            return;
        }

        harmony.Patch(remoteState, prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeRemoteConnectionState)));
        harmony.Patch(authenticated, prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeClientAuthenticated)));
        Record("fishnet_instrumentation_ready");
    }

    private static void PatchImpactSinks(HarmonyLib.Harmony harmony)
    {
        MethodInfo? money = FindGeneratedMethod(typeof(MoneyManager), "RpcLogic___CreateOnlineTransaction_", 4);
        MethodInfo? moneyReceive = FindGeneratedMethod(typeof(MoneyManager), "RpcLogic___ReceiveOnlineTransaction_", 4);
        MethodInfo? dialogue = FindGeneratedMethod(typeof(NPC), "RpcLogic___SendWorldSpaceDialogue_", 2);
        MethodInfo? combat = FindGeneratedMethod(typeof(CombatBehaviour), "RpcLogic___SetTargetAndEnable_Server_", 1);
        if (money == null || moneyReceive == null || dialogue == null || combat == null)
        {
            Record(
                "failure",
                ("phase", "patch_impact_sinks"),
                ("moneyFound", money != null),
                ("moneyReceiveFound", moneyReceive != null),
                ("dialogueFound", dialogue != null),
                ("combatFound", combat != null));
            return;
        }

        harmony.Patch(
            money,
            prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeMoneyLogic)));
        harmony.Patch(
            moneyReceive,
            prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeMoneyReceiveLogic)),
            postfix: new HarmonyMethod(typeof(ProbeMod), nameof(AfterMoneyReceiveLogic)));
        harmony.Patch(dialogue, prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeDialogueLogic)));
        harmony.Patch(combat, prefix: new HarmonyMethod(typeof(ProbeMod), nameof(BeforeCombatLogic)));
        Record("impact_instrumentation_ready");
    }

    private static MethodInfo? FindGeneratedMethod(Type type, string prefix, int parameterCount)
    {
        return AccessTools.GetDeclaredMethods(type).SingleOrDefault(method =>
            method.Name.StartsWith(prefix, StringComparison.Ordinal) &&
            method.GetParameters().Length == parameterCount);
    }

    private static void BeforeMoneyLogic(
        MoneyManager __instance,
        [HarmonyArgument(0)] string transactionName,
        [HarmonyArgument(1)] float unitAmount,
        [HarmonyArgument(2)] float quantity,
        [HarmonyArgument(3)] string transactionNote,
        out float __state)
    {
        __state = __instance.sync___get_value_onlineBalance();
        if (transactionName != "S1NG controlled transaction")
        {
            return;
        }

        Record(
            "host_money_rpc_logic_before",
            ("transactionName", transactionName),
            ("unitAmount", unitAmount),
            ("quantity", quantity),
            ("transactionNote", transactionNote),
            ("onlineBalance", __state));
    }

    private static void BeforeMoneyReceiveLogic(
        MoneyManager __instance,
        [HarmonyArgument(0)] string transactionName,
        out float __state)
    {
        __state = __instance.sync___get_value_onlineBalance();
        if (transactionName == "S1NG controlled transaction" && role == "host")
        {
            Record("host_money_mutation_before", ("onlineBalance", __state));
        }
    }

    private static void AfterMoneyReceiveLogic(
        MoneyManager __instance,
        [HarmonyArgument(0)] string transactionName,
        [HarmonyArgument(1)] float unitAmount,
        [HarmonyArgument(2)] float quantity,
        float __state)
    {
        if (transactionName != "S1NG controlled transaction" || role != "host")
        {
            return;
        }

        impactMoneyBefore = __state;
        impactMoneyAfter = __instance.sync___get_value_onlineBalance();
        impactMoneyApplied = Math.Abs((impactMoneyAfter - impactMoneyBefore) - (unitAmount * quantity)) < 0.01f;
        Record(
            "host_money_rpc_logic_after",
            ("onlineBalanceBefore", impactMoneyBefore),
            ("onlineBalanceAfter", impactMoneyAfter),
            ("expectedDelta", unitAmount * quantity),
            ("applied", impactMoneyApplied));
    }

    private static void BeforeDialogueLogic(
        NPC __instance,
        [HarmonyArgument(0)] string text,
        [HarmonyArgument(1)] float duration)
    {
        if (text != "S1NG controlled dialogue proof")
        {
            return;
        }

        impactDialogueApplied = true;
        impactNpcId = __instance.ID;
        Record(
            "host_dialogue_rpc_logic",
            ("npcId", __instance.ID),
            ("npcObjectId", __instance.NetworkObject.ObjectId),
            ("text", text),
            ("duration", duration));
    }

    private static void BeforeCombatLogic(
        CombatBehaviour __instance,
        [HarmonyArgument(0)] FishNet.Object.NetworkObject target)
    {
        if (target == null)
        {
            return;
        }

        impactCombatApplied = true;
        Record(
            "host_combat_rpc_logic",
            ("npcId", __instance.Npc?.ID ?? string.Empty),
            ("targetObjectId", target.ObjectId));
    }

    private static void BeforeRemoteConnectionState(ServerManager __instance, RemoteConnectionStateArgs args)
    {
        if (args.ConnectionState != RemoteConnectionState.Started)
        {
            return;
        }

        string address;
        try
        {
            address = __instance.NetworkManager.TransportManager.Transport.GetConnectionAddress(args.ConnectionId);
        }
        catch (Exception exception)
        {
            address = $"error:{exception.GetType().Name}:{exception.Message}";
        }

        Record(
            "fishnet_remote_started",
            ("connectionId", args.ConnectionId),
            ("transportIndex", args.TransportIndex),
            ("transportAddress", address),
            ("peerInLobby", IsCurrentLobbyMember(address)));
    }

    private static void BeforeClientAuthenticated(NetworkConnection connection)
    {
        string address;
        try
        {
            address = connection.GetAddress();
        }
        catch (Exception exception)
        {
            address = $"error:{exception.GetType().Name}:{exception.Message}";
        }

        Record(
            "fishnet_client_authenticated",
            ("connectionId", connection.ClientId),
            ("transportAddress", address),
            ("peerInLobby", IsCurrentLobbyMember(address)),
            ("authenticatedBeforeCall", ReadBoolean(connection, "Authenticated")));
    }

    private static bool IsCurrentLobbyMember(string steamId)
    {
        try
        {
            return Singleton<Lobby>.InstanceExists &&
                   Singleton<Lobby>.Instance.IsInLobby &&
                   Singleton<Lobby>.Instance.GetLobbyMemberIDs().Any(id => id == steamId);
        }
        catch
        {
            return false;
        }
    }

    private static ulong ReadLobbyId()
    {
        try
        {
            Lobby lobby = Singleton<Lobby>.Instance;
            object? service = AccessTools.Field(typeof(Lobby), "_lobbyService")?.GetValue(lobby);
            if (service == null)
            {
                return 0UL;
            }

            PropertyInfo? property = AccessTools.Property(service.GetType(), "_lobbyID");
            object? value = property?.GetValue(service);
            return value == null ? 0UL : Convert.ToUInt64(value, CultureInfo.InvariantCulture);
        }
        catch
        {
            return 0UL;
        }
    }

    private static bool? ReadBoolean(object? target, string memberName)
    {
        if (target == null)
        {
            return null;
        }

        try
        {
            PropertyInfo? property = AccessTools.Property(target.GetType(), memberName);
            if (property?.GetValue(target) is bool propertyValue)
            {
                return propertyValue;
            }

            FieldInfo? field = AccessTools.Field(target.GetType(), memberName);
            return field?.GetValue(target) is bool fieldValue ? fieldValue : null;
        }
        catch
        {
            return null;
        }
    }

    private static bool TryReadPersistedBalance(string moneyPath, out float balance)
    {
        balance = 0f;
        try
        {
            if (!File.Exists(moneyPath))
            {
                return false;
            }

            Match match = Regex.Match(
                File.ReadAllText(moneyPath),
                "\\\"OnlineBalance\\\"\\s*:\\s*(?<value>-?[0-9]+(?:\\.[0-9]+)?)",
                RegexOptions.CultureInvariant);
            if (!match.Success ||
                !float.TryParse(match.Groups["value"].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out balance))
            {
                return false;
            }
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool EvidenceContains(string path, string value)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd().Contains(value, StringComparison.Ordinal);
        }
        catch (IOException)
        {
            return false;
        }
    }

    private static void RecordLobbySnapshot(string eventName, ulong lobbyId)
    {
        string[] memberIds;
        try
        {
            memberIds = Singleton<Lobby>.Instance.GetLobbyMemberIDs().ToArray();
        }
        catch
        {
            memberIds = Array.Empty<string>();
        }

        Record(
            eventName,
            ("lobbyId", lobbyId),
            ("isInLobby", Singleton<Lobby>.InstanceExists && Singleton<Lobby>.Instance.IsInLobby),
            ("isHost", Singleton<Lobby>.InstanceExists && Singleton<Lobby>.Instance.IsHost),
            ("memberCount", memberIds.Length),
            ("memberIds", string.Join(",", memberIds)));
    }

    private static void WriteHostReady(ulong lobbyId)
    {
        string hostReadyPath = Path.Combine(Path.GetDirectoryName(evidencePath)!, "host-ready.txt");
        File.WriteAllText(
            hostReadyPath,
            $"{SteamUser.GetSteamID().m_SteamID}|{lobbyId}");
        Record("host_ready_file_written", ("path", hostReadyPath), ("lobbyId", lobbyId));
    }

    private static void Record(string eventName, params (string Key, object? Value)[] fields)
    {
        string Format(object? value)
        {
            if (value == null)
            {
                return "null";
            }

            return value switch
            {
                bool boolean => boolean ? "true" : "false",
                float number => number.ToString("0.###", CultureInfo.InvariantCulture),
                double number => number.ToString("0.###", CultureInfo.InvariantCulture),
                _ => value.ToString()!.Replace("|", "%7C").Replace("\r", " ").Replace("\n", " ")
            };
        }

        string line = string.Join(
            "|",
            new[]
            {
                DateTime.UtcNow.ToString("O", CultureInfo.InvariantCulture),
                eventName,
                $"role={role}",
                $"scenario={scenario}"
            }.Concat(fields.Select(field => $"{field.Key}={Format(field.Value)}")));

        lock (EvidenceLock)
        {
            if (!string.IsNullOrWhiteSpace(evidencePath))
            {
                File.AppendAllText(evidencePath, line + Environment.NewLine);
            }
        }

        MelonLogger.Msg($"{Prefix} {line}");
    }
}
