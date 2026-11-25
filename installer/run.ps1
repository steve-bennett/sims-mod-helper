param(
    [string]$FixtureDir,
    [switch]$Loop
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$script:Sims4GameId = 78062

function Get-FixtureJson {
    param([string]$Dir, [string]$Name)
    Get-Content -LiteralPath (Join-Path $Dir $Name) -Raw | ConvertFrom-Json
}

function Send-Report {
    param($Row, [string]$Status, [string]$Reason, [string]$FixtureDir)
    if ($Reason.Length -gt 300) { $Reason = $Reason.Substring(0, 300) }
    $record = @{ id = [string]$Row.id; status = $Status; reason = $Reason }
    if ([string]::IsNullOrWhiteSpace($FixtureDir)) {
        Invoke-Relay -Action 'report' -Body $record | Out-Null
    } else {
        ($record | ConvertTo-Json -Compress -Depth 3) | Add-Content -LiteralPath (Join-Path $FixtureDir 'reports.jsonl') -Encoding UTF8
    }
    Write-SmhLog @{ step = 'report'; id = [string]$Row.id; status = $Status; reason = $Reason }
}

function Invoke-InstallRow {
    param($Row, [string]$FixtureDir)
    $fixture = -not [string]::IsNullOrWhiteSpace($FixtureDir)
    $rowId = [string]$Row.id
    $paths = Get-SmhPaths
    $quarantineRow = Join-Path $paths.QuarantineFolder $rowId

    try {
        $projectId = [int]$Row.projectId
        $fileId = [int]$Row.fileId
        $modName = [string]$Row.modName
        if ($fixture) {
            $mod = Get-FixtureJson -Dir $FixtureDir -Name ("mod-$projectId.json")
            $file = Get-FixtureJson -Dir $FixtureDir -Name ("file-$projectId-$fileId.json")
        } else {
            $mod = Invoke-CurseForge -PathAndQuery "/v1/mods/$projectId"
            $file = Invoke-CurseForge -PathAndQuery "/v1/mods/$projectId/files/$fileId"
        }
        if ($null -ne $mod.data) { $mod = $mod.data }
        if ($null -ne $file.data) { $file = $file.data }
        Write-SmhLog @{ step = 'fetched'; projectId = $projectId; fileId = $fileId }

        if ([int]$mod.gameId -ne $script:Sims4GameId) {
            Send-Report -Row $Row -Status 'blocked' -Reason "that isn't a Sims 4 mod" -FixtureDir $FixtureDir
            return
        }
        if (-not $mod.allowModDistribution -or [string]::IsNullOrWhiteSpace([string]$file.downloadUrl)) {
            Send-Report -Row $Row -Status 'blocked' -Reason "creator doesn't allow outside downloads" -FixtureDir $FixtureDir
            return
        }
        if (-not (Test-DownloadUrl -Url ([string]$file.downloadUrl))) {
            Send-Report -Row $Row -Status 'blocked' -Reason "download wasn't from CurseForge" -FixtureDir $FixtureDir
            return
        }

        $safeName = ([string]$file.fileName) -replace '[^A-Za-z0-9._-]', '_'
        if ([string]::IsNullOrWhiteSpace($safeName)) { $safeName = 'download.bin' }
        New-Item -ItemType Directory -Path $quarantineRow -Force | Out-Null
        $quarantineFile = Join-Path $quarantineRow $safeName

        if ($fixture) {
            Copy-Item -LiteralPath (Join-Path $FixtureDir ([string]$file.fileName)) -Destination $quarantineFile -Force
        } else {
            Save-CurseForgeDownload -Url ([string]$file.downloadUrl) -OutFile $quarantineFile
        }
        Write-SmhLog @{ step = 'downloaded'; id = $rowId; file = $safeName }

        $scan = Invoke-DefenderScan -Path $quarantineFile
        Write-SmhLog @{ step = 'scan'; id = $rowId; clean = $scan.Clean; method = $scan.Method; detail = $scan.Detail }
        if (-not $scan.Clean) {
            $why = if ($scan.Flagged) { 'virus scanner flagged it' } else { "couldn't run the virus check" }
            Send-Report -Row $Row -Status 'blocked' -Reason $why -FixtureDir $FixtureDir
            return
        }

        $verdict = Get-ArchiveVerdict -Path $quarantineFile
        Write-SmhLog @{ step = 'verdict'; id = $rowId; verdict = $verdict.Verdict; reason = $verdict.Reason }
        if ($verdict.Verdict -eq 'blocked' -or $verdict.Verdict -eq 'failed') {
            Send-Report -Row $Row -Status $verdict.Verdict -Reason $verdict.Reason -FixtureDir $FixtureDir
            return
        }

        Install-ModFiles -Path $quarantineFile -ProjectId $projectId -ModName $modName -Files $verdict.Files
        Write-SmhLog @{ step = 'installed'; id = $rowId; projectId = $projectId; files = $verdict.Files }

        $reason = ''
        $settings = Get-GameModSettings
        if ($settings.Found -and (-not $settings.ModsEnabled -or -not $settings.ScriptModsEnabled)) {
            $reason = 'installed, but mods are switched off in the game settings'
        }
        Send-Report -Row $Row -Status 'installed' -Reason $reason -FixtureDir $FixtureDir
    } catch {
        Write-SmhLog @{ step = 'error'; id = $rowId; error = $_.Exception.Message }
        try { Send-Report -Row $Row -Status 'failed' -Reason "couldn't download it, will need a retry" -FixtureDir $FixtureDir } catch { }
    } finally {
        if (Test-Path -LiteralPath $quarantineRow) {
            Remove-Item -LiteralPath $quarantineRow -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-UninstallRow {
    param($Row, [string]$FixtureDir)
    Uninstall-Mod -ProjectId ([int]$Row.projectId)
    Write-SmhLog @{ step = 'uninstalled'; id = [string]$Row.id; projectId = [int]$Row.projectId }
    Send-Report -Row $Row -Status 'uninstalled' -Reason '' -FixtureDir $FixtureDir
}

function Invoke-SmhPass {
    param([string]$FixtureDir)
    $fixture = -not [string]::IsNullOrWhiteSpace($FixtureDir)
    if ($fixture) {
        $pending = Get-FixtureJson -Dir $FixtureDir -Name 'pending.json'
    } else {
        $pending = Invoke-Relay -Action 'pending' -Body @{}
    }
    if (-not $pending.ok) {
        Write-SmhLog @{ step = 'pending'; error = [string]$pending.error }
        return
    }
    $rows = @($pending.rows)
    if ($rows.Count -eq 0) { return }
    Write-SmhLog @{ step = 'pending'; count = $rows.Count }
    foreach ($row in $rows) {
        $guid = [guid]::Empty
        if (-not [guid]::TryParse([string]$row.id, [ref]$guid)) {
            Write-SmhLog @{ step = 'row-error'; error = 'row id is not a uuid' }
            continue
        }
        $row.id = $guid.ToString()
        try {
            if ($row.action -eq 'uninstall') {
                Invoke-UninstallRow -Row $row -FixtureDir $FixtureDir
            } elseif ($row.action -eq 'install') {
                Invoke-InstallRow -Row $row -FixtureDir $FixtureDir
            }
        } catch {
            Write-SmhLog @{ step = 'row-error'; id = [string]$row.id; error = $_.Exception.Message }
        }
    }
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\SimsModHelper')
if (-not $mutex.WaitOne(0)) { exit 0 }
try {
    do {
        try {
            Invoke-SmhPass -FixtureDir $FixtureDir
        } catch {
            Write-SmhLog @{ step = 'pass-error'; error = $_.Exception.Message }
        }
        if ($Loop) { Start-Sleep -Seconds 300 }
    } while ($Loop)
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
