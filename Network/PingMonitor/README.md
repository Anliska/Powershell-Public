# Ping Monitor

Checks multiple IP addresses concurrently.
Displays a colored dashboard and logs failed cycles.

## Requirements

Windows PowerShell 5.1 or PowerShell 7 on Windows.
Keep Watch-Ping.ps1 and SourcePing.cs in the same folder.

## Setup

Run from this folder:

    Copy-Item .\targets.example.csv .\targets.csv

Edit targets.csv:
- name: unique name using letters, digits, underscores or hyphens.
- address: target IP address.
- source: optional local IPv4 address from ipconfig.
  Leave source blank for automatic routing.

A configured source requires an active local adapter and IPv4.
IPv4 WeakHostSend must be disabled when selecting a source.
The script does not change routes or gateways.

## Run

    .\Watch-Ping.ps1
    .\Watch-Ping.ps1 -NoLog
    .\Watch-Ping.ps1 -IntervalSeconds 2 -TimeoutMilliseconds 1000 -LogPath .\logs\ping.csv

Stop with Ctrl+C.
A = automatic routing. S = configured source.
Automatic adapter display is a routing snapshot, not packet capture.

## Logs

Semicolon-delimited CSV with one column per target.
Only cycles with failed replies are logged.
A different log header prompts before overwriting.
Declining preserves the file and stops the monitor.

Local targets.csv and CSV logs are excluded from Git.
Do not commit credentials, local configurations or logs.

## Validation

Configuration, logging and display tested with simulated replies.
The native helper compiled.
Live Windows source selection requires local testing.
