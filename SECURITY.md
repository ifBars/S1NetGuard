# Security and disclosure

This repository documents a multiplayer authorization issue, a defensive
host-side mod, and a controlled reproduction harness. The harness runs against
isolated game copies and test identities. It does not include packet
construction, serializer layouts, emulator binaries, proprietary game code,
game assets, saves, credentials, or captured Steam identifiers.

Do not use the findings or harness to access or interfere with a session you do
not own. Run the automated GSE lane only against the isolated host and client
created by the runner. Run the Valve lane only with controlled accounts and a
controlled host.

Give the game developer time to review the report. Discuss newly discovered
exploit details privately with the repository owner instead of opening a
public issue containing live identifiers or weaponized traffic.
