# Record one isolated USBPcap capture. Must run in an ELEVATED PowerShell.
#   .\scripts\capture_usb.ps1 -Name 03_liveview -Seconds 20 [-Hub \.\USBPcap1]
# Captures every device on the root hub (-A) with descriptors injected, then
# stops after -Seconds. Output: captures\tether\<Name>.pcap
param(
    [Parameter(Mandatory)][string]$Name,
    [int]$Seconds = 20,
    [string]$Hub = "\.\USBPcap1"
)
$ErrorActionPreference = "Stop"
$exe = "C:\Program Files\USBPcap\USBPcapCMD.exe"
$out = Join-Path $PSScriptRoot "..\captures\tether\$Name.pcap"
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
$p = Start-Process -FilePath $exe -ArgumentList @("-d", $Hub, "-o", "`"$out`"", "-A", "--inject-descriptors") -PassThru -WindowStyle Hidden
Write-Host "capturing $Hub -> $out for $Seconds s ... perform the action now"
for ($i = $Seconds; $i -gt 0; $i--) { Write-Host -NoNewline "$i "; Start-Sleep 1 }
Stop-Process -Id $p.Id -Force
Write-Host "`ndone: $((Get-Item $out).Length) bytes"
