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

AMP config version 11 exposes the complete supported non-secret scalar
configuration in the `Ragnarok Online:gamepad` page. Its 790 persisted fields
cover login, character, map, web, packet, script, log, inter-server structure
and every active battle setting. AMP writes them to the corresponding rAthena
`conf/import/*_conf.txt` override, so upstream files remain pristine and saved
changes take precedence on the next service start. `runtime-config` is a
verified directory junction to the real checkout; it is created in both AMP
path-resolution locations without replacing any existing non-junction path.
The protected local SQL import is anchored in the non-generated
`conf/inter_athena.conf` file after the AMP-managed inter-server import. This
keeps it effective and last even when MetaConfig completely rewrites
`conf/import/inter_conf.txt`; credentials, SQL identities, passwords and Vault
material are never mapped into AMP.
The Character server's `Player slots` setting writes `max_connect_user`; `-1`
keeps rAthena's unlimited mode and positive values impose the selected limit.

The supervisor drains every child output stream continuously through a
dedicated non-blocking console-input reader. Readiness additionally requires
the map server's confirmed `Map Server is now online.` registration event, not
only an early TCP 5121 listener, so AMP cannot expose character selection while
the map database is still loading.

On Genesis Server the entire live chain stays under
`NT AUTHORITY\NETWORK SERVICE`: the ADS Windows service launches the AMP
instance, AMP launches the foreground PowerShell supervisor, and the
supervisor launches all four rAthena executables without alternate
credentials. The instance is deliberately non-daemonized and does not start
on host boot. Application output remains in the AMP Console rather than
opening separate terminal windows.

`ragnarok-banner.jpg` was supplied by the server operator for this instance's
visual presentation. It is not part of rAthena and no rights to the underlying
Ragnarok Online artwork or marks are granted by this template package. The
operator-provided 588 x 219 source is center-cropped by 60 pixels on each side
to 468 x 219. That preserves the full height and closely matches the 460 x 215
Steam header proportion used by AMP's `steam:` display-image source, keeping
the instance card aligned with standard game banners.

The runtime expects:

- `login-server.exe`, `char-server.exe`, `map-server.exe` and
  `web-server.exe` under the configured server root;
- MySQL-backed rAthena configuration prepared separately;
- the pre-existing shared Iris MySQL account compatible with the native
  rAthena client, with its credentials supplied from the Iris Vault;
- TCP ports 6900, 6121, 5121 and 8888 available on the host;
- read/execute access to the checkout and write access to its log directory
  for the AMP instance operating-system identity.
