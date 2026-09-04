$ErrorActionPreference = "Stop"
$target = Join-Path $env:APPDATA "Godot\app_userdata\Football Drone Simulator"
$appDataRoot = (Resolve-Path -LiteralPath $env:APPDATA).Path

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host "No Football Drone Simulator user data was found."
    exit 0
}

$resolvedTarget = (Resolve-Path -LiteralPath $target).Path
if (-not $resolvedTarget.StartsWith($appDataRoot + "\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove data outside the current user's AppData directory."
}

$confirmation = Read-Host "Delete all simulator profiles and training results? Type DELETE to confirm"
if ($confirmation -ceq "DELETE") {
    Remove-Item -Recurse -Force -LiteralPath $resolvedTarget
    Write-Host "Simulator user data was permanently removed."
} else {
    Write-Host "Cancelled. No files were removed."
}

