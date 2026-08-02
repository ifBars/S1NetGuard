# Schedule I: direct P2P admission bypasses lobby membership and exposes server RPCs

## Executive Summary

I confirmed, in controlled two-client testing with distinct emulated Steam
identities, that a Schedule I client can use the direct `LoadAsClient` path to
join a host while it is not a member of
the host's lobby. The host accepted the transport connection, FishNet
auto-authenticated it, and the client spawned a local player and loaded the
game. This is an admission-control failure: a transport-identified peer
crosses into the game session without a host-controlled authorization decision.

The primary effect gives an unauthorized peer session entry. Once the server admits
that peer, the peer reaches server RPCs intended for game participants. The
controlled tests then exercised three high-risk paths: a shared-money mutation,
free-text world-space dialogue, and NPC target control. The money test changed
the host's runtime balance from `0` to `-123.45` and persisted `-123.45` in two
separate successful runs.

I reviewed the controlled logs, the repro harness, the targeted defensive
patches, and the current Mono surface. The successful tests used Schedule I
`0.4.6f11 Alternate` on Mono with `Assembly-CSharp.dll` SHA-256
`EFF38A4C5A176F27694721F29F3C06D9384CA123CEC8D325939C967520A857EE`.
I did not test a live Valve backend or a public session.

The evidence supports High severity for multiplayer session and save integrity.
It does not show remote code execution, host operating-system compromise, or
Steam-account compromise.

## Background

The relevant trust boundary is between a Steam-compatible transport connection
and a game-authorized client. FishySteamworks supplies a transport address that
identifies the remote peer. FishNet can then authenticate the connection. A
secure host must make an explicit admission decision before that authentication
step: is this verified SteamID a current member of the active session, or did
the host otherwise authorize it?

Lobby visibility and game admission are different decisions. A FriendsOnly
lobby may influence how a backend exposes or joins a lobby, but it does not by
itself prove that every later direct transport connection has passed a
game-level authorization check. Friends are not generally untrusted. The
missing property is that the host never established whether this particular
direct peer belonged in this particular running session.

