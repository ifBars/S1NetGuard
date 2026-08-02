using MelonLoader;

namespace S1NetGuard;

internal static class NetGuardPreferences
{
    internal static MelonPreferences_Entry<bool> EnableAdmissionGate { get; private set; } = null!;
    internal static MelonPreferences_Entry<bool> FailClosedWhenLobbyUnavailable { get; private set; } = null!;
    internal static MelonPreferences_Entry<string> AllowedSteamIds { get; private set; } = null!;
    internal static MelonPreferences_Entry<bool> TrustSteamFriendsInLobby { get; private set; } = null!;
    internal static MelonPreferences_Entry<bool> TrustAllCurrentLobbyMembers { get; private set; } = null!;
    internal static MelonPreferences_Entry<bool> LockLobbyWhenGameplayStarts { get; private set; } = null!;
    internal static MelonPreferences_Entry<bool> EnableRpcDefenseInDepth { get; private set; } = null!;
    internal static MelonPreferences_Entry<bool> DisconnectOnRpcViolation { get; private set; } = null!;

    internal static void Initialize()
    {
        MelonPreferences_Category category = MelonPreferences.CreateCategory("S1NetGuard");
        EnableAdmissionGate = category.CreateEntry(
            "EnableAdmissionGate",
            true,
            "Reject remote Steam identities that are not current lobby members or explicitly allowed.");
        FailClosedWhenLobbyUnavailable = category.CreateEntry(
            "FailClosedWhenLobbyUnavailable",
            true,
            "Reject remote joins when lobby membership cannot be verified.");
        AllowedSteamIds = category.CreateEntry(
            "AllowedSteamIds",
            string.Empty,
            "Comma-separated SteamID64 values allowed to connect without current lobby membership.");
        TrustSteamFriendsInLobby = category.CreateEntry(
            "TrustSteamFriendsInLobby",
            true,
            "Allow a transport-verified Steam friend who is also in the current lobby.");
        TrustAllCurrentLobbyMembers = category.CreateEntry(
            "TrustAllCurrentLobbyMembers",
            false,
            "Compatibility mode: trust every current lobby member, including non-friends.");
        LockLobbyWhenGameplayStarts = category.CreateEntry(
            "LockLobbyWhenGameplayStarts",
            false,
            "Optionally mark the Steam lobby non-joinable after gameplay starts.");
        EnableRpcDefenseInDepth = category.CreateEntry(
            "EnableRpcDefenseInDepth",
            false,
            "Optionally block remote money, free-text worldspace dialogue, and NPC target-control ServerRpcs.");
        DisconnectOnRpcViolation = category.CreateEntry(
            "DisconnectOnRpcViolation",
            true,
            "Disconnect and session-deny a peer that invokes a blocked high-risk ServerRpc.");
    }
}
