#Requires -RunAsAdministrator

param(
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("enable", "disable", "status", "help")]
    [string]$Action,

    [switch]$GpUpdate,

    [switch]$RestartTermService
)

$ErrorActionPreference = "Stop"

$policyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
$values = @(
    "AVCHardwareEncodePreferred",
    "AVC444ModePreferred"
)
$changesPolicy = $Action -eq "enable" -or $Action -eq "disable"

function Show-Help {
    Write-Host @"
Usage:
  .\tools\rdp-h264-policy.ps1 help
  .\tools\rdp-h264-policy.ps1 status
  .\tools\rdp-h264-policy.ps1 enable  [-GpUpdate] [-RestartTermService]
  .\tools\rdp-h264-policy.ps1 disable [-GpUpdate] [-RestartTermService]

Actions:
  help      Show this help.
  status    Show current local policy values.
  enable    Enable RDP H.264 hardware encoding and AVC 444 preference.
  disable   Disable RDP H.264 hardware encoding and AVC 444 preference.

Options:
  -GpUpdate             Run gpupdate /target:computer /force after changing policy.
  -RestartTermService   Restart TermService after changing policy. This disconnects active RDP sessions.

Policy path:
  HKLM\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services
  AVCHardwareEncodePreferred
  AVC444ModePreferred
"@
}

function Get-PolicyState {
    param([string]$Name)

    $item = Get-ItemProperty -Path $policyPath -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return "not configured"
    }

    $value = $item.$Name
    if ($value -eq 1) {
        return "enabled"
    }
    if ($value -eq 0) {
        return "disabled"
    }
    return "custom ($value)"
}

switch ($Action) {
    "help" {
        Show-Help
    }
    "enable" {
        New-Item -Path $policyPath -Force | Out-Null
        foreach ($name in $values) {
            New-ItemProperty -Path $policyPath -Name $name -PropertyType DWord -Value 1 -Force | Out-Null
        }
        Write-Host "Enabled RDP H.264 hardware encoding and AVC 444 preference."
    }
    "disable" {
        New-Item -Path $policyPath -Force | Out-Null
        foreach ($name in $values) {
            New-ItemProperty -Path $policyPath -Name $name -PropertyType DWord -Value 0 -Force | Out-Null
        }
        Write-Host "Disabled RDP H.264 hardware encoding and AVC 444 preference."
    }
    "status" {
        foreach ($name in $values) {
            Write-Host "$name = $(Get-PolicyState -Name $name)"
        }
    }
}

if ($GpUpdate -and $changesPolicy) {
    gpupdate /target:computer /force
    Write-Host "Policy refreshed."
}

if ($RestartTermService -and $changesPolicy) {
    Write-Warning "Restarting TermService will disconnect active Remote Desktop sessions."
    Restart-Service TermService -Force
    Write-Host "TermService restarted."
}

if ($changesPolicy) {
    if (-not $GpUpdate) {
        Write-Host "Run 'gpupdate /target:computer /force' to refresh computer policy."
    }
    if (-not $RestartTermService) {
        Write-Host "Log off the RDP session and reconnect, or rerun with -RestartTermService to reinitialize Remote Desktop Services."
    }
}
