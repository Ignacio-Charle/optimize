$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\MemoryMonitor.ps1')

Describe 'MemoryMonitor metrics and boundaries' {
    It 'converts KiB to exact 64-bit bytes and used percent' {
        $ram = Convert-RamMeasurement -TotalVisibleKiB 1048576 -AvailableKiB 262144
        $ram.TotalBytes | Should Be 1073741824
        $ram.AvailableBytes | Should Be 268435456
        $ram.UsedBytes | Should Be 805306368
        $ram.UsedPct | Should Be 75.0
    }

    It 'rejects invalid RAM measurements instead of publishing zero' {
        { Convert-RamMeasurement -TotalVisibleKiB 0 -AvailableKiB 0 } | Should Throw
        { Convert-RamMeasurement -TotalVisibleKiB 100 -AvailableKiB 101 } | Should Throw
        { Convert-RamMeasurement -TotalVisibleKiB 100 -AvailableKiB -1 } | Should Throw
    }

    It 'rejects a sibling with the same textual prefix' {
        $parent = Join-Path ([IO.Path]::GetTempPath()) ('mm-parent-' + [guid]::NewGuid().ToString('N'))
        $root = Join-Path $parent 'Monitor'
        $sibling = Join-Path $parent 'Monitor-copy'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $sibling -Force | Out-Null
        try {
            Test-PathWithinRoot -Path (Join-Path $sibling 'sentinel.tmp') -Root $root | Should Be $false
        } finally {
            Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'HTML export' {
    It 'generates an offline HTML report with synthetic special-character text escaped' {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('mm-html-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        $out = Join-Path $temp 'report.html'
        try {
            $script = Join-Path $PSScriptRoot '..\Generate-ReportHtml.ps1'
            & $script -SyntheticExample -OutputHtml $out
            $html = [IO.File]::ReadAllText($out)
            $html | Should Match 'Content-Security-Policy'
            $html | Should Match 'Dato ausente'
            $html | Should Match 'ejemplo sintético'
        } finally {
            Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'renders untrusted report text literally rather than as markup' {
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('mm-xss-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $temp -Force | Out-Null
            $json = Join-Path $temp 'report.json'
            $out = Join-Path $temp 'report.html'
            $payload = '<img src=x onerror=alert(1)>'
            try {
                [pscustomobject]@{
                    schemaVersion=1
                    timestampUtc='2026-11-26T12:00:00Z'
                    status='partial'
                    stale=$false
                    collectors=[pscustomobject]@{
                        ram=[pscustomobject]@{status='ok';usedPct=50}
                        cpu=[pscustomobject]@{status='failed';usedPct=$null;sampleSeconds=2}
                        disk=[pscustomobject]@{status='ok';systemVolume='C:';totalBytes=100;freeBytes=50;freePct=50}
                    }
                    cleanup=[pscustomobject]@{enabled=$false;mode='Blocked';eligible=0;omitted=0;deleted=0;failed=0}
                    alerts=[pscustomobject]@{ram=$false;disk=$false}
                    diagnosticIds=@($payload)
                } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $json -Encoding UTF8

                & (Join-Path $PSScriptRoot '..\Generate-ReportHtml.ps1') -InputJson $json -OutputHtml $out
                $html = [IO.File]::ReadAllText($out)
                $html | Should Not Match '<img\s'
                $html | Should Match '&lt;img'
            } finally {
                Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
            }
    }
}
