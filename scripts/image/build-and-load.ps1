[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SshKey,

    [Parameter(Mandatory)]
    [string]$KnownHosts,

    [Parameter(Mandatory)]
    [SecureString]$SudoPassword,

    [ValidatePattern('^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Image = 'livescale-api:0.1.0'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$appDirectory = (Resolve-Path (Join-Path $projectRoot 'app')).Path
$sshKeyPath = (Resolve-Path $SshKey).Path
$knownHostsPath = (Resolve-Path $KnownHosts).Path
$sshKeyOptionPath = $sshKeyPath.Replace('\', '/')
$knownHostsOptionPath = $knownHostsPath.Replace('\', '/')
$runId = Get-Date -Format 'yyyyMMddHHmmss'
$remoteBuild = "/tmp/livescale-build-$runId"
$remoteArchive = "/tmp/livescale-api-$runId.tar"
$localArchiveDirectory = Join-Path $projectRoot 'work\image'
$localArchive = Join-Path $localArchiveDirectory "livescale-api-$runId.tar"
$normalizedImage = if ($Image.StartsWith('docker.io/')) {
    $Image
} else {
    "docker.io/library/$Image"
}

if ($remoteBuild -notmatch '^/tmp/livescale-build-[0-9]{14}$' -or
    $remoteArchive -notmatch '^/tmp/livescale-api-[0-9]{14}\.tar$') {
    throw 'Generated remote cleanup paths failed validation.'
}

$nodes = @(
    @{ Name = 'livescale-control'; Ip = '172.16.8.50' },
    @{ Name = 'livescale-worker-1'; Ip = '172.16.8.51' },
    @{ Name = 'livescale-worker-2'; Ip = '172.16.8.52' }
)

$sshOptions = @(
    '-i', $sshKeyOptionPath,
    '-o', 'BatchMode=yes',
    '-o', 'StrictHostKeyChecking=yes',
    '-o', "UserKnownHostsFile=$knownHostsOptionPath"
)
$script:LiveScaleSshOptions = $sshOptions

$bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SudoPassword)
try {
    $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
} finally {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
}
$script:LiveScaleSudoPassword = $plainPassword

function Assert-NativeCommand {
    param(
        [Parameter(Mandatory)]
        [int]$ExitCode,

        [Parameter(Mandatory)]
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Output,

        [Parameter(Mandatory)]
        [string]$Description
    )

    if ($ExitCode -ne 0) {
        throw "$Description failed:`n$($Output -join [Environment]::NewLine)"
    }
}

function Invoke-Remote {
    param(
        [Parameter(Mandatory)]
        [string]$Ip,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $output = & ssh @script:LiveScaleSshOptions "user1@$Ip" $Command 2>&1
    $exitCode = $LASTEXITCODE
    Assert-NativeCommand -ExitCode $exitCode -Output $output `
        -Description "SSH command on $Ip"
    return $output
}

function Invoke-RemoteSudo {
    param(
        [Parameter(Mandatory)]
        [string]$Ip,

        [Parameter(Mandatory)]
        [string]$Command
    )

    $output = $script:LiveScaleSudoPassword |
        & ssh @script:LiveScaleSshOptions "user1@$Ip" "sudo -S -p '' $Command" 2>&1
    $exitCode = $LASTEXITCODE
    Assert-NativeCommand -ExitCode $exitCode -Output $output `
        -Description "privileged SSH command on $Ip"
    return $output
}

function Copy-ToRemote {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination,

        [switch]$Recurse
    )

    if ($Recurse) {
        $output = & scp @script:LiveScaleSshOptions -r $Source $Destination 2>&1
    } else {
        $output = & scp @script:LiveScaleSshOptions $Source $Destination 2>&1
    }
    $exitCode = $LASTEXITCODE
    Assert-NativeCommand -ExitCode $exitCode -Output $output `
        -Description "copy to $Destination"
}

function Copy-FromRemote {
    param(
        [Parameter(Mandatory)]
        [string]$Source,

        [Parameter(Mandatory)]
        [string]$Destination
    )

    $output = & scp @script:LiveScaleSshOptions $Source $Destination 2>&1
    $exitCode = $LASTEXITCODE
    Assert-NativeCommand -ExitCode $exitCode -Output $output `
        -Description "copy from $Source"
}

New-Item -ItemType Directory -Path $localArchiveDirectory -Force | Out-Null
$dockerStarted = $false

try {
    Invoke-Remote -Ip '172.16.8.50' -Command "mkdir -p $remoteBuild" | Out-Null
    Copy-ToRemote -Source $appDirectory `
        -Destination "user1@172.16.8.50:$remoteBuild/app" -Recurse

    Invoke-RemoteSudo -Ip '172.16.8.50' -Command 'systemctl start docker' | Out-Null
    $dockerStarted = $true
    Invoke-RemoteSudo -Ip '172.16.8.50' -Command (
        "docker build --pull --tag $Image --file $remoteBuild/app/Dockerfile $remoteBuild/app"
    ) | Out-Null
    Invoke-RemoteSudo -Ip '172.16.8.50' -Command (
        "docker save --output $remoteArchive $Image"
    ) | Out-Null
    Invoke-RemoteSudo -Ip '172.16.8.50' -Command "chmod 0644 $remoteArchive" | Out-Null
    Invoke-RemoteSudo -Ip '172.16.8.50' -Command (
        "k3s ctr images import $remoteArchive"
    ) | Out-Null

    Copy-FromRemote -Source "user1@172.16.8.50:$remoteArchive" `
        -Destination $localArchive

    foreach ($node in $nodes | Select-Object -Skip 1) {
        Copy-ToRemote -Source $localArchive `
            -Destination "user1@$($node.Ip):$remoteArchive"
        Invoke-RemoteSudo -Ip $node.Ip -Command (
            "k3s ctr images import $remoteArchive"
        ) | Out-Null
    }

    foreach ($node in $nodes) {
        $images = Invoke-RemoteSudo -Ip $node.Ip -Command 'k3s ctr images list --quiet'
        if ($normalizedImage -notin $images) {
            throw "$normalizedImage was not found on $($node.Name)."
        }
        Write-Output "$($node.Name) image=$normalizedImage"
    }
} finally {
    foreach ($node in $nodes | Select-Object -Skip 1) {
        try {
            Invoke-Remote -Ip $node.Ip -Command "rm -f -- $remoteArchive" | Out-Null
        } catch {
            Write-Warning $_
        }
    }
    try {
        Invoke-RemoteSudo -Ip '172.16.8.50' -Command "rm -rf -- $remoteBuild" | Out-Null
        Invoke-RemoteSudo -Ip '172.16.8.50' -Command "rm -f -- $remoteArchive" | Out-Null
    } catch {
        Write-Warning $_
    }
    if ($dockerStarted) {
        try {
            Invoke-RemoteSudo -Ip '172.16.8.50' -Command (
                'systemctl stop docker.service docker.socket'
            ) | Out-Null
        } catch {
            Write-Warning $_
        }
    }
    if (Test-Path -LiteralPath $localArchive) {
        Remove-Item -LiteralPath $localArchive -Force
    }
    $plainPassword = $null
    $script:LiveScaleSudoPassword = $null
}
