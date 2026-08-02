namespace S1NetGuard.Security;

internal enum AdmissionReason
{
    LocalHost,
    SteamFriendInLobby,
    TrustedLobbyMemberCompatibility,
    ExplicitAllowlist,
    FailOpen,
    InvalidTransportIdentity,
    SessionDenied,
    NotInCurrentLobby,
    UntrustedLobbyMember,
    LobbyUnavailable
}

internal readonly struct AdmissionDecision
{
    internal AdmissionDecision(bool allowed, AdmissionReason reason, ulong steamId)
    {
        Allowed = allowed;
        Reason = reason;
        SteamId = steamId;
    }

    internal bool Allowed { get; }
    internal AdmissionReason Reason { get; }
    internal ulong SteamId { get; }
}
