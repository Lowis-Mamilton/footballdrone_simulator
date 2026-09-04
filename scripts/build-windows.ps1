param(
    [Parameter(Mandatory = $true)]
    [string]$GodotPath,
    [string]$InnoSetupPath = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$engine = (Resolve-Path -LiteralPath $GodotPath).Path
$outputDirectory = Join-Path $projectRoot "dist"
$outputExe = Join-Path $outputDirectory "FootballDroneSimulator.exe"

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

& $engine --headless --editor --path $projectRoot --import --quit
if ($LASTEXITCODE -ne 0) { throw "Godot import failed with exit code $LASTEXITCODE" }

& $engine --headless --path $projectRoot --export-release "Windows Desktop" $outputExe
if ($LASTEXITCODE -ne 0) { throw "Godot export failed with exit code $LASTEXITCODE" }

Write-Host "Created $outputExe"
$artifacts = @($outputExe, (Join-Path $outputDirectory "FootballDroneSimulator.pck"))
foreach ($artifact in $artifacts) {
    if (-not (Test-Path -LiteralPath $artifact)) { throw "Missing exported artifact: $artifact" }
    $hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $artifact).Hash.ToLowerInvariant()
    $hashPath = $artifact + ".sha256"
    Set-Content -LiteralPath $hashPath -Value "$hash  $([IO.Path]::GetFileName($artifact))" -Encoding ascii
    Write-Host "SHA-256 $hash  $([IO.Path]::GetFileName($artifact))"
}

if (-not [string]::IsNullOrWhiteSpace($InnoSetupPath)) {
    $compiler = (Resolve-Path -LiteralPath $InnoSetupPath).Path
    & $compiler (Join-Path $projectRoot "installer\FootballDroneSimulator.iss")
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed with exit code $LASTEXITCODE" }
} else {
    Write-Host "Inno Setup path not supplied; portable EXE/PCK produced, installer skipped."
}
