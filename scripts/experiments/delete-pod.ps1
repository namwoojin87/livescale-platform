[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Kubeconfig,

    [ValidateRange(30, 300)]
    [int]$TimeoutSeconds = 120,

    [string]$OutputPath = 'work/results/self-healing.json'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kubeconfigPath = (Resolve-Path $Kubeconfig).Path
$kubectl = (Get-Command kubectl -ErrorAction Stop).Source
$selector = 'app.kubernetes.io/name=livescale-api'
$outputFullPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
New-Item -ItemType Directory -Path (Split-Path $outputFullPath -Parent) `
    -Force | Out-Null

function Invoke-Kubectl {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & $kubectl "--kubeconfig=$kubeconfigPath" @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl $($Arguments -join ' ') failed:`n$($output -join [Environment]::NewLine)"
    }
    return $output
}

function Get-KubernetesJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $json = Invoke-Kubectl -Arguments ($Arguments + @('-o', 'json'))
    return ($json -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
}

function Test-PodReady {
    param(
        [Parameter(Mandatory)]
        [object]$Pod
    )

    return (
        $Pod.status.phase -eq 'Running' -and
        @($Pod.status.containerStatuses | Where-Object ready).Count -eq 1
    )
}

$initialPods = Get-KubernetesJson -Arguments @(
    'get', 'pods', '-n', 'livescale', '-l', $selector
)
$readyInitialPods = @(
    $initialPods.items | Where-Object { Test-PodReady -Pod $_ }
)
if ($readyInitialPods.Count -ne 2) {
    throw "Expected exactly two Ready Pods before deletion, found $($readyInitialPods.Count)."
}

$initialUids = @($readyInitialPods.metadata.uid)
$deletedPod = $readyInitialPods | Sort-Object { $_.metadata.name } | Select-Object -First 1
$deletedAt = Get-Date

Invoke-Kubectl -Arguments @(
    'delete', 'pod', $deletedPod.metadata.name,
    '-n', 'livescale', '--wait=false'
) | Out-Null

$deadline = $deletedAt.AddSeconds($TimeoutSeconds)
$replacementPod = $null
$replacementObservedAt = $null
$recoveredAt = $null

do {
    $currentPods = Get-KubernetesJson -Arguments @(
        'get', 'pods', '-n', 'livescale', '-l', $selector
    )
    $newPods = @(
        $currentPods.items | Where-Object { $_.metadata.uid -notin $initialUids }
    )
    if ($newPods.Count -gt 0 -and $null -eq $replacementObservedAt) {
        $replacementObservedAt = Get-Date
    }

    $replacementPod = @(
        $newPods | Where-Object { Test-PodReady -Pod $_ }
    ) | Select-Object -First 1

    $deployment = Get-KubernetesJson -Arguments @(
        'get', 'deployment/livescale-api', '-n', 'livescale'
    )
    $desired = [int]$deployment.spec.replicas
    $available = if ($null -eq $deployment.status.availableReplicas) {
        0
    } else {
        [int]$deployment.status.availableReplicas
    }

    if ($null -ne $replacementPod -and $available -eq $desired) {
        $recoveredAt = Get-Date
        break
    }
    Start-Sleep -Seconds 1
} while ((Get-Date) -lt $deadline)

if ($null -eq $recoveredAt -or $null -eq $replacementPod) {
    throw "Deployment did not recover within $TimeoutSeconds seconds."
}

$result = [ordered]@{
    deleted_pod = [ordered]@{
        name = $deletedPod.metadata.name
        uid  = $deletedPod.metadata.uid
        node = $deletedPod.spec.nodeName
    }
    replacement_pod = [ordered]@{
        name = $replacementPod.metadata.name
        uid  = $replacementPod.metadata.uid
        node = $replacementPod.spec.nodeName
    }
    deleted_at             = $deletedAt.ToString('o')
    replacement_observed_at = $replacementObservedAt.ToString('o')
    recovered_at           = $recoveredAt.ToString('o')
    observed_seconds       = [Math]::Round(
        ($replacementObservedAt - $deletedAt).TotalSeconds,
        3
    )
    ready_seconds          = [Math]::Round(
        ($recoveredAt - $deletedAt).TotalSeconds,
        3
    )
    desired_replicas       = $desired
    available_replicas     = $available
}

$result | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath $outputFullPath -Encoding utf8

Write-Output "deleted=$($deletedPod.metadata.name) node=$($deletedPod.spec.nodeName)"
Write-Output "replacement=$($replacementPod.metadata.name) node=$($replacementPod.spec.nodeName)"
Write-Output "replacement_observed_seconds=$($result.observed_seconds)"
Write-Output "deployment_recovered_seconds=$($result.ready_seconds)"
Write-Output "replicas=$available/$desired"
Write-Output "output=$outputFullPath"
