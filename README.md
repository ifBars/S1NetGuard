# S1 Net Guard

Security research and a temporary host-side defense for a Schedule I multiplayer admission flaw.

## Finding

The reviewed connection path accepts an incoming Steam P2P peer and lets FishNet authenticate it without a host-controlled authorization decision. Lobby membership is not enough for an open lobby because an unknown account may enter the lobby and then reach the same server-RPC boundary as an invited player.

Several non-owner server RPCs make that admission flaw consequential. The reviewed paths can affect shared online money, display arbitrary world-space dialogue, and influence NPC targeting. The incident clip visibly shows promotional messages rendered through the game's native-looking NPC dialogue. The reported balance change and exact admission route are not independently confirmed by the clip.

https://github.com/user-attachments/assets/5ccbcb0d-00bd-40c6-bf06-567fb1dcb196

- [Security write-up](reports/schedule-i-unauthenticated-p2p-rpc-abuse.md)
- [Incident clip](evidence/streamer-incident.mp4)

## Recommended game fix

The game should authorize the transport-verified SteamID before FishNet authenticates the connection. Admission should require a host-approved invite, explicit session authorization, or another host-controlled trust decision. The game should reject an unauthorized peer before creating its player object or allowing it to invoke game RPCs.

Lobby visibility and game admission should remain separate decisions. High-risk RPCs should also validate the sender's authority. These checks provide a second layer, not a substitute for admission control.

## Temporary mitigation

S1 Net Guard applies the admission check as a MelonLoader mod. By default, it accepts an immediate Steam friend who is in the current lobby or a SteamID explicitly allowed by the host. It rejects other remote peers before FishNet authentication and blocks rejected identities from reconnecting during the session.

Optional RPC guards cover the reviewed money, dialogue, and NPC-targeting paths. The mod disables them by default because they may interfere with legitimate invited-player actions.

## Status

- Mono and IL2CPP builds compile without warnings or errors.
- Eleven admission-policy scenarios pass.
- Twelve admission, lobby-audit, and RPC surfaces match the current Mono and IL2CPP assemblies.
- Real startup smoke tests pass on both runtimes.
- A controlled two-account end-to-end admission test remains outstanding.

## Build

Copy `local.build.props.example` to `local.build.props`, set the local game paths, then build the matching runtime:

```powershell
dotnet build S1NetGuard.csproj -c Mono -p:AutomateLocalDeployment=false
dotnet build S1NetGuard.csproj -c Il2cpp -p:AutomateLocalDeployment=false
```

This repository does not publish binaries. It also omits packet-construction details, proprietary game assemblies, decompiled dumps, generated wrappers, and game assets.
