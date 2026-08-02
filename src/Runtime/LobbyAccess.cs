using System.Reflection;
using HarmonyLib;
using MelonLoader;
#if MONO
using GameLobby = ScheduleOne.Networking.Lobby;
using S1Singleton = ScheduleOne.DevUtilities.Singleton<ScheduleOne.Networking.Lobby>;
using Steamworks;
#else
using GameLobby = Il2CppScheduleOne.Networking.Lobby;
using S1Singleton = Il2CppScheduleOne.DevUtilities.Singleton<Il2CppScheduleOne.Networking.Lobby>;
using Il2CppSteamworks;
#endif

namespace S1NetGuard.Runtime;

internal static class LobbyAccess
{
    internal static bool TryGetMemberIds(out string[] memberIds)
    {
        memberIds = Array.Empty<string>();
        try
        {
            if (!S1Singleton.InstanceExists)
            {
                return false;
            }

            GameLobby lobby = S1Singleton.Instance;
            if (lobby == null || !lobby.IsInLobby)
            {
                return false;
            }

            var members = lobby.GetLobbyMemberIDs();
            memberIds = new string[members.Count];
            for (int i = 0; i < members.Count; i++)
            {
                memberIds[i] = members[i];
            }

            return true;
        }
        catch (Exception exception)
        {
            MelonLogger.Warning($"{Constants.LogPrefix} Lobby membership lookup failed: {exception.Message}");
            return false;
        }
    }

    internal static bool TryLockCurrentLobby()
    {
        try
        {
            if (!S1Singleton.InstanceExists)
            {
                return false;
            }

            GameLobby lobby = S1Singleton.Instance;
            if (lobby == null || !lobby.IsHost || !lobby.IsInLobby)
            {
                return false;
            }

            ulong lobbyId = lobby.LobbyID;
            if (lobbyId == 0UL)
            {
                object? service = ReadMember(lobby, "_lobbyService");
                object? rawLobbyId = service == null ? null : ReadMember(service, "_lobbyID");
                if (rawLobbyId != null)
                {
                    lobbyId = Convert.ToUInt64(rawLobbyId);
                }
            }

            if (lobbyId == 0UL)
            {
                return false;
            }

            bool locked = SteamMatchmaking.SetLobbyJoinable(new CSteamID(lobbyId), false);
            if (locked)
            {
                MelonLogger.Msg($"{Constants.LogPrefix} Locked Steam lobby {lobbyId} against late joins.");
            }

            return locked;
        }
        catch (Exception exception)
        {
            MelonLogger.Warning($"{Constants.LogPrefix} Lobby lock failed: {exception.Message}");
            return false;
        }
    }

    internal static bool IsImmediateSteamFriend(ulong steamId)
    {
        if (steamId == 0UL)
        {
            return false;
        }

        try
        {
            return SteamFriends.HasFriend(new CSteamID(steamId), EFriendFlags.k_EFriendFlagImmediate);
        }
        catch (Exception exception)
        {
            MelonLogger.Warning($"{Constants.LogPrefix} Steam friendship lookup failed: {exception.Message}");
            return false;
        }
    }

    private static object? ReadMember(object target, string name)
    {
        Type type = target.GetType();
        PropertyInfo? property = AccessTools.Property(type, name);
        if (property != null)
        {
            return property.GetValue(target);
        }

        FieldInfo? field = AccessTools.Field(type, name);
        return field?.GetValue(target);
    }
}
