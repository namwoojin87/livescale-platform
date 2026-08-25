[CmdletBinding()]
param(
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+$')]
    [string]$Version = '1.15.9',

    [string]$WorkDirectory = 'work'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$workRoot = [IO.Path]::GetFullPath((Join-Path $projectRoot $WorkDirectory))
$downloadDirectory = Join-Path $workRoot 'downloads\terraform'
$toolDirectory = Join-Path $workRoot "tools\terraform-$Version"
$zipName = "terraform_${Version}_windows_amd64.zip"
$zipPath = Join-Path $downloadDirectory $zipName
$sumsPath = Join-Path $downloadDirectory "terraform_${Version}_SHA256SUMS"
$releaseBase = "https://releases.hashicorp.com/terraform/$Version"

New-Item -ItemType Directory -Path $downloadDirectory, $toolDirectory `
    -Force | Out-Null

Invoke-WebRequest -Uri "$releaseBase/$zipName" -OutFile $zipPath
Invoke-WebRequest -Uri "$releaseBase/terraform_${Version}_SHA256SUMS" `
    -OutFile $sumsPath

$checksumLine = Select-String -Path $sumsPath `
    -Pattern "\s$([regex]::Escape($zipName))$" |
    Select-Object -First 1
if ($null -eq $checksumLine) {
    throw "The official checksum file has no entry for $zipName."
}

$expected = ($checksumLine.Line -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $zipPath).Hash.ToLowerInvariant()
if ($actual -ne $expected) {
    throw "Terraform checksum mismatch: expected $expected, got $actual"
}

Expand-Archive -LiteralPath $zipPath -DestinationPath $toolDirectory -Force
$terraform = Join-Path $toolDirectory 'terraform.exe'
$versionOutput = & $terraform version
if ($LASTEXITCODE -ne 0 -or $versionOutput[0] -ne "Terraform v$Version") {
    throw 'The extracted Terraform executable failed version verification.'
}

Write-Output "terraform=$terraform"
Write-Output "sha256=$actual"
Write-Output "version=$($versionOutput[0])"
