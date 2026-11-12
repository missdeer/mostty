param([Parameter(Mandatory)][string]$Case, [Parameter(Mandatory)][string]$Output)
$ErrorActionPreference='Stop'
$catalog=Get-Content -Raw (Join-Path $PSScriptRoot 'workloads.json') | ConvertFrom-Json -AsHashtable
if (-not $catalog.ContainsKey($Case)) { throw "Unknown fixture: $Case" }
$spec=$catalog[$Case]; $esc=[string][char]27
$writer=[IO.StreamWriter]::new($Output,$false,[Text.UTF8Encoding]::new($false))
try {
    if ($spec.kind -eq 'bmp') {
        $bytes=[byte[]]::new(54+$spec.width*$spec.height*4)
        $bytes[0]=66; $bytes[1]=77
        foreach ($pair in @(@(2,$bytes.Length),@(10,54),@(14,40),@(18,$spec.width),@(22,$spec.height),@(34,($spec.width*$spec.height*4)))) {
            [BitConverter]::GetBytes([int32]$pair[1]).CopyTo($bytes,[int]$pair[0])
        }
        $bytes[26]=1; $bytes[28]=32
        for ($i=54; $i -lt $bytes.Length; $i+=4) { for ($c=0; $c -lt 4; $c++) { $bytes[$i+$c]=$spec.bgra[$c] } }
        $writer.BaseStream.Write($bytes,0,$bytes.Length)
    } elseif ($spec.kind -eq 'rgba') {
        $pixels=[byte[]]::new($spec.width*$spec.height*4)
        for ($i=0; $i -lt $pixels.Length; $i+=4) { $pixels[$i]=255; $pixels[$i+3]=255 }
        $payload=[Convert]::ToBase64String($pixels)
        for ($image=0; $image -lt $spec.iterations; $image++) {
            $id=if ($spec.replace) {1} else {$image+1}
            for ($offset=0; $offset -lt $payload.Length; $offset+=4096) {
                $length=[Math]::Min(4096,$payload.Length-$offset)
                $more=if ($offset+$length -lt $payload.Length) {'1'} else {'0'}
                $header=if ($offset -eq 0) {"${esc}_Ga=T,f=32,s=$($spec.width),v=$($spec.height),i=$id,q=2,m="} else {"${esc}_Gm="}
                $writer.Write($header+$more+';'+$payload.Substring($offset,$length)+$esc+'\')
            }
        }
    } else {
        $unit=if ($spec.kind -eq 'text') { $spec.text } else {
            $builder=[Text.StringBuilder]::new()
            for ($i=0; $i -lt $spec.count; $i++) {
                $null=$builder.Append($spec.styles[$i % $spec.styles.Count]).Append([char]($spec.start+$i))
                if ($i % 80 -eq 79) { $null=$builder.Append("`r`n") }
            }
            $null=$builder.Append("${esc}[0m"); $builder.ToString()
        }
        for ($i=0; $i -lt $spec.iterations; $i++) { $writer.Write($unit) }
    }
} finally { $writer.Dispose() }
@{case=$Case;sha256=(Get-FileHash $Output -Algorithm SHA256).Hash.ToLowerInvariant();bytes=(Get-Item $Output).Length} |
    ConvertTo-Json -Compress | Set-Content -Encoding utf8NoBOM "$Output.json"
