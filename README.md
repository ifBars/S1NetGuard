# S1 Net Guard

Security research and a host-side defensive MelonLoader mod for an authorization weakness in Schedule I multiplayer.

The inspected networking path can accept a Steam P2P connection and let FishNet authenticate it without a host-controlled authorization decision. Once admitted, a peer can reach high-risk non-owner server RPCs related to shared money, world-space dialogue, and NPC targeting.

## Research package

- [Technical security report](reports/schedule-i-unauthenticated-p2p-rpc-abuse.md)
- [Streamer incident clip](evidence/streamer-incident.mp4)
- [Clip provenance and limitations](evidence/README.md)

The clip visually corroborates attacker-controlled promotional messages rendered through native-looking world-space NPC dialogue. It does not independently prove the reported balance change or establish the exact connection path.

This repository intentionally omits offensive packet construction, generated RPC identifiers, serializer details, proprietary game assemblies, decompiled dumps, generated IL2CPP wrappers, AssetRipper exports, and game assets.

## Defensive mod

S1 Net Guard evaluates remote Steam identities before FishNet creates or authenticates a player. It accepts an immediate Steam friend in the current lobby or an explicitly allowed SteamID.

The mod keeps rejected identities on a session denylist and offers an optional late-join lobby lock. Optional RPC guards cover shared-money mutation, free-text world-space dialogue, and NPC target control. The mod disables RPC hardening by default to preserve normal invited-player behavior; the admission gate is the main protection.

## Build

Copy `local.build.props.example` to `local.build.props`, set the two game paths, and build each runtime independently:

```powershell
dotnet build S1NetGuard.csproj -c Mono -p:AutomateLocalDeployment=false
dotnet build S1NetGuard.csproj -c Il2cpp -p:AutomateLocalDeployment=false
```

Install only a locally built DLL matching the game backend in the game's `Mods` directory. This repository does not publish a release or prebuilt binaries.

## Configuration

MelonPreferences creates an `S1NetGuard` category:

- `EnableAdmissionGate=true`: enforce host authorization using the transport SteamID.
- `FailClosedWhenLobbyUnavailable=true`: reject remote peers if the host cannot verify lobby membership.
- `AllowedSteamIds=`: comma-separated SteamID64 exceptions.
- `TrustSteamFriendsInLobby=true`: trust verified immediate Steam friends who are current lobby members.
- `TrustAllCurrentLobbyMembers=false`: compatibility mode for trusting non-friend lobby members; enabling it weakens protection for open lobbies.
- `LockLobbyWhenGameplayStarts=false`: optionally disable late Steam lobby joins after loading gameplay.
- `EnableRpcDefenseInDepth=false`: optionally suppress remote high-risk RPC logic.
- `DisconnectOnRpcViolation=true`: disconnect and session-deny peers that hit an enabled RPC guard.

If the host intentionally uses a non-Steam or lobby-less transport workflow, add the expected SteamID64 values to `AllowedSteamIds` or explicitly choose fail-open mode. Fail-open mode weakens the primary protection.

## Verification

```powershell
dotnet run --project tests\S1NetGuard.PolicyVerifier\S1NetGuard.PolicyVerifier.csproj -c Release
.\tests\Verify-GameSurface.ps1 -MonoGamePath "<mono install>" -Il2CppGamePath "<il2cpp install>"
.\tests\Run-StartupSmoke.ps1 -Runtime Mono -GamePath "<mono install>"
.\tests\Run-StartupSmoke.ps1 -Runtime Il2Cpp -GamePath "<il2cpp install>"
```

The verifier covers local-host admission, friend-plus-lobby authorization, explicit exceptions, unknown direct peers, untrusted non-friend lobby members, invalid identities, fail-closed behavior, opt-in compatibility modes, reconnect denial, and allowlist parsing. The surface check verifies every Harmony target against both current assemblies without copying or publishing proprietary game code. The startup smoke temporarily deploys only the matching S1 Net Guard DLL, waits for the real MelonLoader/Harmony initialization markers, stops only the process it launched, and removes the temporary deployment.

The mod also expands the game's persona-only lobby callback log with a line like:

```text
[S1NetGuard] Lobby member update: changedSteamId=..., actorSteamId=..., lobbyId=..., state=Entered, immediateFriend=False.
```

This distinguishes entry, departure, disconnect, kick, and ban events while retaining the exact Steam identities needed for incident correlation.

For a live check, host a normal lobby and confirm a Steam friend in that lobby connects. For an invited non-friend, add their SteamID64 to `AllowedSteamIds`. Then attempt connections from controlled non-friend identities both outside and inside the lobby; confirm the host log reports `NotInCurrentLobby` and `UntrustedLobbyMember` respectively, and that no player object appears. Do not test against third-party sessions.
