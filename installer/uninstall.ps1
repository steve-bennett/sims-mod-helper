param(
    [Parameter(Mandatory = $true)]
    [int]$ProjectId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib.ps1')

Uninstall-Mod -ProjectId $ProjectId
Write-SmhLog @{ step = 'manual-uninstall'; projectId = $ProjectId }
