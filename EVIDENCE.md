# Evidence status

This page separates source review, emulated runtime evidence, live Valve
evidence, and deferred work. Raw logs contain SteamIDs, lobby IDs, local paths,
and disposable saves, so they remain outside Git.

| Claim | Status | Evidence boundary |
| --- | --- | --- |
| Schedule I requests a four-member FriendsOnly lobby. | Confirmed | Mono source review and a live Valve host-side API-boundary probe captured `CreateLobby(k_ELobbyTypeFriendsOnly, 4)`. |
| An unrelated identity can enter that lobby through Valve `JoinLobby`. | Deferred | Requires two unrelated real Steam accounts. GSE behavior cannot answer this platform-policy question. A denial counts as FriendsOnly enforcement only if `LobbyEnter_t` returns `k_EChatRoomEnterResponseNotAllowed` and both membership views show no entry; other failures are inconclusive. |
| A client can skip lobby membership and connect through `LoadAsClient`. | Confirmed on Mono/GSE | Run `20260802-075529-e3b15683` recorded `peerInLobby=false`, FishNet authentication, player spawn, and completed game load. |
| The admitted client can affect shared money, native dialogue, and NPC targeting. | Confirmed on Mono/GSE | Runs `20260802-080454-ef9ecfc3` and `20260802-080549-75b31251` reached all three paths and persisted `-123.45`. |
| S1NetGuard rejects a direct non-member before FishNet authentication. | Confirmed on Mono/GSE | Run `20260802-075809-70af89f6` rejected the peer as `NotInCurrentLobby`. |
| S1NetGuard blocks the reviewed RPC paths for an admitted peer. | Confirmed on Mono/GSE | Run `20260802-081044-1dc07c57` logged all three blocks and preserved runtime and persisted balance at `0`. |
| The mod loads and resolves its target surfaces on both game runtimes. | Confirmed | Mono and IL2CPP builds and startup probes passed. Static surface verification passed for the reviewed runtime seams. |
| The full exploit and mitigation chain reproduces on IL2CPP. | Not tested | IL2CPP build, startup, and surface compatibility do not substitute for a two-client gameplay reproduction. |
| The direct path reproduces between two real Valve Steam accounts. | Deferred | The live host half passed; a matching client run has not been performed. |

## GSE compatibility boundary

GSE is a local test substitute for the game-facing Steam API, not evidence that
Valve's backend makes the same admission decisions. The Goldberg project
documents a drop-in replacement for `steam_api(64).dll` that emulates Steam
online features over LAN. Its implementation exposes the Steam matchmaking
interfaces, returns `LobbyEnter_t`, and emits `LobbyChatUpdate_t`, allowing the
unmodified Schedule I, FishySteamworks, FishNet, and game RPC code to run with
two distinct local identities.

Goldberg explicitly prioritizes accurate API behavior, but does not claim
backend equivalence. Its matchmaking source also shows a material difference:
FriendsOnly lobbies are included in emulator searches, and the lobby owner
accepts a JOIN message without checking friendship or an invitation. Valve
documents `k_ELobbyTypeFriendsOnly` as joinable only by friends and invitees
and absent from the lobby list.

Accordingly, the GSE runs prove the game-level chain after a transport peer can
reach the host: absent FishNet authenticator, non-member admission, player load,
and the reviewed RPC effects. They do not prove that an unrelated Valve account
can discover or join the lobby, or that Valve will route the same direct peer.
That last boundary still requires the prepared two-machine, two-account Valve
test.

Primary sources:

- [Goldberg project README](https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/blob/master/README.md)
- [Goldberg matchmaking implementation](https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/blob/master/dll/steam_matchmaking.h#L1122-1150)
- [Goldberg JOIN handling](https://gitlab.com/Mr_Goldberg/goldberg_emulator/-/blob/master/dll/steam_matchmaking.h#L1341-1352)
- [Valve ISteamMatchmaking documentation](https://partner.steamgames.com/doc/api/ISteamMatchmaking#ELobbyType)

## Accepted controlled runs

| Run | Result |
| --- | --- |
| `20260802-075529-e3b15683` | Direct non-member admission and game load. |
| `20260802-080454-ef9ecfc3` | Corrected money, dialogue, NPC-control, and persistence result. |
| `20260802-080549-75b31251` | Independent repeat of the corrected impact result. |
| `20260802-075809-70af89f6` | Admission-gate rejection before authentication. |
| `20260802-081044-1dc07c57` | RPC defense with an explicitly allowlisted controlled peer. |

## Public harness validation

After moving the controlled workflow into `tests/Repro`, the complete documented
matrix passed again from the repository layout:

| Run | Result |
| --- | --- |
| `20260802-141542-2ae0dc44` | GSE FriendsOnly backend control. |
| `20260802-141615-e261dbe4` | Direct non-member admission and completed game load. |
| `20260802-141659-ece0d236` | Admission gate rejected the non-member before authentication. |
| `20260802-141740-41783245` | Money, dialogue, NPC targeting, and persisted `-123.45`. |
| `20260802-141820-9dd95a9e` | RPC guards blocked all three paths; runtime and persisted balance remained `0`. |
| `20260802-143337-8fcfc36a` | Fresh direct-admission run recorded `GetAuthenticator()` as null immediately before the non-member authenticated and loaded. |

Run `20260802-080236-27d7eacc` used an incorrect observation point for the
runtime money assertion. Run `20260802-080907-14426b9f` lost a required
client-side evidence file. Neither run supports a positive or negative claim.

## Tested build

- Schedule I: `0.4.6f11 Alternate` (Mono).
- `Assembly-CSharp.dll` SHA-256:
  `EFF38A4C5A176F27694721F29F3C06D9384CA123CEC8D325939C967520A857EE`.
- Local Steam API replacement: file version `08.33.09.23`, SHA-256
  `EF32F9BB1FEF9E9B58F3EA06F88B2EA1E206C861A4D0431D287E537C59A1A391`.

The local binary identifies itself as `GSE Client API`. Its exact build lineage
cannot be established from authoritative Goldberg release metadata, so the
version string is recorded as local binary metadata rather than a Goldberg
release number.

The repository includes the controlled harness and evidence verifiers, but not
the game, GSE, generated IL2CPP wrappers, raw logs, test saves, or compiled
mod/probe binaries.
