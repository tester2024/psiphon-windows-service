# Speed measurements for psiphon.ps1. Dot-sourced, not run on its own.
#
# Everything here goes through the local SOCKS5 listener: latency is a raw
# SOCKS CONNECT, downloads are streamed with curl, uploads use a small TLS
# client so the byte counter is ours.

function Get-SocksPort {
    [int](Read-Config).LocalSocksProxyPort
}

function Get-QualityColor([double]$Value, [double]$Good, [double]$Okay, [switch]$LowerIsBetter) {
    if ($LowerIsBetter) {
        if ($Value -le $Good) { return "Green" }
        if ($Value -le $Okay) { return "Yellow" }
        return "Red"
    }

    if ($Value -ge $Good) { return "Green" }
    if ($Value -ge $Okay) { return "Yellow" }
    return "Red"
}

function Read-Exact($Stream, [byte[]]$Buffer, [int]$Count) {
    $offset = 0

    while ($offset -lt $Count) {
        $n = $Stream.Read($Buffer, $offset, $Count - $offset)
        if ($n -le 0) { throw "connection closed" }
        $offset += $n
    }
}

function Get-IpInfo {
    $old = $ErrorActionPreference
    $ErrorActionPreference = "Continue"

    $json = & curl.exe -s --max-time 15 -x "socks5h://127.0.0.1:$script:SocksPort" "https://ipinfo.io/json"
    if ($LASTEXITCODE -eq 0 -and $json) {
        try {
            $o = ($json | Out-String) | ConvertFrom-Json
            if ($o.ip) {
                $ErrorActionPreference = $old
                return [pscustomobject]@{ IP = $o.ip; Country = $o.country; City = $o.city; Org = $o.org }
            }
        }
        catch { }
    }

    $ip = & curl.exe -s --max-time 15 -x "socks5h://127.0.0.1:$script:SocksPort" "https://api.ipify.org"
    $ErrorActionPreference = $old

    if ($LASTEXITCODE -eq 0 -and $ip) {
        return [pscustomobject]@{ IP = ($ip | Out-String).Trim(); Country = ""; City = ""; Org = "" }
    }

    return $null
}

function Measure-Ping([int]$Count = 5) {
    $samples = New-Object System.Collections.Generic.List[double]

    # One CONNECT per sample. The reply arrives after roughly one round trip,
    # which is the number we care about.
    for ($i = 0; $i -le $Count; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $client = New-Object Net.Sockets.TcpClient

        try {
            $client.NoDelay = $true
            $client.ReceiveTimeout = 15000
            $client.Connect("127.0.0.1", $script:SocksPort)
            $stream = $client.GetStream()

            $greeting = [byte[]](5, 1, 0)
            $stream.Write($greeting, 0, $greeting.Length)

            $method = New-Object byte[] 2
            Read-Exact $stream $method 2
            if ($method[0] -ne 5 -or $method[1] -ne 0) { throw "SOCKS5 negotiation failed" }

            $request = [byte[]](5, 1, 0, 1, 1, 1, 1, 1, 1, 187) # CONNECT 1.1.1.1:443
            $stream.Write($request, 0, $request.Length)

            $head = New-Object byte[] 4
            Read-Exact $stream $head 4
            if ($head[1] -ne 0) { throw "SOCKS5 connect failed (reply $($head[1]))" }

            $rest = 0
            if ($head[3] -eq 1) { $rest = 6 }
            elseif ($head[3] -eq 4) { $rest = 18 }
            elseif ($head[3] -eq 3) {
                $length = New-Object byte[] 1
                Read-Exact $stream $length 1
                $rest = $length[0] + 2
            }

            if ($rest -gt 0) {
                $tail = New-Object byte[] $rest
                Read-Exact $stream $tail $rest
            }

            $sw.Stop()
        }
        catch {
            throw "latency test failed: $($_.Exception.Message)"
        }
        finally {
            $client.Close()
        }

        if ($i -eq 0) { continue } # the first one pays for setup

        $samples.Add($sw.Elapsed.TotalMilliseconds)
        Write-Progress -Activity "Psiphon test" `
            -Status ("latency {0}/{1}  |  {2:N0} ms" -f $i, $Count, $sw.Elapsed.TotalMilliseconds) `
            -PercentComplete ([int](($i / $Count) * 100))
    }

    Write-Progress -Activity "Psiphon test" -Completed

    $jitter = 0.0
    if ($samples.Count -gt 1) {
        $deltas = New-Object System.Collections.Generic.List[double]
        for ($k = 1; $k -lt $samples.Count; $k++) {
            $deltas.Add([Math]::Abs($samples[$k] - $samples[$k - 1]))
        }
        $jitter = ($deltas | Measure-Object -Average).Average
    }

    return [pscustomobject]@{
        Min    = ($samples | Measure-Object -Minimum).Minimum
        Avg    = ($samples | Measure-Object -Average).Average
        Max    = ($samples | Measure-Object -Maximum).Maximum
        Jitter = $jitter
        Count  = $samples.Count
    }
}

