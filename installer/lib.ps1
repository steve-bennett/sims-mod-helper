$script:ModsDisabledKey = 'modsdisabled'
$script:ScriptModsEnabledKey = 'scriptmodsenabled'
$script:ModExts = @('.package', '.ts4script')
$script:ArchiveExts = @('.zip', '.rar', '.7z')
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Get-SmhPaths {
    $modsRoot = if (-not [string]::IsNullOrWhiteSpace($env:SMH_MODS_ROOT_OVERRIDE)) {
        $env:SMH_MODS_ROOT_OVERRIDE
    } else {
        Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Electronic Arts\The Sims 4\Mods'
    }
    $work = Join-Path $env:LOCALAPPDATA 'SimsModHelper'
    @{
        ModsRoot         = $modsRoot
        WorkingFolder    = $work
        QuarantineFolder = Join-Path $work 'quarantine'
        LogFile          = Join-Path $work 'log.jsonl'
        ConfigFile       = Join-Path $work 'config.json'
    }
}

function Get-SmhConfig {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { $Path = (Get-SmhPaths).ConfigFile }
    if (-not (Test-Path -LiteralPath $Path)) { throw "config.json not found" }
    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-ModFolderName {
    param([int]$ProjectId, [string]$ModName)
    $slug = $ModName -replace '[^A-Za-z0-9]', '_'
    if ($slug.Length -gt 40) { $slug = $slug.Substring(0, 40) }
    "SMH_${ProjectId}_$slug"
}

function Test-DownloadUrl {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    $uri = $null
    if (-not [Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) { return $false }
    if ($uri.Scheme -ne 'https') { return $false }
    $uri.Host -eq 'edge.forgecdn.net' -or $uri.Host -eq 'mediafilez.forgecdn.net'
}

function Test-UnsafeEntryName {
    param([string]$Name)
    if ($Name -match '\.\.') { return $true }
    if ([IO.Path]::IsPathRooted($Name)) { return $true }
    if ($Name -match '^[A-Za-z]:') { return $true }
    $false
}

function Test-ContentMagic {
    param($Stream, [string]$Extension)
    $buffer = New-Object byte[] 4
    $count = $Stream.Read($buffer, 0, 4)
    if ($count -lt 4) { return $false }
    if ($Extension -eq '.package') {
        return ($buffer[0] -eq 0x44 -and $buffer[1] -eq 0x42 -and $buffer[2] -eq 0x50 -and $buffer[3] -eq 0x46)
    }
    if ($Extension -eq '.ts4script') {
        return ($buffer[0] -eq 0x50 -and $buffer[1] -eq 0x4B -and $buffer[2] -eq 0x03 -and $buffer[3] -eq 0x04)
    }
    $false
}

function Get-ProgramReason {
    param([string]$Extension)
    if ([string]::IsNullOrWhiteSpace($Extension)) { return 'it contained a program file (no extension)' }
    "it contained a program file ($Extension)"
}

function Get-ZipVerdict {
    param([string]$Path)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $result = @{ Verdict = 'blocked'; Reason = ''; Files = @() }
    $ignored = @('.txt', '.md', '.pdf', '.rtf', '.png', '.jpg', '.jpeg', '.gif', '.webp')
    $install = New-Object System.Collections.ArrayList
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $zip.Entries) {
            if (Test-UnsafeEntryName $entry.FullName) {
                $result.Reason = 'it had a broken file path'
                return $result
            }
            if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) { continue }
            $leaf = [IO.Path]::GetFileName($entry.FullName.Replace('\', '/'))
            $ext = [IO.Path]::GetExtension($leaf).ToLowerInvariant()
            if ($script:ModExts -contains $ext) {
                $stream = $entry.Open()
                try {
                    if (-not (Test-ContentMagic -Stream $stream -Extension $ext)) {
                        $result.Reason = 'it contained a disguised file'
                        return $result
                    }
                } finally {
                    $stream.Dispose()
                }
                [void]$install.Add($entry.FullName)
            } elseif ($ignored -contains $ext) {
                continue
            } elseif ($script:ArchiveExts -contains $ext) {
                $result.Reason = "it contained another archive I can't check"
                return $result
            } else {
                $result.Reason = Get-ProgramReason $ext
                return $result
            }
        }
    } finally {
        $zip.Dispose()
    }
    if ($install.Count -eq 0) {
        $result.Verdict = 'failed'
        $result.Reason = 'nothing to install in this download'
        return $result
    }
    $result.Verdict = 'install'
    $result.Files = @($install)
    $result
}

function Get-ArchiveVerdict {
    param([string]$Path)
    $result = @{ Verdict = 'blocked'; Reason = ''; Files = @() }
    $leaf = [IO.Path]::GetFileName($Path)
    $ext = [IO.Path]::GetExtension($leaf).ToLowerInvariant()
    if ($script:ModExts -contains $ext) {
        $stream = [IO.File]::OpenRead($Path)
        try {
            $ok = Test-ContentMagic -Stream $stream -Extension $ext
        } finally {
            $stream.Dispose()
        }
        if (-not $ok) {
            $result.Reason = 'it contained a disguised file'
            return $result
        }
        $result.Verdict = 'install'
        $result.Files = @($leaf)
        return $result
    }
    $stream = [IO.File]::OpenRead($Path)
    try { $isZip = Test-ContentMagic -Stream $stream -Extension '.ts4script' } finally { $stream.Dispose() }
    if ($isZip) { return Get-ZipVerdict -Path $Path }
    if ($script:ArchiveExts -contains $ext) {
        $result.Reason = "it contained another archive I can't check"
        return $result
    }
    $result.Reason = Get-ProgramReason $ext
    $result
}

function Get-UniquePath {
    param([string]$Folder, [string]$Name)
    $base = [IO.Path]::GetFileNameWithoutExtension($Name)
    $ext = [IO.Path]::GetExtension($Name)
    $candidate = Join-Path $Folder $Name
    $i = 2
    while (Test-Path -LiteralPath $candidate) {
        $candidate = Join-Path $Folder ($base + '_' + $i + $ext)
        $i++
    }
    $candidate
}

function Install-ModFiles {
    param([string]$Path, [int]$ProjectId, [string]$ModName, [string[]]$Files)
    $paths = Get-SmhPaths
    $folder = Join-Path $paths.ModsRoot (Get-ModFolderName -ProjectId $ProjectId -ModName $ModName)
    Uninstall-Mod -ProjectId $ProjectId
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $root = [IO.Path]::GetFullPath($folder).TrimEnd('\') + '\'
    $ext = [IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($script:ModExts -contains $ext) {
        $dest = Get-UniquePath -Folder $folder -Name ([IO.Path]::GetFileName($Path))
        Copy-Item -LiteralPath $Path -Destination $dest -Force
        return
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($name in $Files) {
            $entry = $zip.GetEntry($name)
            if ($null -eq $entry) { continue }
            $leaf = [IO.Path]::GetFileName($entry.FullName.Replace('\', '/'))
            $dest = Get-UniquePath -Folder $folder -Name $leaf
            $full = [IO.Path]::GetFullPath($dest)
            if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw 'entry resolved outside the mod folder'
            }
            $src = $entry.Open()
            try {
                $dst = [IO.File]::Create($full)
                try { $src.CopyTo($dst) } finally { $dst.Dispose() }
            } finally {
                $src.Dispose()
            }
        }
    } finally {
        $zip.Dispose()
    }
}

function Uninstall-Mod {
    param([int]$ProjectId)
    $paths = Get-SmhPaths
    if (-not (Test-Path -LiteralPath $paths.ModsRoot)) { return }
    Get-ChildItem -LiteralPath $paths.ModsRoot -Directory -Filter "SMH_${ProjectId}_*" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force
    }
}

function Invoke-DefenderScan {
    param([string]$Path)
    $mp = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    $detail = ''
    if (Test-Path -LiteralPath $mp) {
        $output = & $mp -Scan -ScanType 3 -File $Path -DisableRemediation 2>&1
        $code = $LASTEXITCODE
        $text = ($output | Out-String)
        if ($code -eq 0) {
            if ($text -match 'skipped') {
                return @{ Clean = $false; Method = 'mpcmdrun'; Detail = 'scan was skipped'; Flagged = $false }
            }
            if (Test-Path -LiteralPath $Path) {
                return @{ Clean = $true; Method = 'mpcmdrun'; Detail = ''; Flagged = $false }
            }
            return @{ Clean = $false; Method = 'realtime-fallback'; Detail = 'file was removed'; Flagged = $true }
        }
        if ($code -eq 2) {
            return @{ Clean = $false; Method = 'mpcmdrun'; Detail = 'threat found'; Flagged = $true }
        }
        $detail = "mpcmdrun exit $code"
        if ($text -match 'access is denied|access denied') { $detail = 'access denied' }
    } else {
        $detail = 'mpcmdrun not found'
    }
    Start-Sleep -Seconds 5
    if (-not (Test-Path -LiteralPath $Path)) {
        return @{ Clean = $false; Method = 'realtime-fallback'; Detail = 'file was removed'; Flagged = $true }
    }
    try {
        $status = Get-MpComputerStatus -ErrorAction Stop
        $detections = Get-MpThreatDetection -ErrorAction Stop
    } catch {
        return @{ Clean = $false; Method = 'unavailable'; Detail = $detail; Flagged = $false }
    }
    if (-not $status.RealTimeProtectionEnabled -or [string]$status.AMRunningMode -ne 'Normal') {
        return @{ Clean = $false; Method = 'unavailable'; Detail = "$detail; real-time protection not active"; Flagged = $false }
    }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($detection in @($detections)) {
        foreach ($resource in @($detection.Resources)) {
            if ([string]::IsNullOrWhiteSpace($resource)) { continue }
            $raw = $resource -replace '^[A-Za-z]+:_', ''
            try { $resourcePath = [IO.Path]::GetFullPath($raw) } catch { continue }
            if ($resourcePath -eq $full) {
                return @{ Clean = $false; Method = 'realtime-fallback'; Detail = 'detection present'; Flagged = $true }
            }
        }
    }
    @{ Clean = $true; Method = 'realtime-fallback'; Detail = $detail; Flagged = $false }
}

function Get-GameModSettings {
    param([string]$Path)
    $result = @{ Found = $false; ModsEnabled = $true; ScriptModsEnabled = $true }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Electronic Arts\The Sims 4\Options.ini'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $modsValue = $null
    $scriptValue = $null
    foreach ($line in Get-Content -LiteralPath $Path) {
        $index = $line.IndexOf('=')
        if ($index -lt 0) { continue }
        $key = $line.Substring(0, $index).Trim().ToLowerInvariant()
        $value = $line.Substring($index + 1).Trim()
        if ($key -eq $script:ModsDisabledKey) { $modsValue = $value }
        elseif ($key -eq $script:ScriptModsEnabledKey) { $scriptValue = $value }
    }
    if ($null -eq $modsValue -or $null -eq $scriptValue) { return $result }
    $result.Found = $true
    $result.ModsEnabled = ($modsValue -ne '1')
    $result.ScriptModsEnabled = ($scriptValue -ne '0')
    $result
}

function Write-SmhLog {
    param($Record)
    $paths = Get-SmhPaths
    $dir = Split-Path -Parent $paths.LogFile
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Record['time'] = (Get-Date).ToUniversalTime().ToString('o')
    ($Record | ConvertTo-Json -Compress -Depth 5) | Add-Content -LiteralPath $paths.LogFile -Encoding UTF8
}

function Invoke-Relay {
    param([string]$Action, $Body)
    $config = Get-SmhConfig
    $payload = @{ token = $config.installerToken; action = $Action }
    if ($null -ne $Body) {
        foreach ($key in $Body.Keys) { $payload[$key] = $Body[$key] }
    }
    Invoke-RestMethod -Method Post -Uri $config.relayUrl -ContentType 'application/json' -Body ($payload | ConvertTo-Json -Depth 5 -Compress) -TimeoutSec 30
}

function Save-CurseForgeDownload {
    param([string]$Url, [string]$OutFile)
    for ($hop = 0; $hop -le 5; $hop++) {
        if (-not (Test-DownloadUrl -Url $Url)) { throw "redirect left CurseForge: $Url" }
        $request = [Net.HttpWebRequest]::Create($Url)
        $request.AllowAutoRedirect = $false
        $request.Timeout = 30000
        $response = $null
        try {
            try { $response = $request.GetResponse() } catch [Net.WebException] { $response = $_.Exception.Response; if ($null -eq $response) { throw } }
            $code = [int]$response.StatusCode
            if ($code -ge 300 -and $code -lt 400) {
                $Url = [string](New-Object Uri ([Uri]$Url), ([string]$response.Headers['Location']))
                continue
            }
            if ($code -ne 200) { throw "download returned HTTP $code" }
            $stream = $response.GetResponseStream()
            $file = [IO.File]::Create($OutFile)
            try { $stream.CopyTo($file) } finally { $file.Dispose(); $stream.Dispose() }
            return
        } finally {
            if ($null -ne $response) { $response.Dispose() }
        }
    }
    throw 'too many redirects'
}

function Invoke-CurseForge {
    param([string]$PathAndQuery)
    $config = Get-SmhConfig
    Invoke-RestMethod -Method Get -Uri ('https://api.curseforge.com' + $PathAndQuery) -Headers @{ 'x-api-key' = $config.curseForgeKey } -TimeoutSec 30
}
