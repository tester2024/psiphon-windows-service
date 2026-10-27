# Psiphon as a Windows service

This is a thin Windows service wrapper around
[psiphon-tunnel-core](https://github.com/Psiphon-Labs/psiphon-tunnel-core).
It keeps the tunnel running in the background, starts it at boot, and puts the
local SOCKS5 proxy on `127.0.0.1:9999`.

The tunnel core itself is a console program and does not implement the Windows
service interface, so `psiphon-service.exe` takes care of that part: starting
the tunnel, restarting it when it exits, reloading it when the config changes,
and stopping it when Windows stops the service.

## What you get

- `PsiphonTunnelCore` service, automatic start, runs as `LocalSystem`
- SOCKS5 on `127.0.0.1:9999` (HTTP proxy available but off by default)
- a `psiphon` command for status, country selection, speed tests and logs
- automatic reload when `config\psiphon.config` changes, no restart needed

## Install

Grab `psiphon-windows-service-<version>.zip` from the releases page, extract
it anywhere (for example `C:\Tools\psiphon`), then run:

```powershell
powershell -ExecutionPolicy Bypass -File scripts\install.ps1
```

The script asks for administrator rights, writes the config for the folder you
extracted to, registers the service and adds the `cli` folder to your user
`PATH`. Open a new terminal afterwards and check:

```powershell
psiphon status
```

The proxy starts listening immediately, but it needs 20-60 seconds to fetch a
server list and connect. Requests fail until `psiphon status` shows a region.

### Using the proxy

```
type: SOCKS5 (or SOCKS5h, remote DNS)
host: 127.0.0.1
port: 9999
auth: none
```

```powershell
curl.exe -x socks5h://127.0.0.1:9999 https://api.ipify.org
```

The proxy is bound to localhost. To use it from other machines, add
`"ListenInterface": "any"` to `config\psiphon.config` and allow port 9999 in
Windows Firewall. Only do that on a network you trust.

## Commands

| Command | What it does |
| --- | --- |
| `psiphon status` | service state, listeners, configured and connected region |
| `psiphon set-country de` | connect through Germany; `auto` for the best server anywhere |
| `psiphon regions` | countries the network is currently offering |
| `psiphon socks 9999` | show or change the SOCKS5 port |
| `psiphon http off` | enable/disable the HTTP proxy (`psiphon http 8080`) |
| `psiphon test` | exit IP, latency/jitter, download and upload |
| `psiphon ping` / `psiphon speed` | one half of the test |
| `psiphon logs 50` | tail the tunnel log |
| `psiphon start/stop/restart` | service control (asks for elevation) |

`psiphon test` runs through the tunnel and takes about 15 seconds:

```
  Psiphon speed test
  ----------------------------------------------------------------
  exit IP    172.232.154.35    SE  |  Stockholm  |  AS63949 Akamai Connected Cloud
  socks5 127.0.0.1:9999  |  server SE  |  QUIC-OSSH
  ----------------------------------------------------------------

  ----------------------------------------------------------------
  latency     121 ms avg   min 112  |  max 129  |  jitter 8 ms  (5 samples)
  download   0.67 Mbps avg peak 1.23  |  2.0 MB in 25.2 s
  upload     1.82 Mbps avg  |  1.0 MB in 4.3 s
  ----------------------------------------------------------------
```

Defaults are 5 pings, 2 MB down and 1 MB up. `psiphon test quick` uses smaller
sizes, `psiphon test 10` uses a 10 MB download. Results are appended to
`logs\speedtest.log`.

## Configuration

`config\psiphon.config` is a normal tunnel-core config. The bootstrap values
(server list URLs and signature keys) come from the public Psiphon Windows
client, so no account or token is needed.

Useful keys:

```jsonc
"LocalSocksProxyPort": 9999,
"DisableLocalSocksProxy": false,
"LocalHttpProxyPort": 0,
"DisableLocalHttpProxy": true,
"EgressRegion": "DE",        // omit for "best server anywhere"
"ListenInterface": ""        // "" = localhost, "any" = all interfaces
```

Save the file and the service reloads the tunnel within a couple of seconds.
`psiphon set-country` and `psiphon socks` edit the same file.

## Limitations

- **No UDP.** The local proxy implements SOCKS5 `CONNECT` only; there is no
  `UDP ASSOCIATE` and no UDP relay. Apps that need UDP (WireGuard, most game
  voice chat, some QUIC-only clients) will not work through it.
- Windows only. The service host is Windows-specific and the TUN/packet
  tunnel support in psiphon-tunnel-core is not implemented for Windows.
- The tunnel needs a few seconds after boot before it can carry traffic.
- If the machine has a system-wide proxy or a firewall that blocks the Psiphon
  servers, the client will keep retrying, but it may not connect.

## Files

```
bin\psiphon-tunnel-core.exe   tunnel core, built from source
bin\psiphon-service.exe       service host
cli\psiphon.ps1               command line helper
config\psiphon.config         generated at install time
config\service.json           generated at install time
data\                         tunnel data store
logs\                         service and tunnel logs
scripts\install.ps1           installer
scripts\uninstall.ps1         removes the service
```

Logs rotate at 5 MB for `service.log` and 10 MB for the tunnel logs.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File scripts\uninstall.ps1
```

This removes the service and the `PATH` entry. Config, data and logs stay where
they are; delete the folder to remove everything.

## Build from source

You need Go 1.26 or newer and git.

```powershell
git clone https://github.com/Psiphon-Labs/psiphon-tunnel-core.git upstream
git -C upstream checkout v2.0.42

# tunnel core
cd upstream
$env:CGO_ENABLED = "0"
$env:GOFLAGS = "-mod=vendor"
go build -trimpath -ldflags "-s -w" -o ..\bin\psiphon-tunnel-core.exe .\ConsoleClient
cd ..

# service host
cd service
$env:GOFLAGS = ""
go build -trimpath -ldflags "-s -w" -o ..\bin\psiphon-service.exe .
```

The GitHub workflow does the same on every push and publishes a zip on tags.

## Credits

- [psiphon-tunnel-core](https://github.com/Psiphon-Labs/psiphon-tunnel-core)
  by Psiphon Inc., GPLv3.
- The service host and the PowerShell helper in this repo are GPLv3 as well;
  see `LICENSE`.
