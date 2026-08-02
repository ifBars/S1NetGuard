# S1 Net Guard

Host-side protection and security research for a Schedule I multiplayer
admission flaw.

https://github.com/user-attachments/assets/5ccbcb0d-00bd-40c6-bf06-567fb1dcb196

[Incident clip](evidence/streamer-incident.mp4) |
[Security write-up](reports/schedule-i-unauthenticated-p2p-rpc-abuse.md)

## Confirmed behavior

In a controlled two-client Mono test, a client that was not in the host's
lobby used Schedule I's direct connection path and reached an authenticated,
loaded game session. FishNet had no configured authenticator, and the game did
not make a host-controlled admission decision before authentication.

The same controlled client reached non-owner RPC paths for shared money,
world-space dialogue, and NPC targeting. Two independent runs changed the
runtime balance from `0` to `-123.45` and persisted the result to the isolated
test save.

The test used GSE, a Steam-compatible emulator. It proves the game and FishNet
path, but it does not prove that an unrelated account can join a FriendsOnly
lobby through Valve. Valve documents FriendsOnly lobbies as joinable by friends
and invitees. That live two-account lobby control remains separate.

## What the mod does

S1 Net Guard checks the transport SteamID before FishNet authenticates a remote
connection. By default, it allows:

- the local host;
- an immediate Steam friend who is also in the current lobby; or
- a SteamID the host explicitly allowlisted.

The admission gate rejects other remote peers before player creation. Optional
RPC guards block the reviewed money, free-text dialogue, and NPC-targeting
paths. Those guards are off by default because they can also block legitimate
actions from invited players.

Controlled negative tests confirmed that the admission gate rejects a direct
non-member before FishNet authentication. A separate allowlisted-client test
confirmed that the RPC guards block all three reviewed requests and preserve
the runtime and saved balance.

## Recommended game fix

The game should attach a session-aware FishNet `Authenticator` before starting
the server. It must authorize the transport-verified SteamID before FishNet
enters its authenticated-client path. Lobby discovery and transport admission
must remain separate decisions. High-risk RPCs must also validate the sender's
session role and authority over the requested action.

The [security write-up](reports/schedule-i-unauthenticated-p2p-rpc-abuse.md)
contains the proposed game-side control flow and regression cases.

## Validation status

- Controlled direct-admission reproduction: passed on Mono `0.4.6f11 Alternate`.
- Controlled money, dialogue, NPC-control, and save-impact reproduction: passed twice on Mono.
- Admission and RPC-defense negative controls: passed on Mono.
- Mono and IL2CPP builds: zero warnings and errors.
- Mono and IL2CPP real startup checks: passed.
- Mono and IL2CPP game-surface checks: 12 targets passed.
- Admission policy verifier: 12 scenarios passed.
- Live Valve FriendsOnly test with two unrelated Steam accounts: not yet run.

## Build

Copy `local.build.props.example` to `local.build.props`, set the local game
paths, and build the matching runtime:

```powershell
dotnet build S1NetGuard.csproj -c Mono -p:AutomateLocalDeployment=false
dotnet build S1NetGuard.csproj -c Il2cpp -p:AutomateLocalDeployment=false
```

This repository does not publish binaries. It also omits packet-construction
details, proprietary game assemblies, decompiled dumps, generated wrappers,
test saves, and local reproduction logs.
