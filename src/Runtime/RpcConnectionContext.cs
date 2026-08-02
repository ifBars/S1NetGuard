#if MONO
using NetworkConnection = FishNet.Connection.NetworkConnection;
#else
using NetworkConnection = Il2CppFishNet.Connection.NetworkConnection;
#endif

namespace S1NetGuard.Runtime;

internal static class RpcConnectionContext
{
    [ThreadStatic]
    private static NetworkConnection? _current;

    internal static NetworkConnection? Current => _current;

    internal static void Set(NetworkConnection connection)
    {
        _current = connection;
    }

    internal static void Clear()
    {
        _current = null;
    }
}
