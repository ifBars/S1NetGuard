# Configuration

MelonLoader creates the `S1NetGuard` category in `UserData/MelonPreferences.cfg`.
Restart the game after changing an entry.

| Entry | Default | Effect |
| --- | --- | --- |
| `EnableAdmissionGate` | `true` | Evaluates every remote FishNet transport connection before authentication. |
| `FailClosedWhenLobbyUnavailable` | `true` | Rejects a remote peer when current lobby membership cannot be read. |
| `AllowedSteamIds` | empty | Comma-separated SteamID64 values that may connect without current lobby membership. |
| `TrustSteamFriendsInLobby` | `true` | Admits an immediate Steam friend only when that identity is also in the current lobby. |
| `TrustAllCurrentLobbyMembers` | `false` | Compatibility mode that admits any current lobby member, including a non-friend invitee. |
| `LockLobbyWhenGameplayStarts` | `false` | Marks the current Steam lobby non-joinable after `Main` or `Tutorial` loads. |
| `EnableRpcDefenseInDepth` | `false` | Blocks the reviewed remote money, dialogue, and NPC-targeting RPCs. |
| `DisconnectOnRpcViolation` | `true` | Disconnects and session-denies a peer after a blocked RPC. |

## Common host configurations

The default configuration trusts friends who are present in the lobby:

```ini
[S1NetGuard]
EnableAdmissionGate = true
FailClosedWhenLobbyUnavailable = true
TrustSteamFriendsInLobby = true
TrustAllCurrentLobbyMembers = false
EnableRpcDefenseInDepth = false
```

To admit a specific non-friend invitee without trusting every lobby member:

```ini
[S1NetGuard]
AllowedSteamIds = "7656119XXXXXXXXXX"
```

To admit all current lobby members, including non-friend invitees:

```ini
[S1NetGuard]
TrustAllCurrentLobbyMembers = true
```

That compatibility setting still rejects a direct peer who is not in the
current lobby. It places more trust in the lobby backend and should not replace
an explicit allowlist when the invited SteamID is known.

## RPC defense

Enable the RPC layer only if blocking the reviewed actions is acceptable for
the host's session:

```ini
[S1NetGuard]
EnableRpcDefenseInDepth = true
DisconnectOnRpcViolation = true
```

The guards cover the reviewed shared-money mutation, free-text world-space
dialogue, and NPC target-control paths. They are not a general authorization
system for every Schedule I RPC. The native game fix should validate each
sender against the specific action and target object.
