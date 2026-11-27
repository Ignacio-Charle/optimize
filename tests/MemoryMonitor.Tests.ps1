$ErrorActionPreference = 'Stop'

Describe 'MemoryMonitor metrics and boundaries' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\MemoryMonitor.ps1')
    }

    It 'converts KiB to exact 64-bit bytes and used percent' {
        $ram = Convert-RamMeasurement -TotalVisibleKiB 1048576 -AvailableKiB 262144
        if ($ram.TotalBytes -ne 1073741824) { throw 'incorrect total bytes' }
        if ($ram.AvailableBytes -ne 268435456) { throw 'incorrect available bytes' }
        if ($ram.UsedBytes -ne 805306368) { throw 'incorrect used bytes' }
        if ($ram.UsedPct -ne 75.0) { throw 'incorrect used percentage' }
    }

    It 'rejects invalid RAM measurements instead of publishing zero' {
        foreach ($case in @(
            { Convert-RamMeasurement -TotalVisibleKiB 0 -AvailableKiB 0 },
            { Convert-RamMeasurement -TotalVisibleKiB 100 -AvailableKiB 101 },
            { Convert-RamMeasurement -TotalVisibleKiB 100 -AvailableKiB -1 }
        )) {
            $threw = $false
            try { & $case } catch { $threw = $true }
            if (-not $threw) { throw 'an invalid measurement was not rejected' }
        }
    }

    It 'rejects a sibling with the same textual prefix' {
        $parent = Join-Path ([IO.Path]::GetTempPath()) ('mm-parent-' + [guid]::NewGuid().ToString('N'))
        $root = Join-Path $parent 'Monitor'
        $sibling = Join-Path $parent 'Monitor-copy'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $sibling -Force | Out-Null
        try {
            if (Test-PathWithinRoot -Path (Join-Path $sibling 'sentinel.tmp') -Root $root) { throw 'a sibling path with a matching prefix was accepted' }
        } finally {
            Remove-Item -LiteralPath $parent -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'HTML export' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '..\MemoryMonitor.ps1')
    }

    It 'generates an offline HTML report with synthetic special-character text escaped' {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('mm-html-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp -Force | Out-Null
        $out = Join-Path $temp 'report.html'
        try {
            $script = Join-Path $PSScriptRoot '..\Generate-ReportHtml.ps1'
            & $script -SyntheticExample -OutputHtml $out
            $html = [IO.File]::ReadAllText($out)
            if ($html -notmatch 'Content-Security-Policy') { throw 'missing CSP' }
            if ($html -notmatch 'Data unavailable') { throw 'missing unavailable/partial state' }
            if ($html -notmatch 'synthetic example') { throw 'missing synthetic content' }
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
                if ($html -match '<img\s') { throw 'untrusted markup was interpreted as HTML' }
                if ($html -notmatch '&lt;img') { throw 'synthetic data was not escaped' }
            } finally {
                Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
            }
    }
}
