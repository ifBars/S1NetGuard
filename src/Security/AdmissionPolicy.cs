namespace S1NetGuard.Security;

internal static class AdmissionPolicy
{
    internal const int LocalHostConnectionId = 32767;

    internal static AdmissionDecision Evaluate(
        int connectionId,
        string? transportAddress,
        ulong localSteamId,
        bool lobbyAvailable,
        IEnumerable<string> lobbyMemberIds,
        bool isSteamFriend,
        bool trustSteamFriendsInLobby,
        bool trustAllCurrentLobbyMembers,
        ISet<ulong> explicitAllowlist,
        ISet<ulong> sessionDenylist,
        bool failClosedWhenLobbyUnavailable)
    {
        if (connectionId == LocalHostConnectionId)
        {
            return new AdmissionDecision(true, AdmissionReason.LocalHost, 0UL);
        }

        if (!TryParseSteamId(transportAddress, out ulong steamId))
        {
            return new AdmissionDecision(false, AdmissionReason.InvalidTransportIdentity, 0UL);
        }

        if (localSteamId != 0UL && steamId == localSteamId)
        {
            return new AdmissionDecision(true, AdmissionReason.LocalHost, steamId);
        }

        if (sessionDenylist.Contains(steamId))
        {
            return new AdmissionDecision(false, AdmissionReason.SessionDenied, steamId);
        }

        if (explicitAllowlist.Contains(steamId))
        {
            return new AdmissionDecision(true, AdmissionReason.ExplicitAllowlist, steamId);
        }

        if (!lobbyAvailable)
        {
            return failClosedWhenLobbyUnavailable
                ? new AdmissionDecision(false, AdmissionReason.LobbyUnavailable, steamId)
                : new AdmissionDecision(true, AdmissionReason.FailOpen, steamId);
        }

        bool isCurrentLobbyMember = false;
        foreach (string memberId in lobbyMemberIds)
        {
            if (TryParseSteamId(memberId, out ulong memberSteamId) && memberSteamId == steamId)
            {
                isCurrentLobbyMember = true;
                break;
            }
        }

        if (!isCurrentLobbyMember)
        {
            return new AdmissionDecision(false, AdmissionReason.NotInCurrentLobby, steamId);
        }

        if (trustAllCurrentLobbyMembers)
        {
            return new AdmissionDecision(true, AdmissionReason.TrustedLobbyMemberCompatibility, steamId);
        }

        if (trustSteamFriendsInLobby && isSteamFriend)
        {
            return new AdmissionDecision(true, AdmissionReason.SteamFriendInLobby, steamId);
        }

        return new AdmissionDecision(false, AdmissionReason.UntrustedLobbyMember, steamId);
    }

    internal static bool TryParseSteamId(string? value, out ulong steamId)
    {
        return ulong.TryParse(value?.Trim(), out steamId) && steamId != 0UL;
    }

    internal static HashSet<ulong> ParseSteamIdSet(string? value)
    {
        var result = new HashSet<ulong>();
        if (string.IsNullOrWhiteSpace(value))
        {
            return result;
        }

        foreach (string candidate in value.Split(new[] { ',', ';', ' ', '\r', '\n', '\t' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (TryParseSteamId(candidate, out ulong steamId))
            {
                result.Add(steamId);
            }
        }

        return result;
    }
}
