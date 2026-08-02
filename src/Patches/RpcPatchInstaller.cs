using System.Reflection;
using HarmonyLib;
using MelonLoader;
using S1NetGuard.Runtime;
using S1NetGuard.Security;
#if MONO
using NetworkConnection = FishNet.Connection.NetworkConnection;
#else
using NetworkConnection = Il2CppFishNet.Connection.NetworkConnection;
#endif

namespace S1NetGuard.Patches;

internal static class RpcPatchInstaller
{
#if MONO
    private const string MoneyManagerType = "ScheduleOne.Money.MoneyManager";
    private const string NpcType = "ScheduleOne.NPCs.NPC";
    private const string PlayerType = "ScheduleOne.PlayerScripts.Player";
    private const string CombatBehaviourType = "ScheduleOne.Combat.CombatBehaviour";
#else
    private const string MoneyManagerType = "Il2CppScheduleOne.Money.MoneyManager";
    private const string NpcType = "Il2CppScheduleOne.NPCs.NPC";
    private const string PlayerType = "Il2CppScheduleOne.PlayerScripts.Player";
    private const string CombatBehaviourType = "Il2CppScheduleOne.Combat.CombatBehaviour";
#endif

    private static readonly RpcPatchDefinition[] Definitions =
    {
        new(MoneyManagerType, "RpcReader___Server_CreateOnlineTransaction_", 3,
            "RpcLogic___CreateOnlineTransaction_", 4, nameof(BlockMoneyRpc)),
        new(NpcType, "RpcReader___Server_SendWorldSpaceDialogue_", 3,
            "RpcLogic___SendWorldSpaceDialogue_", 2, nameof(BlockDialogueRpc)),
        new(PlayerType, "RpcReader___Server_SendWorldSpaceDialogue_", 3,
            "RpcLogic___SendWorldSpaceDialogue_", 2, nameof(BlockDialogueRpc)),
        new(CombatBehaviourType, "RpcReader___Server_SetTargetAndEnable_Server_", 3,
            "RpcLogic___SetTargetAndEnable_Server_", 1, nameof(BlockNpcControlRpc))
    };

    internal static void Install(HarmonyLib.Harmony harmony)
    {
        int installed = 0;
        foreach (RpcPatchDefinition definition in Definitions)
        {
            try
            {
                Type? targetType = AccessTools.TypeByName(definition.TypeName);
                if (targetType == null)
                {
                    throw new MissingMemberException($"Type {definition.TypeName} was not found.");
                }

                MethodInfo reader = FindGeneratedMethod(targetType, definition.ReaderPrefix, definition.ReaderParameterCount);
                MethodInfo logic = FindGeneratedMethod(targetType, definition.LogicPrefix, definition.LogicParameterCount);

                harmony.Patch(
                    reader,
                    prefix: new HarmonyMethod(AccessTools.Method(typeof(RpcPatchInstaller), nameof(BeginRpc))),
                    postfix: new HarmonyMethod(AccessTools.Method(typeof(RpcPatchInstaller), nameof(EndRpc))),
                    finalizer: new HarmonyMethod(AccessTools.Method(typeof(RpcPatchInstaller), nameof(FinalizeRpc))));
                harmony.Patch(
                    logic,
                    prefix: new HarmonyMethod(AccessTools.Method(typeof(RpcPatchInstaller), definition.GuardMethodName)));
                installed++;
            }
            catch (Exception exception)
            {
                MelonLogger.Error(
                    $"{Constants.LogPrefix} Failed to install RPC guard for {definition.TypeName}: {exception}");
            }
        }

        MelonLogger.Msg($"{Constants.LogPrefix} Installed {installed}/{Definitions.Length} targeted RPC guard(s).");
    }

    private static MethodInfo FindGeneratedMethod(Type targetType, string namePrefix, int parameterCount)
    {
        MethodInfo[] matches = AccessTools.GetDeclaredMethods(targetType)
            .Where(method => method.Name.StartsWith(namePrefix, StringComparison.Ordinal) &&
                             method.GetParameters().Length == parameterCount)
            .ToArray();

        return matches.Length == 1
            ? matches[0]
            : throw new MissingMethodException(
                $"Expected one {targetType.FullName}.{namePrefix}* method with {parameterCount} parameters; " +
                $"found {matches.Length}.");
    }

    private static void BeginRpc([HarmonyArgument(2)] NetworkConnection connection)
    {
        RpcConnectionContext.Set(connection);
    }

    private static void EndRpc()
    {
        RpcConnectionContext.Clear();
    }

    private static Exception? FinalizeRpc(Exception? __exception)
    {
        RpcConnectionContext.Clear();
        return __exception;
    }

    private static bool BlockMoneyRpc()
    {
        return ShouldRunRpc("shared-money mutation");
    }

    private static bool BlockDialogueRpc()
    {
        return ShouldRunRpc("free-text worldspace dialogue");
    }

    private static bool BlockNpcControlRpc()
    {
        return ShouldRunRpc("NPC target control");
    }

    private static bool ShouldRunRpc(string capability)
    {
        if (!NetGuardPreferences.EnableRpcDefenseInDepth.Value)
        {
            return true;
        }

        NetworkConnection? connection = RpcConnectionContext.Current;
        if (connection == null)
        {
            return true;
        }

        string address = connection.GetAddress();
        AdmissionPolicy.TryParseSteamId(address, out ulong steamId);
        MelonLogger.Warning(
            $"{Constants.LogPrefix} Blocked remote {capability} RPC from SteamID {steamId} " +
            $"(connection {connection.ClientId}).");

        if (NetGuardPreferences.DisconnectOnRpcViolation.Value)
        {
            ConnectionRegistry.Deny(steamId);
            ConnectionRegistry.QueueDisconnect(connection);
        }

        return false;
    }

    private sealed class RpcPatchDefinition
    {
        internal RpcPatchDefinition(
            string typeName,
            string readerPrefix,
            int readerParameterCount,
            string logicPrefix,
            int logicParameterCount,
            string guardMethodName)
        {
            TypeName = typeName;
            ReaderPrefix = readerPrefix;
            ReaderParameterCount = readerParameterCount;
            LogicPrefix = logicPrefix;
            LogicParameterCount = logicParameterCount;
            GuardMethodName = guardMethodName;
        }

        internal string TypeName { get; }
        internal string ReaderPrefix { get; }
        internal int ReaderParameterCount { get; }
        internal string LogicPrefix { get; }
        internal int LogicParameterCount { get; }
        internal string GuardMethodName { get; }
    }
}
