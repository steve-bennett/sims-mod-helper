param(
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

$paths = Get-SmhPaths
$startup = [Environment]::GetFolderPath('Startup')
$cmdPath = Join-Path $startup 'SimsModHelper.cmd'

if ($Uninstall) {
    if (Test-Path -LiteralPath $cmdPath) { Remove-Item -LiteralPath $cmdPath -Force }
    if (Test-Path -LiteralPath $paths.WorkingFolder) { Remove-Item -LiteralPath $paths.WorkingFolder -Recurse -Force }
    return
}

New-Item -ItemType Directory -Path $paths.WorkingFolder -Force | Out-Null
New-Item -ItemType Directory -Path $paths.QuarantineFolder -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'lib.ps1') -Destination $paths.WorkingFolder -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'run.ps1') -Destination $paths.WorkingFolder -Force

$relayUrl = (Read-Host 'Relay URL').Trim()
$tokenSecure = Read-Host 'Installer token' -AsSecureString
$keySecure = Read-Host 'CurseForge API key' -AsSecureString

$token = [pscredential]::new('x', $tokenSecure).GetNetworkCredential().Password
$key = [pscredential]::new('x', $keySecure).GetNetworkCredential().Password

@{ relayUrl = $relayUrl; installerToken = $token; curseForgeKey = $key } |
    ConvertTo-Json | Set-Content -LiteralPath $paths.ConfigFile -Encoding UTF8

$acl = New-Object System.Security.AccessControl.FileSecurity
$acl.SetAccessRuleProtection($true, $false)
$identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
$acl.AddAccessRule($rule)
[System.IO.File]::SetAccessControl($paths.ConfigFile, $acl)

$runPath = Join-Path $paths.WorkingFolder 'run.ps1'
$psArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$runPath`" -Loop"
Set-Content -LiteralPath $cmdPath -Value "@echo off`r`npowershell.exe $psArgs`r`n" -Encoding ASCII
Start-Process -FilePath 'powershell.exe' -ArgumentList $psArgs -WindowStyle Hidden
