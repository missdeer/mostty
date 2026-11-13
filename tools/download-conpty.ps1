#Requires -Version 5.1
<#
.SYNOPSIS
Download the latest stable Microsoft ConPTY x64 pair from official NuGet.
.EXAMPLE
.\download-conpty.ps1
.EXAMPLE
.\download-conpty.ps1 -Destination 'C:\Apps\Mostty\conpty'
.EXAMPLE
.\download-conpty.ps1 -Version '1.25.261109001'
#>
[CmdletBinding()]
param(
    [string]$Destination = (Join-Path (Get-Location).Path 'conpty'),
    [string]$Version = ''
)

$ErrorActionPreference = 'Stop'
if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'Run this script on Windows; Microsoft Authenticode validation is required.'
}

function Invoke-WithRetry([scriptblock]$Operation) {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try { return (& $Operation) }
        catch {
            if ($attempt -eq 3) { throw }
            Write-Warning ("Download attempt {0} failed: {1}" -f $attempt, $_.Exception.Message)
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

$Destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Destination)
if ($Destination -eq [IO.Path]::GetPathRoot($Destination)) {
    throw 'Destination must be a dedicated directory, such as C:\Apps\Mostty\conpty.'
}
$Destination = $Destination.TrimEnd([char[]]@([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
if ((Test-Path -LiteralPath $Destination) -and -not (Test-Path -LiteralPath $Destination -PathType Container)) {
    throw "Destination is not a directory: $Destination"
}
$parent = Split-Path -Parent $Destination
$null = New-Item -ItemType Directory -Force -Path $parent
$work = Join-Path $parent ('.conpty-download-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $work
$ready = Join-Path $work 'ready'
$backup = Join-Path $work 'previous'
$oldTls = [Net.ServicePointManager]::SecurityProtocol

try {
    # Windows PowerShell 5.1 may otherwise negotiate an obsolete TLS version.
    [Net.ServicePointManager]::SecurityProtocol = $oldTls -bor [Net.SecurityProtocolType]::Tls12
    $base = 'https://api.nuget.org/v3-flatcontainer/microsoft.windows.console.conpty'
    if (-not $Version) {
        $index = Invoke-WithRetry { Invoke-RestMethod -Uri "$base/index.json" -TimeoutSec 60 }
        $stable = @($index.versions | Where-Object { $_ -match '^\d+\.\d+\.\d+(?:\.\d+)?$' } |
            Sort-Object { [version]$_ })
        if ($stable.Count -eq 0) { throw 'Official NuGet index contains no stable ConPTY version.' }
        $Version = $stable[-1]
    }
    if ($Version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        throw 'Specify a stable numeric NuGet version; prereleases are not selected.'
    }
    $url = "$base/$Version/microsoft.windows.console.conpty.$Version.nupkg"
    $archive = Join-Path $work 'conpty.nupkg'
    Write-Host "Downloading Microsoft ConPTY $Version (x64) from $url"
    Invoke-WithRetry { Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing -TimeoutSec 120 | Out-Null }

    # Preserve other files in an existing installation; validate the new pair
    # before replacing the destination directory.
    if (Test-Path -LiteralPath $Destination) {
        Copy-Item -LiteralPath $Destination -Destination $ready -Recurse -Force
    } else {
        $null = New-Item -ItemType Directory -Path $ready
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($archive)
    $files = [ordered]@{
        'conpty.dll' = 'runtimes/win-x64/native/conpty.dll'
        'OpenConsole.exe' = 'build/native/runtimes/x64/OpenConsole.exe'
    }
    try {
        foreach ($name in $files.Keys) {
            $entry = $zip.GetEntry($files[$name])
            if ($null -eq $entry) { throw "Official package is missing $($files[$name])" }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $ready $name), $true)
        }
    } finally { $zip.Dispose() }

    $hashes = [ordered]@{}
    foreach ($name in $files.Keys) {
        $path = Join-Path $ready $name
        $signature = Get-AuthenticodeSignature -FilePath $path
        if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
            $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw "Invalid Microsoft signature on ${name}: $($signature.Status). Existing installation was not replaced."
        }
        $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
    [ordered]@{
        version = $Version
        source = $url
        package_sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        files = $hashes
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $ready 'manifest.json') -Encoding UTF8

    if (Test-Path -LiteralPath $Destination) {
        Move-Item -LiteralPath $Destination -Destination $backup
    }
    try { Move-Item -LiteralPath $ready -Destination $Destination }
    catch {
        if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $Destination }
        throw
    }
    if (Test-Path -LiteralPath $backup) {
        try { Remove-Item -LiteralPath $backup -Recurse -Force }
        catch { Write-Warning "Installed successfully; close programs using the old files and remove backup: $backup" }
    }
    Write-Host "Installed Microsoft ConPTY $Version in $Destination"
    Write-Host 'Open a new Mostty terminal to use the new ConPTY. Existing terminals retain their current version.'
} finally {
    [Net.ServicePointManager]::SecurityProtocol = $oldTls
    # Never discard a backup if replacement or rollback could not finish.
    if (Test-Path -LiteralPath $backup) {
        Write-Warning "Previous installation preserved at $backup"
    } else {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
