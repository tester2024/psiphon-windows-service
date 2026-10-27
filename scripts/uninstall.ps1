#Requires -Version 5.1
<#
  Removes the Psiphon service and its PATH entry.

  Data, logs and configuration are left in place so a reinstall keeps them.
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
$cliDir = Join-Path $InstallDir "cli"

$service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($service) {
    if ($service.Status -ne "Stopped") { Stop-Service -Name $serviceName -Force }
    sc.exe delete $serviceName | Out-Null
    Write-Host "Service removed."
} else {
    Write-Host "Service is not installed."
}

$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -like "*$cliDir*") {
    $parts = $userPath -split ';' | Where-Object { $_ -and $_ -ne $cliDir }
    [Environment]::SetEnvironmentVariable("Path", ($parts -join ';'), "User")
    Write-Host "Removed $cliDir from the user PATH."
}

Write-Host "Config, data and logs were kept in $InstallDir."
Write-Host "Delete the folder if you want them gone."
