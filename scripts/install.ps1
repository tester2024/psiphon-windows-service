#Requires -Version 5.1
<#
  Installs the Psiphon tunnel as an auto-starting Windows service.

  Usage (from an extracted release):
      powershell -ExecutionPolicy Bypass -File scripts\install.ps1

  The script asks for elevation itself, creates config\psiphon.config and
  config\service.json for the current install path, registers the service and
  adds the cli folder to the user PATH.
#>

[CmdletBinding()]
param(
    [string]$InstallDir = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = "Stop"
$serviceName = "PsiphonTunnelCore"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $argList = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass",
        "-File", "`"$PSCommandPath`"",
        "-InstallDir", "`"$InstallDir`""
    )
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -PassThru -Wait
    exit $proc.ExitCode
}

$InstallDir = (Resolve-Path $InstallDir).Path
$binDir = Join-Path $InstallDir "bin"
$configDir = Join-Path $InstallDir "config"
$dataDir = Join-Path $InstallDir "data"
$logDir = Join-Path $InstallDir "logs"
$cliDir = Join-Path $InstallDir "cli"

$required = @(
    (Join-Path $binDir "psiphon-tunnel-core.exe"),
    (Join-Path $binDir "psiphon-service.exe"),
    (Join-Path $cliDir "psiphon.ps1"),
    (Join-Path $cliDir "speedtest.ps1"),
    (Join-Path $configDir "psiphon.config.template.json")
)
foreach ($file in $required) {
    if (-not (Test-Path $file)) { throw "missing file: $file" }
}

Write-Host "Installing into $InstallDir"
New-Item -ItemType Directory -Force -Path $dataDir, $logDir | Out-Null

# tunnel config: same public bootstrap values, paths for this machine
$config = Get-Content (Join-Path $configDir "psiphon.config.template.json") -Raw | ConvertFrom-Json
$config.DataRootDirectory = $dataDir
$configPath = Join-Path $configDir "psiphon.config"
[IO.File]::WriteAllText(
    $configPath,
    ($config | ConvertTo-Json -Depth 10),
    (New-Object System.Text.UTF8Encoding($false))
)

# service host settings
$serviceSettings = [ordered]@{
    app    = Join-Path $binDir "psiphon-tunnel-core.exe"
    args   = @("-config", $configPath, "-formatNotices")
    logDir = $logDir
    watch  = @($configPath)
}
[IO.File]::WriteAllText(
    (Join-Path $configDir "service.json"),
    ($serviceSettings | ConvertTo-Json -Depth 5),
    (New-Object System.Text.UTF8Encoding($false))
)

# replace an existing install
$existing = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($existing) {
    Write-Host "Removing the existing $serviceName service"
    if ($existing.Status -ne "Stopped") { Stop-Service -Name $serviceName -Force }
    sc.exe delete $serviceName | Out-Null
    for ($i = 0; $i -lt 10; $i++) {
        Start-Sleep -Milliseconds 500
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) { break }
    }
}

$binaryPath = '"{0}" "{1}"' -f (Join-Path $binDir "psiphon-service.exe"), (Join-Path $configDir "service.json")
New-Service `
    -Name $serviceName `
    -BinaryPathName $binaryPath `
    -DisplayName "Psiphon Tunnel Core" `
    -Description "SOCKS5 proxy on 127.0.0.1:9999, powered by psiphon-tunnel-core" `
    -StartupType Automatic | Out-Null

sc.exe failure $serviceName reset= 86400 actions= restart/5000/restart/10000/restart/30000 | Out-Null
Start-Service -Name $serviceName

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$cliDir*") {
    [Environment]::SetEnvironmentVariable("Path", ($userPath.TrimEnd(';') + ";" + $cliDir), "User")
}

Start-Sleep -Seconds 5
Get-Service -Name $serviceName | Format-Table Name, Status, StartType -AutoSize

Write-Host ""
Write-Host "Done. Open a new terminal and try:"
Write-Host "  psiphon status"
Write-Host "  psiphon test"
Write-Host ""
Write-Host "The proxy listens on socks5://127.0.0.1:9999 after the first tunnel is up,"
Write-Host "usually 20-60 seconds. Until then proxy requests will fail."
