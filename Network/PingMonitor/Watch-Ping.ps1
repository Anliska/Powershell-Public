#requires -Version 5.1
<#
.SYNOPSIS
    Pings addresses from targets.csv concurrently and logs failed cycles.
.EXAMPLE
    .\Watch-Ping.ps1
.EXAMPLE
    .\Watch-Ping.ps1 -LogPath C:\Logs\ping.csv -IntervalSeconds 2
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot 'targets.csv'),
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 1,
    [ValidateRange(1, 60000)]
    [int]$TimeoutMilliseconds = 1000,
    [string]$LogPath = (Join-Path $PSScriptRoot 'ping.csv'),
    [switch]$NoLog,
    [switch]$PlainOutput
)

$ErrorActionPreference = 'Stop'
$targets = @(Import-Csv -LiteralPath $ConfigPath -Delimiter ';' -Encoding UTF8)
if ($targets.Count -eq 0) { throw "No targets in config: $ConfigPath" }
$labels = @()
$addresses = @()
$sources = @()
$interfaces = @()
foreach ($target in $targets) {
    $name = ([string]$target.name).Trim()
    if ($name -notmatch '^[A-Za-z0-9_-]+$' -or $labels -contains $name) {
        throw 'Target names must be unique and contain only letters, digits, underscores or hyphens.'
    }
    $address = $null
    if (-not [System.Net.IPAddress]::TryParse(([string]$target.address).Trim(), [ref]$address)) {
        throw "Invalid IP address for target '$name': $($target.address)"
    }
    $selection = ([string]$target.source).Trim()
    $source = $null
    $interfaceLabel = 'unavailable'
    if ($selection) {
        if ($env:OS -ne 'Windows_NT') { throw 'Source selection requires Windows.' }
        if ($address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Target '$name': source selection currently supports IPv4 only."
        }
        $localIp = $null
        if (-not [System.Net.IPAddress]::TryParse($selection, [ref]$localIp) -or $localIp.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Target '$name': source must be a local IPv4 address, not a gateway or adapter name."
        }
        $candidates = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -eq $localIp.ToString() -and $_.AddressState -eq 'Preferred' })
        if ($candidates.Count -ne 1) {
            throw "Target '$name': '$selection' must identify exactly one active local IPv4 address."
        }
        $adapter = Get-NetAdapter | Where-Object { $_.ifIndex -eq $candidates[0].InterfaceIndex }
        if ($adapter.Status -ne 'Up') { throw "Target '$name': adapter is not Up." }
        $ipInterface = Get-NetIPInterface -InterfaceIndex $candidates[0].InterfaceIndex -AddressFamily IPv4
        if ($ipInterface.WeakHostSend -ne 'Disabled' -or @(Get-NetIPInterface -AddressFamily IPv4 | Where-Object { $_.WeakHostSend -ne 'Disabled' }).Count -gt 0) {
            throw "Target '$name': WeakHostSend must be Disabled to restrict sending to the source adapter."
        }
        $source = [System.Net.IPAddress]::Parse($candidates[0].IPAddress)
        $interfaceLabel = "$($candidates[0].InterfaceAlias) [$source]"
    }
    $sources += $source
    $interfaces += $interfaceLabel
    $labels += $name
    $addresses += $address
}
if ($env:OS -ne 'Windows_NT' -and -not (Get-Command ping -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Linux/macOS requires the system ping utility. Install it before running this script.'
}
if (@($sources | Where-Object { $null -ne $_ }).Count -gt 0 -and -not ('NetworkMonitor.SourcePing' -as [type])) {
    Add-Type -Path (Join-Path $PSScriptRoot 'SourcePing.cs')
}
if (-not $NoLog) {
    $LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
    $directory = Split-Path -Parent $LogPath
    [System.IO.Directory]::CreateDirectory($directory) | Out-Null
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $header = 'date/time;' + ($labels -join ';')
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 0) {
        if ((Get-Content -LiteralPath $LogPath -TotalCount 1) -ne $header) {
            Write-Host "A naplo fejlece elter a jelenlegi konfiguraciotol: $LogPath" -ForegroundColor Yellow
            Write-Host 'A feluliras torli a fajl teljes korabbi tartalmat.' -ForegroundColor Yellow
            $answer = Read-Host 'Felulirod a naplot? [i/igen = igen; Enter = nem]'
            if ($null -eq $answer -or $answer.Trim() -notmatch '^(i|igen|y|yes)$') {
                Write-Host 'Inditas megszakitva. A naplo valtozatlan maradt.'
                return
            }
            [System.IO.File]::WriteAllText($LogPath, $header + [Environment]::NewLine, $encoding)
        }
    } else {
        [System.IO.File]::WriteAllText($LogPath, $header + [Environment]::NewLine, $encoding)
    }
}