function Measure-Download([double]$MegaBytes, [int]$MaxSeconds = 30) {
    $bytes = [long]($MegaBytes * 1MB)
    $tmp = Join-Path $env:TEMP ("psiphon-dl-" + [guid]::NewGuid().ToString("N") + ".bin")

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = "curl.exe"
    $info.Arguments = '-sS -x socks5h://127.0.0.1:{0} -o "{1}" "https://speed.cloudflare.com/__down?bytes={2}"' -f `
        $script:SocksPort, $tmp, $bytes
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardError = $true

    $proc = [System.Diagnostics.Process]::Start($info)
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $size = [long]0
    $lastSize = [long]0
    $lastTime = 0.0
    $peak = 0.0

    while (-not $proc.HasExited) {
        if (Test-Path $tmp) { $size = (Get-Item $tmp).Length }

        $elapsed = $sw.Elapsed.TotalSeconds
        if (($elapsed - $lastTime) -ge 0.4) {
            $mbps = (($size - $lastSize) * 8.0) / (($elapsed - $lastTime) * 1e6)
            if ($elapsed -ge 0.6 -and $mbps -gt $peak) { $peak = $mbps }

            Write-Progress -Activity "Psiphon test" `
                -Status ("download {0:N1}/{1:N1} MB  |  {2:N2} Mbps" -f ($size / 1MB), $MegaBytes, $mbps) `
                -PercentComplete ([Math]::Min(100, [int](($size / $bytes) * 100)))

            $lastSize = $size
            $lastTime = $elapsed
        }

        if ($elapsed -ge $MaxSeconds) {
            $proc.Kill()
            break
        }

        Start-Sleep -Milliseconds 200
    }

    $sw.Stop()
    $stderr = $proc.StandardError.ReadToEnd()
    $exitCode = $proc.ExitCode

    if (Test-Path $tmp) {
        $size = (Get-Item $tmp).Length
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }

    Write-Progress -Activity "Psiphon test" -Completed
    if ($exitCode -ne 0) { throw ("download failed: " + $stderr.Trim()) }

    $seconds = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)

    return [pscustomobject]@{
        Mbps     = ($size * 8.0) / ($seconds * 1e6)
        PeakMbps = $peak
        Bytes    = $size
        Seconds  = $seconds
    }
}

function Connect-Socks([string]$TargetHost, [int]$TargetPort) {
    $client = New-Object Net.Sockets.TcpClient
    $client.NoDelay = $true
    $client.ReceiveTimeout = 20000
    $client.SendTimeout = 60000
    $client.Connect("127.0.0.1", $script:SocksPort)

    $stream = $client.GetStream()
    $greeting = [byte[]](5, 1, 0)
    $stream.Write($greeting, 0, $greeting.Length)

    $method = New-Object byte[] 2
    Read-Exact $stream $method 2
    if ($method[0] -ne 5 -or $method[1] -ne 0) {
        $client.Close()
        throw "SOCKS5 negotiation failed"
    }

    $hostBytes = [Text.Encoding]::ASCII.GetBytes($TargetHost)
    $request = New-Object byte[] (5 + $hostBytes.Length + 2)
    $request[0] = 5
    $request[1] = 1
    $request[2] = 0
    $request[3] = 3
    $request[4] = [byte]$hostBytes.Length
    [Array]::Copy($hostBytes, 0, $request, 5, $hostBytes.Length)
    $request[$request.Length - 2] = [byte][Math]::Floor($TargetPort / 256)
    $request[$request.Length - 1] = [byte]($TargetPort % 256)
    $stream.Write($request, 0, $request.Length)

    $head = New-Object byte[] 4
    Read-Exact $stream $head 4
    if ($head[1] -ne 0) {
        $client.Close()
        throw "SOCKS5 connect to ${TargetHost}:${TargetPort} failed (reply $($head[1]))"
    }

    $rest = 0
    if ($head[3] -eq 1) { $rest = 6 }
    elseif ($head[3] -eq 4) { $rest = 18 }
    elseif ($head[3] -eq 3) {
        $length = New-Object byte[] 1
        Read-Exact $stream $length 1
        $rest = $length[0] + 2
    }

    if ($rest -gt 0) {
        $tail = New-Object byte[] $rest
        Read-Exact $stream $tail $rest
    }

    return [pscustomobject]@{ Client = $client; Stream = $stream }
}

function Measure-Upload([double]$MegaBytes) {
    $bytes = [long]($MegaBytes * 1MB)
    $sw = [Diagnostics.Stopwatch]::StartNew()

    $conn = Connect-Socks "speed.cloudflare.com" 443
    $ssl = New-Object Net.Security.SslStream($conn.Stream, $false)

    try {
        $ssl.AuthenticateAsClient("speed.cloudflare.com")

        $header = "POST /__up HTTP/1.1`r`n" +
            "Host: speed.cloudflare.com`r`n" +
            "User-Agent: psiphon-cli-speedtest`r`n" +
            "Content-Type: application/octet-stream`r`n" +
            "Content-Length: $bytes`r`n" +
            "Connection: close`r`n`r`n"
        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
        $ssl.Write($headerBytes, 0, $headerBytes.Length)

        $chunk = New-Object byte[] 65536
        $sent = [long]0
        $lastSent = [long]0
        $lastTime = 0.0

        while ($sent -lt $bytes) {
            $n = [Math]::Min($chunk.Length, $bytes - $sent)
            $ssl.Write($chunk, 0, $n)
            $sent += $n

            $elapsed = $sw.Elapsed.TotalSeconds
            if (($elapsed - $lastTime) -ge 0.4) {
                $mbps = (($sent - $lastSent) * 8.0) / (($elapsed - $lastTime) * 1e6)

                Write-Progress -Activity "Psiphon test" `
                    -Status ("upload {0:N1}/{1:N1} MB  |  {2:N2} Mbps" -f ($sent / 1MB), $MegaBytes, $mbps) `
                    -PercentComplete ([Math]::Min(100, [int](($sent / $bytes) * 100)))

                $lastSent = $sent
                $lastTime = $elapsed
            }
        }

        $ssl.Flush()

        # The server response tells us the transfer is really done.
        $reply = New-Object byte[] 1024
        try { $null = $ssl.Read($reply, 0, $reply.Length) } catch { }

        $sw.Stop()
    }
    finally {
        $ssl.Dispose()
        $conn.Client.Close()
        Write-Progress -Activity "Psiphon test" -Completed
    }

    $seconds = [Math]::Max($sw.Elapsed.TotalSeconds, 0.001)

    return [pscustomobject]@{
        Mbps     = ($bytes * 8.0) / ($seconds * 1e6)
        PeakMbps = $null
        Bytes    = $bytes
        Seconds  = $seconds
    }
}

function Assert-TunnelReady {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc -or $svc.Status -ne "Running") {
        throw "the service is not running (psiphon start)"
    }

    $cfg = Read-Config
    $script:SocksPort = [int]$cfg.LocalSocksProxyPort

    if ($cfg.DisableLocalSocksProxy -or $script:SocksPort -le 0) {
        throw "the SOCKS proxy is disabled (psiphon socks 9999)"
    }

    if (-not (Test-Listening $script:SocksPort)) {
        throw "nothing is listening on 127.0.0.1:$script:SocksPort yet"
    }
}

function Get-TunnelInfo {
    $region = ""
    $protocol = ""

    $active = Get-Notice 'ConnectedServerRegion'
    if ($active -and $active.Line -match '"serverRegion":"([A-Z]{2})"') { $region = $Matches[1] }

    $tunnel = Get-Notice 'ActiveTunnel'
    if ($tunnel -and $tunnel.Line -match '"protocol":"([^"]+)"') { $protocol = $Matches[1] }

    return [pscustomobject]@{ Region = $region; Protocol = $protocol }
}

function Write-Header($Ip, $Tunnel) {
    Write-Host ""
    Write-Host "  Psiphon speed test" -ForegroundColor Cyan
    Write-Host ("  " + ("-" * 64)) -ForegroundColor White

    Write-Host "  exit IP    " -NoNewline -ForegroundColor White
    if ($Ip -and $Ip.IP) {
        Write-Host ("{0,-16}" -f $Ip.IP) -NoNewline -ForegroundColor Yellow

        $where = @($Ip.Country, $Ip.City, $Ip.Org) | Where-Object { $_ }
        if ($where.Count -gt 0) {
            Write-Host ("  " + ($where -join "  |  ")) -ForegroundColor White
        } else {
            Write-Host ""
        }
    } else {
        Write-Host "unavailable (tunnel may still be connecting)" -ForegroundColor Red
    }

    $line = @("socks5 127.0.0.1:$script:SocksPort")
    if ($Tunnel.Region) { $line += "server $($Tunnel.Region)" }
    if ($Tunnel.Protocol) { $line += $Tunnel.Protocol }

    Write-Host ("  " + ($line -join "  |  ")) -ForegroundColor White
    Write-Host ("  " + ("-" * 64)) -ForegroundColor White
}

function Write-Summary($Ping, $Down, $Up) {
    Write-Host ""
    Write-Host ("  " + ("-" * 64)) -ForegroundColor White

    if ($Ping) {
        Write-Host "  latency   " -NoNewline -ForegroundColor White
        Write-Host ("{0,5:N0} ms" -f $Ping.Avg) -NoNewline -ForegroundColor (Get-QualityColor $Ping.Avg 150 300 -LowerIsBetter)
        Write-Host (" avg   min {0:N0}  |  max {1:N0}  |  jitter {2:N0} ms  ({3} samples)" -f `
            $Ping.Min, $Ping.Max, $Ping.Jitter, $Ping.Count) -ForegroundColor White
    }

    if ($Down) {
        Write-Host "  download  " -NoNewline -ForegroundColor White
        Write-Host ("{0,5:N2} Mbps" -f $Down.Mbps) -NoNewline -ForegroundColor (Get-QualityColor $Down.Mbps 5 1)

        $peak = if ($Down.PeakMbps -gt 0) { " peak {0:N2}  |" -f $Down.PeakMbps } else { "" }
        Write-Host (" avg{0}  {1:N1} MB in {2:N1} s" -f $peak, ($Down.Bytes / 1MB), $Down.Seconds) -ForegroundColor White
    }

    if ($Up) {
        Write-Host "  upload    " -NoNewline -ForegroundColor White
        Write-Host ("{0,5:N2} Mbps" -f $Up.Mbps) -NoNewline -ForegroundColor (Get-QualityColor $Up.Mbps 5 1)
        Write-Host (" avg  |  {0:N1} MB in {1:N1} s" -f ($Up.Bytes / 1MB), $Up.Seconds) -ForegroundColor White
    }

    Write-Host ("  " + ("-" * 64)) -ForegroundColor White
    Write-Host ""
}

