# Schedule I: insufficient P2P admission authorization enables post-entry RPC abuse

## Executive Summary

I found that the inspected Schedule I networking path can admit a direct Steam
P2P peer without proving that the host authorized the peer for the current
session. Lobby membership alone is not a sufficient authorization decision
when other software opens or modifies lobby visibility. This is the primary issue. The
transport identifies the remote Steam account, but the server accepts and
auto-authenticates the connection without an authorization decision based on
that identity.

Once the server admits an unknown peer, several server RPCs expand the practical
impact. The reviewed runtime includes ownership-bypassing RPCs that can alter
the shared online balance, display arbitrary world-space dialogue, or affect
NPC targeting. These are post-entry impact primitives, not the root cause.

I reviewed the current local Mono and IL2CPP wrapper binaries, the relevant
networking and RPC paths, and the supplied streamer clip. I did not independently
reproduce an offensive packet sequence or test against a public or live
session. The affected binaries were:

| Runtime | Assembly-CSharp.dll SHA-256 |
| --- | --- |
| Mono | `EFF38A4C5A176F27694721F29F3C06D9384CA123CEC8D325939C967520A857EE` |
| IL2CPP wrapper | `280BD0FCE9C600586CEEE454E67A01463BAE7B326E04B7EF11ECA8BA76BAD920` |

I could not establish an upstream patch-level version from these artifacts, so
this report identifies the affected builds by hash rather than claiming a
specific release range. The appropriate severity is High for multiplayer
session and save integrity. The review found no evidence of remote code
execution, host operating-system compromise, or Steam-account compromise.

## Background

Schedule I's Steam transport accepts inbound Steam Networking Sockets
connections through FishySteamworks. The connection's address exposes the
transport-verified remote SteamID. That identity is useful only if the server
uses it to make an admission decision.

