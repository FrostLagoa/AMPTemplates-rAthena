# rAthena AMP template

This package is published in the public `FrostLagoa/AMPTemplates-rAthena`
repository, mirrored under the Iris AMP integration and installed in the local
AMP deployment-template catalog.

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

`ragnarok-banner.jpg` was supplied by the server operator for this instance's
visual presentation. It is not part of rAthena and no rights to the underlying
Ragnarok Online artwork or marks are granted by this template package.

The runtime expects:

- `login-server.exe`, `char-server.exe`, `map-server.exe` and
  `web-server.exe` under the configured server root;
- MySQL-backed rAthena configuration prepared separately;
- TCP ports 6900, 6121, 5121 and 8888 available on the host;
- read/execute access to the checkout and write access to its log directory
  for the AMP instance operating-system identity.