$failures = @(foreach ($target in $targets) { 0 })
$cycles = 0
$failureCycles = 0
$history = New-Object 'System.Collections.Generic.Queue[string]'
$sessionStarted = Get-Date
$dashboard = -not $PlainOutput -and -not [Console]::IsOutputRedirected

function Update-AutomaticInterfaces {
    for ($i = 0; $i -lt $addresses.Count; $i++) {
        if ($null -ne $sources[$i]) { continue }
        $interfaces[$i] = 'unavailable'
        if ($env:OS -ne 'Windows_NT') { continue }
        try {
            # Find-NetRoute returns both the selected local address and the route.
            $selected = @(Find-NetRoute -RemoteIPAddress $addresses[$i].ToString() -ErrorAction Stop |
                Where-Object { $_.PSObject.Properties['IPAddress'] -and $_.IPAddress })
            if ($selected.Count -eq 1 -and $selected[0].InterfaceAlias) {
                $interfaces[$i] = "$($selected[0].InterfaceAlias) [$($selected[0].IPAddress)]"
            }
        } catch {
            # Never retain an old interface when route lookup fails.
            $interfaces[$i] = 'unavailable'
        }
    }
}

function Show-PingDashboard {
    param($Measurements, $Updated)

    Clear-Host
    Write-Host '  NETWORK MONITOR' -ForegroundColor Cyan
    Write-Host ("  Updated: {0}    Running: {1:hh\:mm\:ss}" -f $Updated.ToString('yyyy-MM-dd HH:mm:ss'), ((Get-Date) - $sessionStarted))
    Write-Host ("  Cycles: {0}    Cycles with failures: {1}" -f $cycles, $failureCycles)
    Write-Host ''
    $headers = @('Target', 'IP address', 'Status', 'RTT', 'Fail', 'Mode', 'Source')
    $rows = @(for ($i = 0; $i -lt $addresses.Count; $i++) {
        $ok = $Measurements[$i].Status -eq 'ok'
        $status = if ($ok) { 'OK' } else { 'NO REPLY' }
        $latency = if ($ok) { '{0} ms' -f $Measurements[$i].Latency } else { '-' }
        $mode = if ($null -eq $sources[$i]) { 'A' } else { 'S' }
        [pscustomobject]@{
            Values = @($labels[$i], $addresses[$i].ToString(), $status, $latency, $failures[$i].ToString(), $mode, $interfaces[$i])
            Color = if ($ok) { 'Green' } else { 'Red' }
        }
    })
    $parts = @(for ($column = 0; $column -lt $headers.Count; $column++) {
        $width = $headers[$column].Length
        foreach ($row in $rows) { $width = [Math]::Max($width, $row.Values[$column].Length) }
        # Right-align measurements and counters; leave the final column unpadded.
        $alignment = if ($column -eq 3 -or $column -eq 4) { $width } else { -$width }
        if ($column -eq $headers.Count - 1) { '{' + $column + '}' }
        else { '{{{0},{1}}}' -f $column, $alignment }
    })
    $format = '  ' + ($parts -join '  ')
    $heading = $format -f $headers
    $tableWidth = $heading.Length
    foreach ($row in $rows) { $tableWidth = [Math]::Max($tableWidth, ($format -f $row.Values).Length) }
    Write-Host $heading -ForegroundColor Cyan
    Write-Host ('  ' + ('-' * ($tableWidth - 2)))
    foreach ($row in $rows) {
        Write-Host ($format -f $row.Values) -ForegroundColor $row.Color
    }
    Write-Host ''
    Write-Host '  A = automatic route | S = configured source' -ForegroundColor DarkGray
    Write-Host '  Last failures (this session):' -ForegroundColor Yellow
    if ($history.Count -eq 0) {
        Write-Host '  No failures so far.' -ForegroundColor Green
    } else {
        foreach ($entry in $history) { Write-Host "  $entry" -ForegroundColor Yellow }
    }
    Write-Host ''
    if ($NoLog) { Write-Host "  Logging: disabled" } else { Write-Host "  CSV: $LogPath" }
    Write-Host "  Interval: $IntervalSeconds s | Timeout: $TimeoutMilliseconds ms | Stop: Ctrl+C" -ForegroundColor DarkGray
}