The inspected base-game `SteamLobbyService.CreateLobby` path requests
`k_ELobbyTypeFriendsOnly`. Valve documents that type as joinable by friends and
invitees and absent from the public lobby list. Valve returns the actual result
of a `JoinLobby` attempt through `LobbyEnter_t`. FishNet's separate behavior is
that a server without an authenticator advances a transport connection into
its authenticated-client path. The latter does not override Valve's lobby
rule; it matters when a client reaches the game transport without joining the
lobby. See the
[Steamworks matchmaking reference](https://partner.steamgames.com/doc/api/ISteamMatchmaking#ELobbyType),
the archived
[FishNet ServerManager documentation](https://web.archive.org/web/20240324100202/https://fish-networking.gitbook.io/docs/fishnet-building-blocks/components/managers/server-manager),
and FishNet's
[no-authenticator branch](https://github.com/FirstGearGames/FishNet/blob/main/Assets/FishNet/Runtime/Managing/Server/ServerManager.cs#L581-L587).

GSE 08.33.09.23 is a controlled Steam-compatible emulator and does not prove
Valve FriendsOnly backend behavior. The live Valve two-account FriendsOnly
join question remains unverified. The controlled result is narrower and still
material: after the harness created a one-member FriendsOnly lobby, a
non-member direct client reached an authenticated, loaded game session.

## Vulnerability Details

We start with a host whose current lobby contains only the host identity. The
second controlled identity is neither a current lobby member nor an immediate
Steam friend. It invokes the game's direct `LoadAsClient` route instead of
joining the lobby. The harness records both the client's lobby state and the
host's FishNet lifecycle events without publishing packet identifiers,
serialization details, or an offensive invocation recipe.

In baseline run `20260802-075529-e3b15683`, the client remained outside the
lobby before and after the direct action. On the host, the remote connection
appeared with `peerInLobby=false`, and the FishNet authentication callback ran
with `authenticatedBeforeCall=false`. The client then reported an authenticated
FishNet client, a spawned local player, a loaded game, and the main game scene.
The controlled bypass therefore crossed all of these state changes:

```text
not in host lobby
    -> direct LoadAsClient
    -> remote transport connection accepted
    -> FishNet client authenticated
    -> player spawned and game loaded
```

This is not an inference from a UI state alone. The host and client logs agree
on the remote connection, authentication callback, absent lobby membership,
and completed load. The reviewed repro harness also instruments the FishNet
remote-connection and `ClientAuthenticated` lifecycle methods, so we can place
the missing authorization check before the latter transition.

The post-entry impact surface includes these reviewed non-owner RPC paths:

| Path | Controlled effect |
| --- | --- |
| `MoneyManager.CreateOnlineTransaction` | Changed the shared online balance and its persisted value in the successful tests. |
| `NPC.SendWorldSpaceDialogue` | Reached the native world-space dialogue path with controlled test text and duration. |
| `CombatBehaviour.SetTargetAndEnable_Server(NetworkObject)` | Reached the server-side NPC target-control path with a controlled test object. |

These are impact primitives after admission, not independent proof that every
non-owner RPC is reachable or unsafe. Their presence matters because the server
has already treated a non-member direct peer as an authenticated participant.

### Incident correlation

The supplied streamer clip shows promotional text rendered through the game's
native-looking world-space dialogue above a nearby NPC. The NPC stays close as
the player moves. That footage supports the reported dialogue behavior and is
consistent with NPC control, but it does not identify the exact RPC. The clip
does not show the reported balance change or the original join sequence.

At the start of the clip, the controlled dialogue visibly promotes five
Instagram accounts. In separately supplied profile screenshots, one of those
accounts uses the display name `vee`, matching the persona in the game's lobby
log. This strengthens the correlation between the logged lobby participant and
the party controlling or promoting content through the dialogue. It does not
prove that the same person controlled both accounts, identify a real person, or
rule out promotion or impersonation of an unrelated account. The profile
screenshots contain unnecessary personal information, so I retain them only in
the private evidence archive.

The accompanying log contains `Player join/leave: vee` from
`SteamLobbyService.PlayerEnterOrLeave(LobbyChatUpdate_t)`. That callback carries
the lobby ID, changed SteamID, actor SteamID, and member-state flags. The game
logs only the persona name. Without the omitted flags, the line cannot tell us
whether the state indicated entry, leave, disconnect, or removal. If a full callback
shows `k_EChatMemberStateChangeEntered`, then it proves lobby membership changed;
it still does not explain whether Valve treated the account as a friend or
invitee, or whether another component changed the lobby type.

[Streamer incident clip](../evidence/streamer-incident.mp4)

## Exploitability Analysis

The evidence supports a repeatable controlled chain rather than a speculative
one. We first establish that the peer is not in the host lobby, then direct
admission succeeds, then FishNet authenticates the peer, and only then do the
controlled game actions run. This sequencing keeps the root cause clear: the
problem is not that a dialogue or money RPC independently defeats lobby rules.
The problem is that the server admits the wrong peer before it evaluates
application-level authority.

Controlled run `20260802-080454-ef9ecfc3` passed the corrected impact
assertions. It recorded all three paths, changed the host runtime balance from
`0` to `-123.45`, and persisted `-123.45`. Fresh run
`20260802-080549-75b31251` repeated the same result with a different controlled
identity pair: all three paths ran, the runtime balance became `-123.45`, and
the save contained `-123.45`.

The prior run `20260802-080236-27d7eacc` is not an accepted money-impact
result. The save contained `-123.45`, but the probe sampled the server RPC stage
before the observer-side balance mutation and recorded the wrong runtime value.
The runner then compared persistence against that bad measurement. The later
corrected and fresh runs observe the actual mutation and are the evidence for
the runtime and persistence result.

I exclude run `20260802-080907-14426b9f` from the mitigation evidence
because the harness failed to share the required client-side file. It is not a
negative result for the defense. Do not combine it with the completed tests.

The practical consequence is host session and save integrity loss. A wrongly
admitted account can receive the same broad RPC opportunity as a permitted
participant. The exact effects remain bounded by server state, spawned objects,
and per-RPC validation. I found no evidence that this path gives arbitrary code
execution, compromises the host machine, or compromises a Steam account.

## Proof of Concept

I intentionally omit packet construction, RPC identifiers, serialization
layouts, and the procedure for invoking these paths against another person's
host. The proof of concept is a controlled two-client validation with distinct
emulated identities and a host under the researcher's control.

The following completed runs form the evidence set:

| Run | Result | What it establishes |
| --- | --- | --- |
| `20260802-075529-e3b15683` | PASS | Direct non-member admission, FishNet authentication, local-player spawn, and game load. |
| `20260802-080454-ef9ecfc3` | PASS | Corrected end-to-end impact: controlled money, dialogue, and combat paths; runtime and persisted balance `-123.45`. |
| `20260802-080549-75b31251` | PASS | Fresh repeat of the corrected impact result, including persisted `-123.45`. |
| `20260802-075809-70af89f6` | PASS | Admission mitigation rejects the non-member before authentication. |
| `20260802-081044-1dc07c57` | PASS | RPC defense validation with an explicitly allowlisted test peer. |

The admission-mitigation run logged the non-member as `NotInCurrentLobby` and
rejected the connection before the client reached the authenticated game state.
The RPC-defense run intentionally allowlisted the test peer so it could pass
the admission gate and exercise the second layer. It logged blocks for all
three protected capabilities, retained a runtime balance of `0`, and persisted
`0`.

In that protected run, the observational Harmony prefixes for dialogue and
combat still ran. Those prefixes only observe method entry; they are not proof
that the underlying game logic executed. The authoritative defensive evidence
is the three block logs, the absent money sink, and the unchanged runtime and
persisted balance.

The test harness should remain private or defensive in scope. A safe regression
test starts a host with a one-member lobby, attempts direct admission from a
controlled non-member, and asserts rejection before `ClientAuthenticated`.
Separate tests should allow a deliberately approved peer, then verify that the
high-risk RPC handlers reject an unauthorized sender without altering money,
dialogue, or NPC-control state.

## Remediation

The game must authorize the transport-verified SteamID before it calls
`ClientAuthenticated` or creates the player's game state. The authorization
source should be a host-controlled session decision, such as an explicit
invite/session allowlist or membership in the active invited session. A failed
identity lookup must fail closed, and a rejected identity should not reconnect
into the same session without a new host decision.

FishNet already provides the correct extension point. The game should attach a
custom `Authenticator` to `ServerManager` before it starts the server. That
authenticator should resolve the FishySteamworks transport address to a
SteamID, compare it with the host-approved session roster, and report success
only after the check passes. A simplified shape is:

```csharp
sealed class SessionSteamAuthenticator : Authenticator
{
    public override event Action<NetworkConnection, bool> OnAuthenticationResult;

    public override void OnRemoteConnection(NetworkConnection connection)
    {
        ulong steamId = ReadVerifiedTransportSteamId(connection);
        bool allowed = sessionAdmission.Allows(steamId);
        OnAuthenticationResult?.Invoke(connection, allowed);
    }
}
```

The game must configure this authenticator before FishNet accepts remote
connections. FishNet then calls `ClientAuthenticated` only after the
authenticator reports success. The game should build the session roster from an
explicit host decision, accepted invitation, or the intended lobby policy. It
should not infer permission from knowledge of the host SteamID. The game should
log the admission decision and reason without exposing sensitive session data
to remote clients.

The game should also require sender authorization for high-risk RPCs even after
admission. Ownership bypasses must be narrow and explicit. For example:

```csharp
[ServerRpc(RequireOwnership = false)]
void CreateOnlineTransaction(Transaction request, NetworkConnection sender)
{
    if (!sessionAuthority.CanMutateSharedMoney(sender, request))
        return;

    ApplyValidatedTransaction(request);
}
```

Apply the same pattern to world-space dialogue and NPC target control. Validate
the sender's session role, relationship to the target object, and the semantic
limits of each request. Do not rely on successful transport authentication as
the authorization decision for shared state.

Regression coverage should include a non-member direct peer, an explicitly
approved peer, a stale or unavailable lobby lookup, a reconnect after denial,
and each high-risk RPC with both allowed and denied senders. Run the suite on
both Mono and IL2CPP after the game-level repair.

## Summary

The controlled evidence shows that direct `LoadAsClient` admission can bypass
current lobby membership in the tested Steam-compatible environment. The host
accepts the connection, FishNet authenticates it, and the client spawns and
loads into the game. Corrected tests then show controlled money, dialogue, and
NPC-control effects, including two persisted `-123.45` balance changes.

The repair is to make a host-controlled SteamID admission decision before
`ClientAuthenticated`, then enforce sender authority on high-risk RPCs as a
second layer. The result is a High session and save-integrity issue, not evidence
of RCE, host compromise, Steam-account compromise, or confirmed live Valve
FriendsOnly behavior.
