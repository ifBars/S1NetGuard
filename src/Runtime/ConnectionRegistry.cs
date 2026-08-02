using MelonLoader;
using S1NetGuard.Security;
#if MONO
using NetworkConnection = FishNet.Connection.NetworkConnection;
#else
using NetworkConnection = Il2CppFishNet.Connection.NetworkConnection;
#endif

namespace S1NetGuard.Runtime;

internal static class ConnectionRegistry
{
    private static readonly HashSet<ulong> SessionDenylist = new();
    private static readonly List<NetworkConnection> PendingDisconnects = new();
    private static HashSet<ulong> _explicitAllowlist = new();

    internal static ISet<ulong> DeniedSteamIds => SessionDenylist;
    internal static ISet<ulong> ExplicitlyAllowedSteamIds => _explicitAllowlist;

    internal static void Reset(string? allowedSteamIds)
    {
        SessionDenylist.Clear();
        PendingDisconnects.Clear();
        _explicitAllowlist = AdmissionPolicy.ParseSteamIdSet(allowedSteamIds);
        if (_explicitAllowlist.Count > 0)
        {
            MelonLogger.Msg($"{Constants.LogPrefix} Loaded {_explicitAllowlist.Count} explicitly allowed SteamID(s).");
        }
    }

    internal static void Deny(ulong steamId)
    {
        if (steamId != 0UL)
        {
            SessionDenylist.Add(steamId);
        }
    }

    internal static void QueueDisconnect(NetworkConnection? connection)
    {
        if (connection == null || connection.ClientId < 0)
        {
            return;
        }

        for (int i = 0; i < PendingDisconnects.Count; i++)
        {
            if (PendingDisconnects[i].ClientId == connection.ClientId)
            {
                return;
            }
        }

        PendingDisconnects.Add(connection);
    }

    internal static void FlushPendingDisconnects()
    {
        for (int i = PendingDisconnects.Count - 1; i >= 0; i--)
        {
            NetworkConnection connection = PendingDisconnects[i];
            PendingDisconnects.RemoveAt(i);
            try
            {
                if (connection.ClientId >= 0 && !connection.Disconnecting)
                {
                    connection.Disconnect(true);
                }
            }
            catch (Exception exception)
            {
                MelonLogger.Warning($"{Constants.LogPrefix} Failed to disconnect blocked connection: {exception.Message}");
            }
        }
    }

    internal static void Clear()
    {
        SessionDenylist.Clear();
        PendingDisconnects.Clear();
        _explicitAllowlist.Clear();
    }
}
