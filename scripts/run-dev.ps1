param(
    [Parameter(Mandatory = $true)]
    [string]$GodotPath
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$engine = (Resolve-Path -LiteralPath $GodotPath).Path
& $engine --editor --path $projectRoot

