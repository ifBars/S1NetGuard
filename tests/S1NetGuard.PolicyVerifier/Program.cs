using S1NetGuard.Security;

const string LobbyMember = "76561198000000001";
const string ExplicitMember = "76561198000000002";
const string Stranger = "76561198000000003";

var lobbyMembers = new[] { LobbyMember };
var allowlist = new HashSet<ulong> { ulong.Parse(ExplicitMember) };
var denylist = new HashSet<ulong>();

ExpectAllowed(
    AdmissionPolicy.Evaluate(
        AdmissionPolicy.LocalHostConnectionId,
        null,
        false,
        Array.Empty<string>(),
        false,
        true,
        false,
        allowlist,
        denylist,
        true),
    AdmissionReason.LocalHost,
    "local host bypass");
ExpectAllowed(
    AdmissionPolicy.Evaluate(1, LobbyMember, true, lobbyMembers, true, true, false, allowlist, denylist, true),
    AdmissionReason.SteamFriendInLobby,
    "verified Steam friend in lobby");
ExpectAllowed(
    AdmissionPolicy.Evaluate(2, ExplicitMember, true, lobbyMembers, false, true, false, allowlist, denylist, true),
    AdmissionReason.ExplicitAllowlist,
    "explicit allowlist");
ExpectDenied(
    AdmissionPolicy.Evaluate(3, Stranger, true, lobbyMembers, false, true, false, allowlist, denylist, true),
    AdmissionReason.NotInCurrentLobby,
    "direct non-member");
ExpectDenied(
    AdmissionPolicy.Evaluate(4, "not-a-steamid", true, lobbyMembers, false, true, false, allowlist, denylist, true),
    AdmissionReason.InvalidTransportIdentity,
    "unverifiable transport identity");
ExpectDenied(
    AdmissionPolicy.Evaluate(5, Stranger, false, Array.Empty<string>(), false, true, false, allowlist, denylist, true),
    AdmissionReason.LobbyUnavailable,
    "fail closed without lobby state");
ExpectAllowed(
    AdmissionPolicy.Evaluate(6, Stranger, false, Array.Empty<string>(), false, true, false, allowlist, denylist, false),
    AdmissionReason.FailOpen,
    "explicit fail-open compatibility mode");

denylist.Add(ulong.Parse(Stranger));
ExpectDenied(
    AdmissionPolicy.Evaluate(7, Stranger, true, new[] { Stranger }, false, true, false, allowlist, denylist, true),
    AdmissionReason.SessionDenied,
    "session denylist wins over later lobby membership");

ExpectDenied(
    AdmissionPolicy.Evaluate(8, Stranger, true, new[] { Stranger }, false, true, false, allowlist, new HashSet<ulong>(), true),
    AdmissionReason.UntrustedLobbyMember,
    "non-friend lobby member rejected");
ExpectAllowed(
    AdmissionPolicy.Evaluate(9, Stranger, true, new[] { Stranger }, false, true, true, allowlist, new HashSet<ulong>(), true),
    AdmissionReason.TrustedLobbyMemberCompatibility,
    "explicit trust-all-lobby compatibility mode");

HashSet<ulong> parsed = AdmissionPolicy.ParseSteamIdSet($" {LobbyMember},invalid;{ExplicitMember}\n{LobbyMember} ");
if (parsed.Count != 2 || !parsed.Contains(ulong.Parse(LobbyMember)) || !parsed.Contains(ulong.Parse(ExplicitMember)))
{
    throw new InvalidOperationException("SteamID allowlist parsing did not normalize and deduplicate values.");
}

Console.WriteLine("PASS|S1NetGuard.PolicyVerifier|11 scenarios");

static void ExpectAllowed(AdmissionDecision decision, AdmissionReason reason, string scenario)
{
    if (!decision.Allowed || decision.Reason != reason)
    {
        throw new InvalidOperationException($"{scenario}: expected allowed/{reason}, got {decision.Allowed}/{decision.Reason}.");
    }
}

static void ExpectDenied(AdmissionDecision decision, AdmissionReason reason, string scenario)
{
    if (decision.Allowed || decision.Reason != reason)
    {
        throw new InvalidOperationException($"{scenario}: expected denied/{reason}, got {decision.Allowed}/{decision.Reason}.");
    }
}
