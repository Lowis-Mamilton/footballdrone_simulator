param(
    [Parameter(Mandatory = $true)]
    [string]$GodotPath
)

$ErrorActionPreference = "Stop"
$projectRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$engine = (Resolve-Path -LiteralPath $GodotPath).Path
$outputDirectory = Join-Path $projectRoot "dist"
$outputZip = Join-Path $outputDirectory "FootballDroneSimulator-1.0.0-macOS-universal.zip"

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

& $engine --headless --editor --path $projectRoot --import --quit
if ($LASTEXITCODE -ne 0) { throw "Godot import failed with exit code $LASTEXITCODE" }

& $engine --headless --path $projectRoot --export-release "macOS" $outputZip
if ($LASTEXITCODE -ne 0) { throw "Godot macOS export failed with exit code $LASTEXITCODE" }
if (-not (Test-Path -LiteralPath $outputZip)) { throw "Missing exported macOS archive: $outputZip" }

Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($outputZip)
try {
    $appRoot = "Football Drone Simulator.app/Contents"
    foreach ($requiredEntry in @(
        "$appRoot/Info.plist",
        "$appRoot/MacOS/Football Drone Simulator",
        "$appRoot/Resources/Football Drone Simulator.pck",
        "$appRoot/Resources/icon.icns"
    )) {
        if ($null -eq $archive.GetEntry($requiredEntry)) {
            throw "macOS archive is missing $requiredEntry"
        }
    }

    $binary = $archive.GetEntry("$appRoot/MacOS/Football Drone Simulator")
    $stream = $binary.Open()
    try {
        $header = New-Object byte[] 8
        if ($stream.Read($header, 0, 8) -ne 8) { throw "Could not read the macOS executable header." }
        $magic = ($header[0..3] | ForEach-Object { $_.ToString("X2") }) -join ""
        $architectureCount = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($header, 4))
        if ($magic -ne "CAFEBABE" -or $architectureCount -lt 2) {
            throw "Expected a Universal macOS binary, found magic=$magic architectures=$architectureCount"
        }
    } finally {
        $stream.Dispose()
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $outputZip).Hash.ToLowerInvariant()
Set-Content -LiteralPath ($outputZip + ".sha256") -Value "$hash  $([IO.Path]::GetFileName($outputZip))" -Encoding ascii
Write-Host "Created $outputZip"
Write-Host "Verified Universal macOS binary with $architectureCount architectures"
Write-Host "SHA-256 $hash  $([IO.Path]::GetFileName($outputZip))"