if (-not $dashboard) {
    Write-Host "Targets: $($addresses -join ', ')"
    if ($NoLog) { Write-Host "Logging: disabled (stop with Ctrl+C)" } else { Write-Host "Failure log: $LogPath (stop with Ctrl+C)" }
}

while ($true) {
    $started = Get-Date
    Update-AutomaticInterfaces
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $pings = @()
    $tasks = @()
    try {
        # Start all requests before waiting for any of their replies.
        for ($i = 0; $i -lt $addresses.Count; $i++) {
            if ($null -ne $sources[$i]) {
                $tasks += [NetworkMonitor.SourcePing]::SendAsync($sources[$i], $addresses[$i], $TimeoutMilliseconds)
            } else {
                $ping = New-Object System.Net.NetworkInformation.Ping
                $pings += $ping
                try {
                    $tasks += $ping.SendPingAsync($addresses[$i], $TimeoutMilliseconds)
                } catch {
                    $tasks += $null
                    Write-Warning "Ping could not start for '$($labels[$i])': $($_.Exception.Message)"
                }
            }
        }

        $measurements = @(foreach ($task in $tasks) {
            try {
                if ($null -eq $task) {
                    [pscustomobject]@{ Status = 'no'; Latency = $null }
                } else {
                    $reply = $task.GetAwaiter().GetResult()
                    if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                        [pscustomobject]@{ Status = 'ok'; Latency = $reply.RoundtripTime }
                    } else {
                        [pscustomobject]@{ Status = 'no'; Latency = $null }
                    }
                }
            } catch {
                Write-Warning ('Ping error: ' + $_.Exception.Message)
                [pscustomobject]@{ Status = 'no'; Latency = $null }
            }
        })
        $results = @($measurements | ForEach-Object { $_.Status })
        $cycles++
        for ($i = 0; $i -lt $addresses.Count; $i++) {
            if ($results[$i] -eq 'no') { $failures[$i]++ }
        }

        if ($results -contains 'no') {
            $line = $started.ToString('yyyy-MM-dd HH:mm:ss.fff zzz') + ';' + ($results -join ';')
            if (-not $NoLog) {
                [System.IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine, $encoding)
            }
            $failureCycles++
            $history.Enqueue($line)
            if ($history.Count -gt 5) { $history.Dequeue() | Out-Null }
            if (-not $dashboard) { Write-Host $line }
        }
        if ($dashboard) { Show-PingDashboard -Measurements $measurements -Updated $started }
    } finally {
        foreach ($ping in $pings) {
            $ping.Dispose()
        }
    }

    # Keep cycle starts approximately IntervalSeconds apart; never overlap cycles.
    $remaining = ($IntervalSeconds * 1000) - $clock.ElapsedMilliseconds
    if ($remaining -gt 0) {
        Start-Sleep -Milliseconds ([int]$remaining)
    }
}
