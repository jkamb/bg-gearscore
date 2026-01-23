# BG-GearScore Auto-Updater
# Double-click to download and install the latest version

Write-Host "Updating BG-GearScore..." -ForegroundColor Cyan

# Find WoW installation (common locations)
$wowPaths = @(
    "$env:ProgramFiles\World of Warcraft\_classic_",
    "${env:ProgramFiles(x86)}\World of Warcraft\_classic_",
    "$env:USERPROFILE\World of Warcraft\_classic_",
    "C:\World of Warcraft\_classic_"
)

$wowPath = $wowPaths | Where-Object { Test-Path $_ } | Select-Object -First 1

if (-not $wowPath) {
    Write-Host "Could not find WoW installation. Please install manually." -ForegroundColor Red
    Write-Host "Download from: https://github.com/jkamb/bg-gearscore/releases/latest"
    pause
    exit
}

$addonsPath = Join-Path $wowPath "Interface\AddOns"
$addonPath = Join-Path $addonsPath "BG-GearScore"

# Get latest release info
try {
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/jkamb/bg-gearscore/releases/latest"
    $zipAsset = $release.assets | Where-Object { $_.name -like "*.zip" } | Select-Object -First 1

    if (-not $zipAsset) {
        throw "No zip file found in latest release"
    }

    Write-Host "Latest version: $($release.tag_name)" -ForegroundColor Green

    # Download zip
    $tempZip = Join-Path $env:TEMP "bg-gearscore-latest.zip"
    Write-Host "Downloading..."
    Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $tempZip

    # Remove old version
    if (Test-Path $addonPath) {
        Write-Host "Removing old version..."
        Remove-Item $addonPath -Recurse -Force
    }

    # Extract new version
    Write-Host "Installing..."
    Expand-Archive -Path $tempZip -DestinationPath $addonsPath -Force

    # Clean up
    Remove-Item $tempZip -Force

    Write-Host "`nBG-GearScore updated successfully to $($release.tag_name)!" -ForegroundColor Green
    Write-Host "Installed to: $addonPath"

} catch {
    Write-Host "`nError: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Please install manually from: https://github.com/jkamb/bg-gearscore/releases/latest"
}

Write-Host "`nPress any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
