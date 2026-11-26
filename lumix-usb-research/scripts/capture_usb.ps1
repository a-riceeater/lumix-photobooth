# Record one isolated USBPcap capture of the LUMIX camera only. Must run ELEVATED.
#   .\scripts\capture_usb.ps1 -Name 01_connect -Seconds 30
# Only the camera's USB device is captured (--devices N, auto-detected by the
# name "DC-S5M2"), so keyboard/mouse/audio traffic on the same root hub is NOT
# recorded. Descriptors are injected at the start. Output: captures\tether\<Name>.pcap
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Seconds = 20,
    [string]$Hub = "\\.\USBPcap1",
    [string]$DeviceName = "DC-S5M2"
)
$ErrorActionPreference = "Stop"
$exe = "C:\Program Files\USBPcap\USBPcapCMD.exe"
$cfg = & $exe --extcap-interface $Hub --extcap-config 2>&1 | Out-String
$m = [regex]::Match($cfg, "\{value=(\d+)\}\{display=\[\d+\] $([regex]::Escape($DeviceName))\}")
if (-not $m.Success) { throw "camera '$DeviceName' not found on $Hub" }
$dev = $m.Groups[1].Value
$out = Join-Path $PSScriptRoot "..\captures\tether\$Name.pcap"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
if (Test-Path $out) { throw "$out already exists; choose another -Name" }
$p = Start-Process -FilePath $exe -PassThru -WindowStyle Hidden -ArgumentList @(
    "-d", $Hub, "--devices", $dev, "--inject-descriptors", "-o", "`"$out`"")
# NOTE: default snaplen (65535) truncates large bulk URBs; analyze_pcap.py zero-pads
# them. "-s 16777216 -b 67108864" captured NO bulk traffic at all (only interrupt
# packets) in 01_tether_connect_idle (attempt 1) - do not use.
Write-Host "capturing $DeviceName (device $dev on $Hub) -> $out for $Seconds s"
Write-Host ">>> perform the action now"
for ($i = $Seconds; $i -gt 0; $i--) { Write-Host -NoNewline "$i "; Start-Sleep 1 }
Stop-Process -Id $p.Id -Force
Start-Sleep -Milliseconds 300
Write-Host "`ndone: $((Get-Item $out).Length) bytes -> $out"