function Save-Result($Ip, $Ping, $Down, $Up) {
    $line = "{0} ip={1} ping_avg={2:N1} jitter={3:N1} down_mbps={4:N2} up_mbps={5:N2}" -f `
        (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK"),
        ($(if ($Ip) { $Ip.IP } else { "-" })),
        ($(if ($Ping) { $Ping.Avg } else { 0 })),
        ($(if ($Ping) { $Ping.Jitter } else { 0 })),
        ($(if ($Down) { $Down.Mbps } else { 0 })),
        ($(if ($Up) { $Up.Mbps } else { 0 }))

    Add-Content -Path $SpeedLog -Value $line -Encoding UTF8
}

function Invoke-SpeedTest([string]$Mode, [switch]$SpeedOnly) {
    Assert-TunnelReady

    $quick = $Mode -eq "quick"
    $pings = if ($quick) { 3 } else { 5 }
    $downMB = if ($quick) { 1 } else { 2 }
    $upMB = if ($quick) { 0.5 } else { 1 }

    if ($Mode -match '^(\d+)$') {
        $downMB = [int]$Matches[1]
        $upMB = [Math]::Max(1, [int]($downMB / 2))
    }

    $tunnel = Get-TunnelInfo
    $ip = Get-IpInfo
    Write-Header -Ip $ip -Tunnel $tunnel

    $ping = $null
    $down = $null
    $up = $null

    try {
        if (-not $SpeedOnly) { $ping = Measure-Ping -Count $pings }
        $down = Measure-Download -MegaBytes $downMB
        $up = Measure-Upload -MegaBytes $upMB
    }
    catch {
        Write-Progress -Activity "Psiphon test" -Completed
        Write-Host ""
        Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "  If the tunnel just reconnected, wait until 'psiphon status' shows a region." -ForegroundColor White
        Write-Host ""
        return
    }

    Write-Summary -Ping $ping -Down $down -Up $up
    Save-Result -Ip $ip -Ping $ping -Down $down -Up $up
}
