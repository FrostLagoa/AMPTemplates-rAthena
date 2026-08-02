# rAthena AMP template

This package is published in the public `FrostLagoa/AMPTemplates-rAthena`
repository and mirrored under the Iris AMP integration. ADS registers that
repository directly; Iris never copies files into the official CubeCoders
catalog.

AMP 2.8 requires the root `manifest.json` to classify this repository as an
`AppTemplates` source before any `.kvp` file is indexed.

The template deliberately manages an existing Windows rAthena checkout rather
than downloading or updating game files. On the Genesis Server host the
authoritative checkout remains `D:\Ragnarok`.

`rathena-supervisor.ps1` is the single AMP foreground process. It starts and
monitors login, character, map and optional web services, merges their output
into the AMP console, performs bounded crash recovery and sends
`server:shutdown` to the stateful rAthena services before forcing a remaining
process to exit.

The template update stage refreshes only the supervisor. It never overwrites
the customized rAthena checkout, SQL data or local secrets.

On Genesis Server the entire live chain stays under
`NT AUTHORITY\NETWORK SERVICE`: the ADS Windows service launches the AMP
instance, AMP launches the foreground PowerShell supervisor, and the
supervisor launches all four rAthena executables without alternate
credentials. The instance is deliberately non-daemonized and does not start
on host boot. Application output remains in the AMP Console rather than
opening separate terminal windows.

`ragnarok-banner.jpg` was supplied by the server operator for this instance's
visual presentation. It is not part of rAthena and no rights to the underlying
Ragnarok Online artwork or marks are granted by this template package.

The runtime expects:

- `login-server.exe`, `char-server.exe`, `map-server.exe` and
  `web-server.exe` under the configured server root;
- MySQL-backed rAthena configuration prepared separately;
- a dedicated least-privilege MySQL account compatible with the native
  rAthena client, with its credentials supplied from the Iris Vault;
- TCP ports 6900, 6121, 5121 and 8888 available on the host;
- read/execute access to the checkout and write access to its log directory
  for the AMP instance operating-system identity.
