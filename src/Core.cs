using MelonLoader;
using S1NetGuard.Patches;
using S1NetGuard.Runtime;

[assembly: MelonInfo(
    typeof(S1NetGuard.Core),
    S1NetGuard.Constants.ModName,
    S1NetGuard.Constants.ModVersion,
    S1NetGuard.Constants.ModAuthor)]
[assembly: MelonGame("TVGS", "Schedule I")]

namespace S1NetGuard;

public sealed class Core : MelonMod
{
    private bool _lobbyLockPending;
    private int _lobbyLockAttemptsRemaining;
    private float _nextLobbyLockAttempt;

    public override void OnInitializeMelon()
    {
        NetGuardPreferences.Initialize();
        ConnectionRegistry.Reset(NetGuardPreferences.AllowedSteamIds.Value);

        HarmonyInstance.PatchAll(typeof(Core).Assembly);
        RpcPatchInstaller.Install(HarmonyInstance);

        LoggerInstance.Msg(
            $"{Constants.ModName} {Constants.ModVersion} initialized. " +
            $"AdmissionGate={NetGuardPreferences.EnableAdmissionGate.Value}, " +
            $"RpcDefenseInDepth={NetGuardPreferences.EnableRpcDefenseInDepth.Value}.");
    }

    public override void OnSceneWasLoaded(int buildIndex, string sceneName)
    {
        if (!NetGuardPreferences.LockLobbyWhenGameplayStarts.Value ||
            !string.Equals(sceneName, "Main", StringComparison.OrdinalIgnoreCase) &&
            !string.Equals(sceneName, "Tutorial", StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        _lobbyLockPending = true;
        _lobbyLockAttemptsRemaining = 10;
        _nextLobbyLockAttempt = 0f;
    }

    public override void OnUpdate()
    {
        ConnectionRegistry.FlushPendingDisconnects();

        if (!_lobbyLockPending || UnityEngine.Time.unscaledTime < _nextLobbyLockAttempt)
        {
            return;
        }

        _nextLobbyLockAttempt = UnityEngine.Time.unscaledTime + 1f;
        _lobbyLockPending = !LobbyAccess.TryLockCurrentLobby();
        _lobbyLockAttemptsRemaining--;
        if (_lobbyLockAttemptsRemaining <= 0)
        {
            _lobbyLockPending = false;
            MelonLogger.Warning($"{Constants.LogPrefix} Could not resolve the current lobby ID to lock late joins.");
        }
    }

    public override void OnApplicationQuit()
    {
        ConnectionRegistry.Clear();
        RpcConnectionContext.Clear();
    }
}
