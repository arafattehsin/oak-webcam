param(
    [int]$DaysToKeep = 3,
    [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$logsRoot = Join-Path $scriptDir '..\logs'
$logsRoot = (Resolve-Path $logsRoot).ProviderPath

Write-Output "Cleaning logs under: $logsRoot (keeping $DaysToKeep day(s))"

# Compute threshold date
$threshold = (Get-Date).AddDays(-$DaysToKeep)

# Expect folders in logs\YYYY\MM\DD
Get-ChildItem -Path $logsRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $yearDir = $_
    Get-ChildItem -Path $yearDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $monthDir = $_
        Get-ChildItem -Path $monthDir.FullName -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $dayDir = $_
            # Parse folder names (YYYY/MM/DD) into a date
            try {
                $folderDate = [datetime]::ParseExact((Join-Path $_.Parent.Parent.Name ($_.Parent.Name) + "/" + $_.Name), 'yyyy/MM/dd', $null)
            } catch {
                # If parsing fails, fallback to folder lastwritetime
                $folderDate = $_.LastWriteTime
            }

            if ($folderDate -lt $threshold) {
                if ($WhatIf) {
                    Write-Output "Would remove: $($_.FullName) (date: $folderDate)"
                }
                else {
                    Write-Output "Removing: $($_.FullName) (date: $folderDate)"
                    Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

Write-Output "Cleanup complete."
