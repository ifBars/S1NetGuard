# Schedule I live Valve two-account control

This bundle tests four separate questions with two controlled, unrelated Steam
accounts:

1. Does Valve allow the unrelated client to enter a FriendsOnly lobby through
   `JoinLobby`?
2. Can the same client skip `JoinLobby` and reach an authenticated, loaded game
   through Schedule I's direct connection path?
3. Can that admitted client exercise the controlled money, dialogue, and NPC
   target paths?
4. Does S1NetGuard reject the direct non-member and block the tested RPCs?

Use separate machines or Steam sessions. Each machine must run the same Mono
game build, the original Steam API supplied by Valve, and a Steam client logged
into the intended account. The accounts must not be Steam friends and must not
invite one another.

The scripts refuse GSE, an ordinary game installation, another mod DLL, or a
Steam initialization that falls back to Schedule I's mock lobby service.

## Build the transferable bundle

From the repository root, build the probe, mod, scripts, and checksum file:

```powershell
.\tests\Repro\New-LiveValveBundle.ps1 -GamePath '<MONO_GAME_PATH>'
Set-Location .\tests\Repro\live-valve-bundle
```

Copy the complete `live-valve-bundle` directory to the second machine. Verify
`SHA256SUMS.txt` after transfer. Do not add evidence files to that directory.

## Prepare one isolated clone per machine

Run this outside the game installation. Choose a new destination:

```powershell
.\New-CleanMonoClone.ps1 `
  -SourcePath '<MONO_GAME_PATH>' `
  -DestinationPath '<NEW_ISOLATED_CLONE_PATH>'
```

Repeat on the other machine. Do not reuse one clone for concurrent processes.

## Run a scenario

Run the host first:

```powershell
.\Run-LiveValveProbe.ps1 `
  -Role Host `
  -Scenario Lobby `
  -Protection Baseline `
  -GamePath '<HOST_CLONE_PATH>' `
  -ExpectedPeerSteamId '<CLIENT_STEAMID64>' `
  -EvidenceRoot '<HOST_PRIVATE_EVIDENCE_ROOT>'
```

The host prints:

```text
HOST_HANDOFF=<HOST_STEAMID64>|<LOBBY_ID>
```

Keep the host running. Give the two values to the controlled client operator:

```powershell
.\Run-LiveValveProbe.ps1 `
  -Role Client `
  -Scenario Lobby `
  -Protection Baseline `
  -GamePath '<CLIENT_CLONE_PATH>' `
  -ExpectedPeerSteamId '<HOST_STEAMID64>' `
  -HostSteamId '<HOST_STEAMID64>' `
  -LobbyId '<LOBBY_ID>' `
  -EvidenceRoot '<CLIENT_PRIVATE_EVIDENCE_ROOT>'
```

Use the same procedure for each row:

| Test | Host scenario | Host protection | Client scenario | Client protection |
| --- | --- | --- | --- | --- |
| Valve FriendsOnly | `Lobby` | `Baseline` | `Lobby` | `Baseline` |
| Direct admission | `Direct` | `Baseline` | `Direct` | `Baseline` |
| Admission mitigation | `Direct` | `AdmissionGate` | `Direct` | `Baseline` |
| RPC impact | `Impact` | `Baseline` | `Impact` | `Baseline` |
| RPC mitigation | `Impact` | `RpcDefense` | `Impact` | `Baseline` |

Use a fresh host and client run for every row. Do not reuse a lobby ID. The
runner copies the default save into the host evidence directory for direct and
impact tests; it does not modify a normal player save.

## Verify a result

Copy the completed host and client evidence directories to one machine:

```powershell
.\Test-LiveValveEvidence.ps1 `
  -HostRunPath '<HOST_EVIDENCE_DIRECTORY>' `
  -ClientRunPath '<CLIENT_EVIDENCE_DIRECTORY>' `
  -HostSteamId '<HOST_STEAMID64>' `
  -ClientSteamId '<CLIENT_STEAMID64>' `
  -LobbyId '<LOBBY_ID>' `
  -Scenario Lobby `
  -Protection Baseline
```

Change `Scenario` and `Protection` to match the table. The verifier checks the
SteamIDs, non-friend results, lobby ID and type, callback flags, application
version, assembly and DLL hashes, lobby membership, FishNet lifecycle, runtime
state, persistence, and protection logs. It emits one of these only when the
required sources agree:

```text
VERDICT|ValveAcceptedUnrelatedIdentity|...
VERDICT|ValveEnforcedFriendsOnly|...
VERDICT|DirectAdmissionConfirmed|...
VERDICT|AdmissionGateRejectedNonMember|...
VERDICT|ImpactConfirmed|...
VERDICT|RpcDefenseBlockedImpact|...
```

Missing or conflicting evidence fails as `INCONCLUSIVE`.

Keep the raw evidence private. It contains exact SteamIDs, lobby IDs, local
paths, and disposable save data. Publish only a redacted verdict and the
matching version and file hashes.
