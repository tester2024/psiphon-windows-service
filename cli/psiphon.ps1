#Requires -Version 5.1
<#
  psiphon - control panel for the Psiphon tunnel service.

    psiphon status
    psiphon set-country de
    psiphon socks 9999
    psiphon test

  Speed measurements live in speedtest.ps1 and are dot-sourced below.
#>

param(
    [Parameter(Position = 0)][string]$Command = "status",
    [Parameter(Position = 1)][string]$Value
)

$ErrorActionPreference = "Stop"

$Root        = Split-Path -Parent $PSScriptRoot
$ConfigPath  = Join-Path $Root "config\psiphon.config"
$TunnelLog   = Join-Path $Root "logs\psiphon.err.log"
$SpeedLog    = Join-Path $Root "logs\speedtest.log"
$ServiceName = "PsiphonTunnelCore"

# ---------------------------------------------------------------------------
# small helpers
# ---------------------------------------------------------------------------

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-Config {
    Get-Content $ConfigPath -Raw | ConvertFrom-Json
}

function Save-Config($Config) {
    $json = $Config | ConvertTo-Json -Depth 10
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-Notice([string]$Pattern) {
    if (-not (Test-Path $TunnelLog)) { return $null }
    Select-String -Path $TunnelLog -Pattern $Pattern | Select-Object -Last 1
}

function Test-Listening([int]$Port) {
    (netstat -ano | Select-String ":$Port\s" | Select-String "LISTENING") -ne $null
}

function Start-Elevated([string]$Arguments) {
    $proc = Start-Process powershell.exe `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $Arguments) `
        -Verb RunAs -PassThru -Wait

    return $proc.ExitCode
}

function Control-Service([string]$Action) {
    if (Test-Admin) {
        switch ($Action) {
            "start"   { Start-Service -Name $ServiceName }
            "stop"    { Stop-Service -Name $ServiceName -Force }
            "restart" { Restart-Service -Name $ServiceName -Force }
        }

        Get-Service -Name $ServiceName | Format-Table Name, Status, StartType -AutoSize
        return
    }

    $code = Start-Elevated "& '$PSCommandPath' $Action"
    if ($code -ne 0) { Write-Host "elevated '$Action' failed (exit $code)" }
}

# ---------------------------------------------------------------------------
# status and settings
# ---------------------------------------------------------------------------

function Show-Status {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    $cfg = Read-Config

    $state = if ($svc) { $svc.Status.ToString() } else { "not installed" }
    $start = if ($svc) { $svc.StartType.ToString() } else { "-" }
    $region = if ($cfg.EgressRegion) { $cfg.EgressRegion } else { "auto (best server)" }

    $socksPort = [int]$cfg.LocalSocksProxyPort
    $socksOn = (-not $cfg.DisableLocalSocksProxy) -and ($socksPort -gt 0)

    $httpPort = [int]$cfg.LocalHttpProxyPort
    $httpOn = (-not $cfg.DisableLocalHttpProxy) -and ($httpPort -gt 0)

    $activeRegion = "unknown"
    $active = Get-Notice 'ConnectedServerRegion'
    if ($active -and $active.Line -match '"serverRegion":"([A-Z]{2})"') { $activeRegion = $Matches[1] }

    $protocol = "-"
    $tunnel = Get-Notice 'ActiveTunnel'
    if ($tunnel -and $tunnel.Line -match '"protocol":"([^"]+)"') { $protocol = $Matches[1] }

    Write-Host ""
    Write-Host "  service     : $ServiceName [$state, $start]"

    if ($socksOn) {
        $listening = if (Test-Listening $socksPort) { "(listening)" } else { "(not listening)" }
        Write-Host "  socks proxy : socks5://127.0.0.1:$socksPort $listening"
    } else {
        Write-Host "  socks proxy : disabled"
    }

    if ($httpOn) {
        Write-Host "  http proxy  : http://127.0.0.1:$httpPort"
    } else {
        Write-Host "  http proxy  : disabled"
    }

    Write-Host "  egress      : $region   (connected: $activeRegion, $protocol)"
    Write-Host ""
}

function Set-Country([string]$Code) {
    if (-not $Code) { throw "usage: psiphon set-country <iso-code|auto>" }

    $cfg = Read-Config

    if ($Code -in @("auto", "any", "none", "-")) {
        if ($cfg.PSObject.Properties.Name -contains "EgressRegion") {
            $cfg.PSObject.Properties.Remove("EgressRegion")
        }
        Save-Config $cfg
        Write-Host "Egress region: auto (best performing server)."
    }
    elseif ($Code -match '^[A-Za-z]{2}$') {
        $cfg | Add-Member -NotePropertyName EgressRegion -NotePropertyValue $Code.ToUpper() -Force
        Save-Config $cfg
        Write-Host "Egress region: $($Code.ToUpper())."
    }
    else {
        throw "invalid country code '$Code' (two letter ISO code, or 'auto')"
    }

    Write-Host "The service reloads the tunnel within a few seconds."
}

function Set-SocksPort([string]$PortText) {
    if (-not $PortText) {
        (Read-Config).LocalSocksProxyPort
        return
    }

    $port = 0
    if (-not [int]::TryParse($PortText, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "invalid port '$PortText'"
    }

    $cfg = Read-Config
    $cfg | Add-Member -NotePropertyName LocalSocksProxyPort -NotePropertyValue $port -Force
    $cfg | Add-Member -NotePropertyName DisableLocalSocksProxy -NotePropertyValue $false -Force
    Save-Config $cfg

    Write-Host "SOCKS5 port: $port. The service reloads the tunnel within a few seconds."
}

function Set-HttpProxy([string]$Arg) {
    $cfg = Read-Config

    if (-not $Arg -or $Arg -eq "status") {
        if ($cfg.DisableLocalHttpProxy -or [int]$cfg.LocalHttpProxyPort -eq 0) {
            Write-Host "disabled"
        } else {
            Write-Host $cfg.LocalHttpProxyPort
        }
        return
    }

    if ($Arg -in @("off", "disable", "0")) {
        $cfg | Add-Member -NotePropertyName DisableLocalHttpProxy -NotePropertyValue $true -Force
        $cfg | Add-Member -NotePropertyName LocalHttpProxyPort -NotePropertyValue 0 -Force
        Save-Config $cfg
        Write-Host "HTTP proxy disabled."
        return
    }

    $port = 0
    if (-not [int]::TryParse($Arg, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "invalid port '$Arg'"
    }

    $cfg | Add-Member -NotePropertyName DisableLocalHttpProxy -NotePropertyValue $false -Force
    $cfg | Add-Member -NotePropertyName LocalHttpProxyPort -NotePropertyValue $port -Force
    Save-Config $cfg

    Write-Host "HTTP proxy enabled on port $port."
}

function Show-Regions {
    $line = Get-Notice 'AvailableEgressRegions'
    if (-not $line) {
        Write-Host "No region list in the log yet. Start the service and try again."
        return
    }

    if ($line.Line -match '"regions":\[([^\]]*)\]') {
        $regions = $Matches[1] -replace '"', '' -split ',' | Where-Object { $_ }
        Write-Host ("Available egress regions (" + $regions.Count + "):")
        Write-Host ("  " + ($regions -join "  "))
    }
}

function Show-Help {
    Write-Host "psiphon <command>"
    Write-Host ""
    Write-Host "  status                service, listeners and current egress"
    Write-Host "  set-country <code>    force an egress country, or 'auto'"
    Write-Host "  regions               regions offered by the network"
    Write-Host "  socks [port]          show or change the SOCKS5 port"
    Write-Host "  http [port|off]       enable or disable the HTTP proxy"
    Write-Host "  test [quick|MB]       exit IP, latency, download and upload"
    Write-Host "  ping [count]          exit IP and latency only"
    Write-Host "  speed [quick|MB]      download and upload only"
    Write-Host "  start | stop | restart"
    Write-Host "  logs [lines]          tail the tunnel log"
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot "speedtest.ps1")

switch ($Command.ToLower()) {
    "status"      { Show-Status }
    "set-country" { Set-Country $Value }
    "country"     { Set-Country $Value }
    "regions"     { Show-Regions }
    "socks"       { Set-SocksPort $Value }
    "port"        { Set-SocksPort $Value }
    "http"        { Set-HttpProxy $Value }
    "test"        { Invoke-SpeedTest -Mode $Value }
    "speed"       { Invoke-SpeedTest -Mode $Value -SpeedOnly }
    "ping" {
        Assert-TunnelReady

        $count = if ($Value -match '^\d+$') { [int]$Value } else { 5 }
        $ip = Get-IpInfo
        Write-Header -Ip $ip -Tunnel (Get-TunnelInfo)

        $result = Measure-Ping -Count $count
        Write-Summary -Ping $result -Down $null -Up $null
        Save-Result -Ip $ip -Ping $result -Down $null -Up $null
    }
    "start"       { Control-Service "start" }
    "stop"        { Control-Service "stop" }
    "restart"     { Control-Service "restart" }
    "logs" {
        $count = if ($Value) { [int]$Value } else { 25 }
        if (Test-Path $TunnelLog) { Get-Content $TunnelLog -Tail $count } else { Write-Host "no log yet" }
    }
    "help"        { Show-Help }
    default       { Show-Help }
}
