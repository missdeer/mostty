<#
.SYNOPSIS
Send a JSON control request to a running Mostty instance. Returns the response as a PowerShell object.
.EXAMPLE
& ./share/mostty/Invoke-Mostty.ps1 -Request @{ action = 'new_tab'; directory = 'C:\work' }
#>
param(
    [Parameter(Mandatory)][hashtable]$Request,
    [int]$TargetProcess,
    [string]$Executable
)
$ErrorActionPreference = 'Stop'
if (!$Executable) {
    $prefix = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $Executable = Join-Path $prefix 'Mostty.exe'
    if (!(Test-Path -LiteralPath $Executable)) { $Executable = Join-Path $prefix 'bin/Mostty.exe' }
}
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $Executable
$start.Arguments = '+control'
if ($TargetProcess) { $start.Arguments += " --target-process $TargetProcess" }
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.WindowStyle = 'Hidden'
$start.RedirectStandardInput = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
$start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
$start.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
$process = [Diagnostics.Process]::Start($start)
try {
    $requestBytes = [Text.UTF8Encoding]::new($false).GetBytes(($Request | ConvertTo-Json -Compress -Depth 8))
    $inputStream = $process.StandardInput.BaseStream
    $inputStream.Write($requestBytes, 0, $requestBytes.Length)
    $inputStream.Close()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $output = $stdout.GetAwaiter().GetResult()
    $errors = $stderr.GetAwaiter().GetResult()
    if (!$output.Trim()) { throw "Mostty control failed ($($process.ExitCode)): $errors" }
    $response = $output | ConvertFrom-Json
    if ($process.ExitCode -ne 0 -or !$response.ok) { throw "Mostty control: $($response.error) $errors" }
    return $response
} finally {
    $process.Dispose()
}