The inspected base-game path requests a friends-only Steam lobby. Valve
documents that friends-only lobbies are joinable by friends and invitees but
do not appear in the lobby list. If the streamer's lobby was open, a setting or
another modification changed that base-game assumption. The incident callback
described below is stronger session-specific evidence and indicates that the
account appeared in the lobby. See Valve's
[ISteamMatchmaking documentation](https://partner.steamgames.com/doc/api/isteammatchmaking?language=english).

The expected multiplayer invariant is straightforward: a direct P2P transport
connection must not become a game session merely because the transport can
identify a Steam account. The host should admit the account only after a
host-controlled authorization decision. The defensive default in the attached
mod requires both current-lobby membership and immediate Steam friendship, or
an explicit SteamID allowlist entry. This preserves ordinary friend play while
preventing an unknown member of an open lobby from becoming an authenticated
game client.

The reviewed configuration does not assign a FishNet authenticator. FishNet's
`ServerManager` therefore follows its no-authenticator behavior and
auto-authenticates a connected client. FishNet's own
[ServerManager documentation](https://fish-networking.gitbook.io/docs/fishnet-building-blocks/components/managers/server-manager)
states that an empty authenticator allows clients to join without specialized
authentication. When we combine that behavior with FishySteamworks inbound
connection acceptance and no host-authorization check, the SteamID reaches a
trusted game session without a host-controlled trust decision.

## Vulnerability Details

We first reach the issue at the transport boundary. FishySteamworks accepts an
inbound Steam Networking Sockets connection and makes the verified remote
SteamID available as the connection address. I found no authenticator
assignment and no admission check that compares that identity with a
host-controlled trust decision.

The incident log supplies an important additional clue:

```text
Player join/leave: vee
ScheduleOne.Networking.SteamLobbyService:PlayerEnterOrLeave(LobbyChatUpdate_t)
```

The callback contains the changed user's SteamID, the account making the
change, the lobby ID, and state-change flags. The game discards those values in
this log line and resolves only the changed account's persona name. If `vee`
was the attacker, this event shows that the account appeared in the Steam lobby
as well as the game. It also means that a defense which trusts every current
lobby member would not stop this incident when the lobby is open. The callback
line alone does not distinguish entry from leave because the game also omits
the state flags.

The next transition matters because FishNet `ServerManager` auto-authenticates
when the configuration omits an authenticator. In other words, the server treats a
transport connection as a game-authorized connection without checking whether
the identified peer belongs in this session. A valid SteamID is not the same
as permission to join a particular lobby.

The admission flaw creates a broader RPC surface. The current Mono source has
295 `ServerRpc` declarations marked `RequireOwnership=false`. That count is an
inventory signal, not a claim that all 295 methods are exploitable. I reviewed
the following high-risk examples because their effects are useful after an
unknown peer reaches an authenticated session:

| RPC | Reviewed effect |
| --- | --- |
| `MoneyManager.CreateOnlineTransaction` | Accepts remotely controlled transaction name, unit amount, quantity, and note. The server applies unit amount multiplied by quantity to the shared online balance, and later persistence records the aggregate. |
| `NPC.SendWorldSpaceDialogue` and `Player.SendWorldSpaceDialogue` | Send remotely controlled text and duration to native world-space UI. |
| `CombatBehaviour.SetTargetAndEnable_Server(NetworkObject)` | Allows server-side AI target control for the supplied network object. |

These methods do not make arbitrary Steam friends untrusted. The concern is
the missing distinction between a peer the host intentionally admitted and an
unknown peer who reached the lobby or direct transport path. Once the server
loses that distinction, the wrong trust context can reach non-owner RPCs.

The reported streamer incident involved an unknown peer, repeated reconnects,
native-looking NPC text, following or forced behavior, and a balance change
from about 1M to 100K. The supplied 87-second clip visibly shows sequential
promotional messages, including a Discord invitation and social-media promotion,
rendered as colored native-looking world-space dialogue above a nearby NPC. The
NPC remains nearby while the player moves along the road. This supports the
reported dialogue behavior and is consistent with following, but it does not
identify the exact RPC or prove AI target manipulation.

The clip does not show the balance UI or a transaction, so it does not
independently corroborate the reported balance change. It also does not expose
the peer's SteamID or the original admission path. Those points remain incident
correlations rather than demonstrated parts of an end-to-end exploit.

[Streamer incident clip](../evidence/streamer-incident.mp4)
Normalized evidence SHA-256: `E15F23A9B6586DA0EFF7FFBE919D9EC08FC3A30938743B1C362D467E67D0C22E`

## Exploitability Analysis

The available evidence supports unauthorized admission, not a claim that a
single RPC alone bypasses every normal permission check. If an unknown peer can
establish an inbound transport connection and the server auto-authenticates it
without a host-controlled authorization decision, that peer enters the same broad
server-RPC trust boundary as a participant the host actually admitted.

From there, the reviewed methods supply concrete integrity impacts. We can
separate them by consequence: the transaction RPC can mutate the shared online
balance from remote values; the dialogue RPCs can create native-looking text
in the world; and the combat RPC can influence NPC targeting. Their practical
availability still depends on ordinary runtime conditions such as spawned
objects and the server state at the time of the call. This report does not
claim that every non-owner RPC is reachable in every session.

Repeated reconnects would be relevant because each successful transport
admission may recreate the same unauthorized session opportunity. A temporary
denylist is therefore useful as a host-side containment measure, but it is not
a replacement for checking admission before authentication.

The available evidence supports High severity because an uninvited account may
reach gameplay and persistence-affecting server functionality. It does not
support a claim of arbitrary code execution, a compromise of the host machine,
or access to the victim's Steam account. I also did not verify the exact cause
of the streamer's balance change, so it should remain an incident correlation,
not a demonstrated end-to-end exploit.

## Proof of Concept

I am intentionally omitting packet construction, RPC identifiers, serializer
details, and an offensive invocation sequence. Publishing those details would
turn a private admission finding into a directly reusable abuse guide.

The safe proof is structural and defensive. I completed the following checks:

1. Traced the current Mono transport ordering. FishySteamworks registers the
   connection-to-SteamID mapping before it raises FishNet's remote-start event.
   FishNet then creates the `NetworkConnection` and, with no authenticator,
   calls its authenticated-client path.
2. Built the defense mod independently for Mono (`netstandard2.1`) and IL2CPP
   (`net6.0`) with zero warnings and zero errors.
3. Ran eleven admission-policy scenarios covering local host, friend-plus-lobby
   authorization, explicit allowlist, unknown non-member, untrusted non-friend
   lobby member, invalid identity, fail-closed and explicit compatibility
   modes, session reconnect denial, and allowlist parsing.
4. Verified all twelve targeted admission, lobby-audit, and RPC method surfaces against both
   current assemblies by name prefix and signature.
5. Launched both real game backends with temporary deployments. Each loaded
   the mod through MelonLoader and installed all four targeted RPC guard pairs;
   the runner then removed the temporary DLL.

I have not yet run the final two-account network scenario. That controlled
test remains the required end-to-end confirmation:

1. Start a controlled host with an active Steam lobby and a test Steam account
   that is not a lobby member and is not allowlisted.
2. Instrument the transport admission path to record the transport-verified
   SteamID, the lobby-membership result, the allowlist result, and whether
   FishNet authentication begins.
3. Verify that the vulnerable configuration can reach authenticated-session
   handling without a successful membership or allowlist decision.
4. Install the proposed admission gate, then repeat the test. Verify that the
   gate rejects both a non-member and an untrusted non-friend lobby member
   before authentication, while accepting a Steam friend in the active lobby.
5. When you enable the optional RPC defense, exercise only defensive RPC tests:
   feed validly decoded test inputs into the generated RPC reader/handler
   boundary and verify that the reader consumes the expected fields while the
   handler suppresses dangerous money, free-text dialogue, and NPC control
   logic from remote callers.

Use only admission and suppression results as expected defensive test output:

```text
[PASS] Non-member SteamID rejected before FishNet authentication
[PASS] Steam friend in current lobby admitted
[PASS] Non-friend lobby member rejected unless explicitly allowed
[PASS] Explicitly allowlisted SteamID admitted
[PASS] Blocked SteamID denied on reconnect
[PASS] Protected RPC payload consumed; dangerous logic not executed
```

Run these tests only with accounts and hosts you control. The invariant needs
no public-session testing.

## Remediation

The fix should restore one invariant: an inbound direct Steam connection must
not authenticate into the game unless the host has authorized its
transport-verified SteamID for the current session.
This check belongs before FishNet auto-authentication, not after an RPC has
already reached game logic.

The defense mod included with this report enforces that invariant at the admission
boundary. It uses the verified transport SteamID, permits an immediate Steam
friend who is also in the current lobby or an explicit allowlist entry, and
denies all other inbound peers. A compatibility setting can trust every current
lobby member, but the mod disables it by default because it weakens protection
for open lobbies. A denylist blocks reconnect attempts, and an optional lobby join lock can close
new admissions when the host wants a fixed session. These defaults should
preserve ordinary lobby and friend play rather than treating friends as
untrusted by default.

The mod also has optional defense-in-depth protections at selected generated
RPC reader/logic paths. They preserve packet reads and suppress the selected
dangerous logic from remote callers. The mod disables this stricter mode by
default because it can affect legitimate invited-player actions. It is a useful
containment layer, but it must not substitute for admission control.

Tests must exercise both Mono and IL2CPP builds. The regression suite should
cover at least these cases:

1. Immediate Steam friend in the current lobby: accepted and authenticated.
2. Explicitly allowlisted non-member: accepted and authenticated.
3. Unknown non-member: rejected before authentication.
4. Non-friend current lobby member: rejected unless explicitly allowlisted.
5. Denylisted peer: rejected on the first and subsequent reconnect attempts.
6. Lobby join lock: blocks new joins according to its documented setting.
7. Protected RPC: consumes the expected payload but does not execute protected
   logic for a remote untrusted sender.

For an upstream fix, the game must make the same SteamID-to-membership/allowlist
decision in its own connection admission path. A game-level fix is preferable
to relying on every host to install a defensive mod.

## Summary

This issue is an authorization failure at the P2P admission boundary. The
transport can identify an inbound Steam peer, but the reviewed configuration
does not require a host-controlled authorization decision before FishNet
authenticates it. The incident's persona-only lobby callback also shows why
membership alone cannot serve as that decision for an open lobby.

We can then understand the RPC findings in their proper role: they make
unauthorized admission consequential by giving a wrongly admitted peer access
to gameplay and persistence-affecting actions. The reviewed evidence supports
High risk to session and save integrity. It does not support claims of RCE,
host compromise, or Steam-account compromise.

Future review should prioritize the other `RequireOwnership=false` RPCs by
checking sender context, object visibility, and server-side validation. That
work should remain distinct from the central repair: reject unknown direct P2P
peers before game authentication.
