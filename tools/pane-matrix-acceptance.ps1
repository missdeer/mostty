$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$matrixId=[Guid]::NewGuid().ToString('N')
$matrixRoot=Join-Path $root "tmp/six-backend-$matrixId"
New-Item -ItemType Directory -Path $matrixRoot | Out-Null
$exe=Join-Path $root 'zig-out/bin/Mostty.exe'
$runner=Join-Path $PSScriptRoot 'pane-acceptance.ps1'
$sourceFiles=@('pane-acceptance.ps1','pane-test-native.cs','pane-output-probe.py','pane-input-probe.py','pane-image-probe.py','pane-matrix-acceptance.ps1','pane-matrix-summary.jq','pane-matrix-summary-test.ps1')
$sourceHashes=[ordered]@{}
foreach($name in $sourceFiles){$sourceHashes[$name]=(Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot $name)).Hash}
Push-Location $root
try{
    & (Join-Path $PSScriptRoot 'pane-matrix-summary-test.ps1') *> (Join-Path $matrixRoot 'summary-tests.log')
    if(-not $?){throw 'Matrix summary contract tests failed'}
    cmd.exe /c "D:\zig-x86_64-windows-0.16.0\zig.exe build --global-cache-dir D:\zig-cache" *> (Join-Path $matrixRoot 'build.log')
    if($LASTEXITCODE -ne 0){throw 'Matrix build failed'}
    cmd.exe /c "D:\zig-x86_64-windows-0.16.0\zig.exe build test --global-cache-dir D:\zig-cache --summary all" *> (Join-Path $matrixRoot 'tests.log')
    if($LASTEXITCODE -ne 0){throw 'Matrix tests failed'}
    $exeHash=(Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash
    $metadata=[ordered]@{matrix_id=$matrixId;created_utc=[DateTime]::UtcNow.ToString('o');source_commit=(git rev-parse HEAD);zig_version=(& 'D:\zig-x86_64-windows-0.16.0\zig.exe' version);os=[Environment]::OSVersion.VersionString;executable_sha256=$exeHash;runner_sha256=$sourceHashes;scope='local six-backend acceptance; unverified hardware scenarios remain separate'}
    $metadata | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $matrixRoot 'metadata.json') -Encoding utf8
    git diff HEAD -- src tools README.md ARCHITECTURE.md configurations.md rad-notes/windows-pane-acceptance.md | Set-Content -LiteralPath (Join-Path $matrixRoot 'pending.patch') -Encoding utf8
    $repro=Join-Path $matrixRoot 'reproduction'
    New-Item -ItemType Directory -Path $repro | Out-Null
    foreach($name in $sourceFiles){Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $repro}
    $resultFiles=@()
    foreach($backend in @('d3d11','d3d12','opengl','pure-opengl','vulkan','native-vulkan')){
        if((Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash -ne $exeHash){throw 'Executable changed during the matrix'}
        foreach($name in $sourceFiles){if((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -ne $sourceHashes[$name]){throw 'Acceptance source changed during the matrix'}}
        $destination=Join-Path $matrixRoot $backend
        New-Item -ItemType Directory -Path $destination | Out-Null
        $started=[DateTime]::UtcNow
        $failure=$null
        try{
            & $runner -Renderer $backend -TestRecovery:($backend -ne 'd3d11') -VulkanValidation:($backend -in @('vulkan','native-vulkan')) *> (Join-Path $destination 'runner.log')
        }catch{$failure=$_.Exception.Message}
        $output=Join-Path $root $(if($backend -eq 'd3d11'){'tmp/pane-acceptance'}else{"tmp/pane-acceptance-$backend"})
        $result=Join-Path $output 'result.json'
        $copied=Join-Path $destination 'result.json'
        if((Test-Path -LiteralPath $result) -and (Get-Item -LiteralPath $result).LastWriteTimeUtc -ge $started){
            Copy-Item -LiteralPath $result -Destination $copied
            $reportedHash=& jq -r '.executable_sha256' $copied
            if($LASTEXITCODE -ne 0 -or $reportedHash -ne $exeHash){throw 'Case result did not identify the tested executable'}
        }else{
            [ordered]@{renderer=$backend;status='unexecuted';error=$failure;executable_sha256=$exeHash} | ConvertTo-Json | Set-Content -LiteralPath $copied -Encoding utf8
        }
        if($failure){
            [IO.File]::WriteAllText((Join-Path $destination 'failure.txt'),$failure)
            Copy-Item -LiteralPath $copied -Destination (Join-Path $destination 'partial-result.json')
            [ordered]@{renderer=$backend;status='fail';error=$failure;executable_sha256=$exeHash;partial_result='partial-result.json'} | ConvertTo-Json | Set-Content -LiteralPath $copied -Encoding utf8
        }
        foreach($file in Get-ChildItem -LiteralPath $output -File -ErrorAction SilentlyContinue){
            if($file.LastWriteTimeUtc -ge $started -and ($file.Extension -eq '.png' -or $file.Name -like 'validation-*.log')){Copy-Item -LiteralPath $file.FullName -Destination $destination}
        }
        $diag=Join-Path $output 'tmp/mostty-diag.log'
        if((Test-Path -LiteralPath $diag) -and (Get-Item -LiteralPath $diag).LastWriteTimeUtc -ge $started){Copy-Item -LiteralPath $diag -Destination $destination}
        if((Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash -ne $exeHash){throw 'Executable changed during a case'}
        $resultFiles+=$copied
        Write-Host "$backend completed; evidence: $destination"
    }
    foreach($name in $sourceFiles){if((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $PSScriptRoot $name)).Hash -ne $sourceHashes[$name]){throw 'Acceptance source changed during the matrix'}}
    & jq -s -f (Join-Path $PSScriptRoot 'pane-matrix-summary.jq') @resultFiles | Set-Content -LiteralPath (Join-Path $matrixRoot 'summary.json') -Encoding utf8
    if($LASTEXITCODE -ne 0){throw 'Matrix summary generation failed'}
    $status=& jq -r '.status' (Join-Path $matrixRoot 'summary.json')
    $archive="$matrixRoot.zip"
    Compress-Archive -LiteralPath $matrixRoot -DestinationPath $archive
    Write-Host "Matrix: $status"
    Write-Host "Evidence archive: $archive"
    if($status -ne 'local-pass-with-limitations'){throw 'Matrix incomplete; inspect summary.json and per-case results'}
}finally{Pop-Location}
