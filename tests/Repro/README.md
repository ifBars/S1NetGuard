# Controlled multiplayer reproduction

This harness reproduces the admission and RPC findings on two isolated Mono
game instances. It supports two separate backends:

- GSE/Goldberg for repeatable local automation.
- Valve Steam for a later two-machine control with real unrelated accounts.

The GSE run exercises Schedule I, FishySteamworks, FishNet, and the game RPCs.
It is valid evidence for the game-level direct-admission path. It is not
evidence that Valve permits an unrelated account to enter a FriendsOnly lobby.

Use this harness only with game installations and accounts you control. It
does not include Schedule I files, MelonLoader, GSE, Steam credentials, saves,
or built DLLs.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7.
- .NET 8 SDK.
- A local Schedule I Mono installation with MelonLoader.
- A local GSE `steam_api64.dll` for the automated lane.
- Enough free space for mutable plugin and loader copies. Large immutable game
  directories use links when possible.

The runner refuses a non-GSE emulator DLL and refuses to start while any
Schedule I process is already running.

## Automated GSE matrix

Set local paths once in the shell:

```powershell
$game = '<MONO_GAME_PATH>'
$gse = '<GSE_STEAM_API64_PATH>'
```

Run each scenario from the repository root:

```powershell
# Backend control: unrelated emulated identity joins a FriendsOnly lobby.
.\tests\Repro\Run-GseRepro.ps1 -Scenario Lobby -GamePath $game -GseSteamApiPath $gse

# Root cause: a non-lobby client reaches an authenticated, loaded game.
.\tests\Repro\Run-GseRepro.ps1 -Scenario Direct -GamePath $game -GseSteamApiPath $gse

# Admission mitigation: S1NetGuard rejects the non-member before authentication.
.\tests\Repro\Run-GseRepro.ps1 -Scenario Direct -ProtectHost -GamePath $game -GseSteamApiPath $gse

# Impact: controlled money, dialogue, NPC targeting, and save persistence.
.\tests\Repro\Run-GseRepro.ps1 -Scenario Impact -GamePath $game -GseSteamApiPath $gse

# RPC mitigation: an allowlisted peer connects, but the reviewed RPCs are blocked.
.\tests\Repro\Run-GseRepro.ps1 -Scenario Impact -ProtectHost -VerifyRpcDefense -GamePath $game -GseSteamApiPath $gse
```

Each run creates unique host, client, shared-state, and evidence directories.
By default, the disposable instances are created beside the source game so
large immutable files can use same-volume hard links. Use `-InstanceRoot` to
choose another location with sufficient free space. The impact test copies
`StreamingAssets/DefaultSave` into the run directory. It does not load or
modify a player save. The runner removes the isolated game instances unless
`-KeepInstances` is supplied. Evidence remains under the ignored
`artifacts/admission-repro` directory.

A successful run ends with one of these markers:

```text
PASS|S1NetGuard.AdmissionRepro|Lobby|Baseline|...
PASS|S1NetGuard.AdmissionRepro|Direct|Baseline|...
PASS|S1NetGuard.AdmissionRepro|Direct|Protected|...
PASS|S1NetGuard.AdmissionRepro|Impact|Baseline|...
PASS|S1NetGuard.AdmissionRepro|Impact|RpcDefense|...
```

Do not combine host and client files from different run IDs. A failed or timed
out phase is not a negative security result.

## Real Valve control

The real-Steam lane uses a fresh lobby and two unrelated accounts. It records
the actual `CreateLobby` and `JoinLobby` arguments, both callbacks, member
flags, FishNet lifecycle, state changes, and matching file hashes.

Follow [LIVE-VALVE.md](LIVE-VALVE.md) when two machines or isolated Steam
sessions are available. Until that matrix runs, Valve FriendsOnly enforcement
and live direct transport admission remain deferred findings.

## Repository-only checks

These checks need no game files:

```powershell
.\tests\Validate-Repository.ps1
```

They run the 12-case admission-policy verifier, parse every PowerShell test
script, exercise every live-evidence verdict with synthetic fixtures, and
reject tracked binaries or private test artifacts.
