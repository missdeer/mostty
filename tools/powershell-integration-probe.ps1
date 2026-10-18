param([string]$Executable, [int]$TargetProcess, [string]$ExpectedDirectory)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$hook = Join-Path $root 'resources/mostty/shell-integration/powershell/mostty.ps1'
function global:prompt { "USER_SUCCESS=$?;NATIVE_EXIT=$global:LASTEXITCODE" }
Remove-Variable LASTEXITCODE -Scope Global -ErrorAction Ignore
. $hook
if ($global:LASTEXITCODE -ne 0) { throw 'StrictMode startup must initialize the missing native exit status' }
$global:LASTEXITCODE = 73
Write-Error 'expected failing command' -ErrorAction Ignore
$text = prompt
if ($text -notlike '*USER_SUCCESS=False;NATIVE_EXIT=73*') { throw 'The user prompt must observe the failing command and its native exit status' }
if ($global:LASTEXITCODE -ne 73) { throw 'Rendering a prompt must preserve the native command exit status' }
[Console]::Write('')
$text = prompt
if ($text -notlike '*USER_SUCCESS=True;NATIVE_EXIT=73*') { throw 'The user prompt must also observe successful commands' }
$body = $function:prompt.ToString()
. $hook
if ($function:prompt.ToString() -ne $body) { throw 'Sourcing integration again must not wrap the prompt twice' }
if ($TargetProcess) {
    $reply = & (Join-Path $root 'resources/mostty/Invoke-Mostty.ps1') -Executable $Executable -TargetProcess $TargetProcess -Request @{action='get'}
    if ($reply.terminal.directory.Replace('/','\') -ne $ExpectedDirectory.Replace('/','\')) {
        throw 'The control client must preserve Unicode directory responses on this PowerShell version'
    }
}
Write-Output 'PowerShell hook and control probes passed'
