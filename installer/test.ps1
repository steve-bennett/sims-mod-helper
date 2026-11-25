$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

$script:failures = 0

function Pass-Case {
    param([string]$Name)
    Write-Host "PASS $Name"
}

function Fail-Case {
    param([string]$Name, [string]$Detail)
    Write-Host "FAIL ${Name}: $Detail"
    $script:failures++
}

function Run-Case {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        Pass-Case $Name
    } catch {
        Fail-Case $Name $_.Exception.Message
    }
}

function Assert {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$What)
    if ("$Expected" -ne "$Actual") { throw "$What expected '$Expected' got '$Actual'" }
}

$root = Join-Path $env:TEMP ('smh-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$modsRoot = Join-Path $root 'Mods'
New-Item -ItemType Directory -Path $modsRoot -Force | Out-Null
$oldModsOverride = $env:SMH_MODS_ROOT_OVERRIDE
$oldLocal = $env:LOCALAPPDATA
$env:SMH_MODS_ROOT_OVERRIDE = $modsRoot
$env:LOCALAPPDATA = Join-Path $root 'LocalAppData'
New-Item -ItemType Directory -Path $env:LOCALAPPDATA -Force | Out-Null

. (Join-Path $PSScriptRoot 'lib.ps1')

function New-Zip {
    param([string]$Path, [object[]]$Entries)
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force }
    $zip = [IO.Compression.ZipFile]::Open($Path, 'Create')
    try {
        foreach ($item in $Entries) {
            $entry = $zip.CreateEntry([string]$item.Name)
            $stream = $entry.Open()
            try {
                $bytes = [Text.Encoding]::ASCII.GetBytes([string]$item.Content)
                $stream.Write($bytes, 0, $bytes.Length)
            } finally {
                $stream.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Get-ModFolder {
    param([int]$ProjectId, [string]$ModName)
    Join-Path $modsRoot (Get-ModFolderName -ProjectId $ProjectId -ModName $ModName)
}

function Write-JsonFile {
    param([string]$Path, $Object)
    $Object | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function New-FixtureDir {
    param([string]$Name)
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $dir
}

function Invoke-RunFixture {
    param([string]$Dir)
    $runScript = Join-Path $PSScriptRoot 'run.ps1'
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$runScript`" -FixtureDir `"$Dir`""
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Wait -PassThru -WindowStyle Hidden
    Assert-Equal 0 $process.ExitCode 'run exit code'
}

function Get-Reports {
    param([string]$Dir)
    $path = Join-Path $Dir 'reports.jsonl'
    Assert (Test-Path -LiteralPath $path) 'reports.jsonl missing'
    @(Get-Content -LiteralPath $path | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
}

$pkMagic = 'PK' + [char]3 + [char]4

Run-Case 'parse-all' {
    foreach ($file in Get-ChildItem -LiteralPath $PSScriptRoot -Filter *.ps1) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count -gt 0) { throw "$($file.Name): $($errors[0].Message)" }
    }
}

Run-Case 'good-zip' {
    $zipPath = Join-Path $root 'good.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = 'sub/cool.package'; Content = 'DBPFpayload' },
        @{ Name = 'scripts/cool.ts4script'; Content = ($pkMagic + 'payload') },
        @{ Name = 'readme.txt'; Content = 'hello' }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'install' $verdict.Verdict 'verdict'
    Assert-Equal 2 $verdict.Files.Count 'file count'
    Install-ModFiles -Path $zipPath -ProjectId 123 -ModName 'Cool Hair' -Files $verdict.Files
    $folder = Get-ModFolder 123 'Cool Hair'
    Assert (Test-Path -LiteralPath $folder) 'mod folder missing'
    $names = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { $_.Name })
    Assert ($names -contains 'cool.package') 'cool.package missing'
    Assert ($names -contains 'cool.ts4script') 'cool.ts4script missing'
    Assert (-not ($names -contains 'readme.txt')) 'readme.txt was installed'
    Assert-Equal 2 $names.Count 'flat file count'
    Assert (-not (Test-Path -LiteralPath (Join-Path $folder 'sub'))) 'sub-folder was created'
}

Run-Case 'dup-names' {
    $zipPath = Join-Path $root 'dup.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = 'a/a.package'; Content = 'DBPFone' },
        @{ Name = 'b/a.package'; Content = 'DBPFtwo' }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'install' $verdict.Verdict 'verdict'
    Install-ModFiles -Path $zipPath -ProjectId 124 -ModName 'Dup' -Files $verdict.Files
    $folder = Get-ModFolder 124 'Dup'
    $names = @(Get-ChildItem -LiteralPath $folder -File | ForEach-Object { $_.Name })
    Assert ($names -contains 'a.package') 'a.package missing'
    Assert ($names -contains 'a_2.package') 'a_2.package missing'
    Assert-Equal 2 $names.Count 'file count'
}

Run-Case 'exe-blocks' {
    $zipPath = Join-Path $root 'exe.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = 'mod.package'; Content = 'DBPFpayload' },
        @{ Name = 'setup.exe'; Content = 'MZprogram' }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'blocked' $verdict.Verdict 'verdict'
    Assert-Equal 'it contained a program file (.exe)' $verdict.Reason 'reason'
    Assert (-not (Test-Path -LiteralPath (Get-ModFolder 125 'Bad Exe'))) 'mod folder was created'
}

Run-Case 'nested-zip-blocks' {
    $zipPath = Join-Path $root 'nested.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = 'mod.package'; Content = 'DBPFpayload' },
        @{ Name = 'inner.zip'; Content = ($pkMagic + 'payload') }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'blocked' $verdict.Verdict 'verdict'
    Assert-Equal "it contained another archive I can't check" $verdict.Reason 'reason'
    Assert (-not (Test-Path -LiteralPath (Get-ModFolder 126 'Nested'))) 'mod folder was created'
}

Run-Case 'noext-blocks' {
    $zipPath = Join-Path $root 'noext.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = 'mod.package'; Content = 'DBPFpayload' },
        @{ Name = 'README'; Content = 'hello' }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'blocked' $verdict.Verdict 'verdict'
    Assert ($verdict.Reason -match 'program file') "reason was '$($verdict.Reason)'"
}

Run-Case 'zip-slip' {
    $zipPath = Join-Path $root 'slip.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = '..\..\evil.package'; Content = 'DBPFpayload' }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'blocked' $verdict.Verdict 'verdict'
    Assert-Equal 'it had a broken file path' $verdict.Reason 'reason'
    Assert (-not (Test-Path -LiteralPath (Get-ModFolder 127 'Slip'))) 'mod folder was created'
    Assert (-not (Test-Path -LiteralPath (Join-Path $modsRoot 'evil.package'))) 'evil.package written in Mods root'
    $aboveRoot = Split-Path -Parent $modsRoot
    Assert (-not (Test-Path -LiteralPath (Join-Path $aboveRoot 'evil.package'))) 'evil.package written above Mods root'
    $twoAbove = Split-Path -Parent $aboveRoot
    Assert (-not (Test-Path -LiteralPath (Join-Path $twoAbove 'evil.package'))) 'evil.package written two levels above Mods root'
}

Run-Case 'disguised' {
    $file = Join-Path $root 'x.package'
    [IO.File]::WriteAllText($file, 'MZ this is a program')
    $verdict = Get-ArchiveVerdict -Path $file
    Assert-Equal 'blocked' $verdict.Verdict 'verdict'
    Assert-Equal 'it contained a disguised file' $verdict.Reason 'reason'
}

Run-Case 'empty-zip-fails' {
    $zipPath = Join-Path $root 'empty.zip'
    New-Zip -Path $zipPath -Entries @(
        @{ Name = 'readme.txt'; Content = 'hello' }
    )
    $verdict = Get-ArchiveVerdict -Path $zipPath
    Assert-Equal 'failed' $verdict.Verdict 'verdict'
    Assert-Equal 'nothing to install in this download' $verdict.Reason 'reason'
}

Run-Case 'bad-host' {
    Assert (-not (Test-DownloadUrl -Url 'https://evil.example.com/x.zip')) 'accepted evil host'
    Assert (-not (Test-DownloadUrl -Url 'http://edge.forgecdn.net/x.zip')) 'accepted http'
    Assert (-not (Test-DownloadUrl -Url 'https://edge.forgecdn.net.evil.com/x.zip')) 'accepted lookalike host'
    Assert (Test-DownloadUrl -Url 'https://edge.forgecdn.net/files/1/2/x.zip') 'rejected good host'
}

Run-Case 'uninstall' {
    $target = Join-Path $modsRoot 'SMH_123_Cool_Hair'
    $sibling = Join-Path $modsRoot 'SMH_1234_Other'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    New-Item -ItemType Directory -Path $sibling -Force | Out-Null
    Uninstall-Mod -ProjectId 123
    Assert (-not (Test-Path -LiteralPath $target)) 'SMH_123_ folder survived'
    Assert (Test-Path -LiteralPath $sibling) 'SMH_1234_Other was removed'
}

Run-Case 'settings-off' {
    $ini = Join-Path $root 'Options.ini'
    Set-Content -LiteralPath $ini -Value "[options]`nmodsdisabled = 1`nscriptmodsenabled = 1" -Encoding ASCII
    $settings = Get-GameModSettings -Path $ini
    Assert $settings.Found 'settings not found'
    Assert (-not $settings.ModsEnabled) 'ModsEnabled should be false'
}

Run-Case 'clean-file' {
    $file = Join-Path $root 'clean.package'
    [IO.File]::WriteAllBytes($file, [Text.Encoding]::ASCII.GetBytes('DBPFclean'))
    $scan = Invoke-DefenderScan -Path $file
    Assert $scan.Clean "not clean via $($scan.Method): $($scan.Detail)"
}

$eicar = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-'
$eicar += 'STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
$eicarPath = Join-Path $root 'eicar.txt'
[IO.File]::WriteAllText($eicarPath, $eicar)
$eicarScan = Invoke-DefenderScan -Path $eicarPath
if ($eicarScan.Clean) {
    Fail-Case 'eicar' "scan said clean via $($eicarScan.Method)"
} else {
    Write-Host "PASS eicar (method=$($eicarScan.Method), detail=$($eicarScan.Detail))"
}

Run-Case 'run-fixture-good' {
    $dir = New-FixtureDir 'fixture-good'
    New-Zip -Path (Join-Path $dir 'cool.zip') -Entries @(
        @{ Name = 'hair.package'; Content = 'DBPFhair' },
        @{ Name = 'hair.ts4script'; Content = ($pkMagic + 'script') }
    )
    Write-JsonFile -Path (Join-Path $dir 'pending.json') -Object @{
        ok = $true
        rows = @(@{
            id = '95eaac93-a693-5f41-a46c-03ce32759a6a'; action = 'install'; projectId = 140; fileId = 540
            modName = 'Fixture Hair'; requestedBy = 'test'; requestedAt = ''
            status = 'pending'; reason = ''; updatedAt = ''; notified = ''
        })
    }
    Write-JsonFile -Path (Join-Path $dir 'mod-140.json') -Object @{ gameId = 78062; allowModDistribution = $true; name = 'Fixture Hair' }
    Write-JsonFile -Path (Join-Path $dir 'file-140-540.json') -Object @{ id = 540; fileName = 'cool.zip'; downloadUrl = 'https://edge.forgecdn.net/files/1/2/cool.zip' }
    Invoke-RunFixture -Dir $dir
    $reports = Get-Reports -Dir $dir
    $installed = @($reports | Where-Object { $_.status -eq 'installed' })
    Assert ($installed.Count -eq 1) "no installed report: $($reports | ConvertTo-Json -Compress)"
    $folder = Get-ModFolder 140 'Fixture Hair'
    Assert (Test-Path -LiteralPath $folder) 'fixture mod folder missing'
    Assert-Equal 2 @(Get-ChildItem -LiteralPath $folder -File).Count 'fixture file count'
}

Run-Case 'bad-row-id' {
    $dir = New-FixtureDir 'fixture-badid'
    $sentinel = Join-Path $root ('smh-sentinel-' + [guid]::NewGuid())
    New-Item -ItemType Directory -Path $sentinel | Out-Null
    Write-JsonFile -Path (Join-Path $dir 'pending.json') -Object @{
        ok = $true
        rows = @(@{
            id = ('..\..\..\' + (Split-Path -Leaf $sentinel)); action = 'install'; projectId = 141; fileId = 541
            modName = 'Bad Id'; requestedBy = 'test'; requestedAt = ''
            status = 'pending'; reason = ''; updatedAt = ''; notified = ''
        })
    }
    Invoke-RunFixture -Dir $dir
    Assert (Test-Path -LiteralPath $sentinel) 'sentinel folder was deleted'
    Assert (-not (Test-Path -LiteralPath (Join-Path $dir 'reports.jsonl'))) 'a report was written for a bad id'
    Remove-Item -LiteralPath $sentinel -Recurse -Force
}

Run-Case 'run-fixture-badhost' {
    $dir = New-FixtureDir 'fixture-badhost'
    Write-JsonFile -Path (Join-Path $dir 'pending.json') -Object @{
        ok = $true
        rows = @(@{
            id = '80e31d4c-fc86-5ba4-8552-dcb7b7755aed'; action = 'install'; projectId = 141; fileId = 541
            modName = 'Bad Host'; requestedBy = 'test'; requestedAt = ''
            status = 'pending'; reason = ''; updatedAt = ''; notified = ''
        })
    }
    Write-JsonFile -Path (Join-Path $dir 'mod-141.json') -Object @{ gameId = 78062; allowModDistribution = $true; name = 'Bad Host' }
    Write-JsonFile -Path (Join-Path $dir 'file-141-541.json') -Object @{ id = 541; fileName = 'bad.zip'; downloadUrl = 'https://evil.example.com/x.zip' }
    Invoke-RunFixture -Dir $dir
    $reports = Get-Reports -Dir $dir
    $blocked = @($reports | Where-Object { $_.status -eq 'blocked' -and $_.reason -eq "download wasn't from CurseForge" })
    Assert ($blocked.Count -eq 1) "wrong report: $($reports | ConvertTo-Json -Compress)"
}

Run-Case 'run-fixture-nodistrib' {
    $dir = New-FixtureDir 'fixture-nodistrib'
    Write-JsonFile -Path (Join-Path $dir 'pending.json') -Object @{
        ok = $true
        rows = @(@{
            id = '4c48d19d-44b7-5ff8-a203-5b8e40b1d611'; action = 'install'; projectId = 142; fileId = 542
            modName = 'No Distrib'; requestedBy = 'test'; requestedAt = ''
            status = 'pending'; reason = ''; updatedAt = ''; notified = ''
        })
    }
    Write-JsonFile -Path (Join-Path $dir 'mod-142.json') -Object @{ gameId = 78062; allowModDistribution = $false; name = 'No Distrib' }
    Write-JsonFile -Path (Join-Path $dir 'file-142-542.json') -Object @{ id = 542; fileName = 'ok.zip'; downloadUrl = 'https://edge.forgecdn.net/files/1/2/ok.zip' }
    Invoke-RunFixture -Dir $dir
    $reports = Get-Reports -Dir $dir
    $blocked = @($reports | Where-Object { $_.status -eq 'blocked' -and $_.reason -eq "creator doesn't allow outside downloads" })
    Assert ($blocked.Count -eq 1) "wrong report: $($reports | ConvertTo-Json -Compress)"
}

$env:SMH_MODS_ROOT_OVERRIDE = $oldModsOverride
$env:LOCALAPPDATA = $oldLocal
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

if ($script:failures -gt 0) { exit 1 }
exit 0
