[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Kubeconfig,

    [ValidateRange(30, 600)]
    [int]$TimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kubeconfigPath = (Resolve-Path $Kubeconfig).Path
$kubectl = (Get-Command kubectl -ErrorAction Stop).Source
$namespace = 'livescale'
$selector = 'app.kubernetes.io/name=livescale-api'

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

Invoke-Kubectl -Arguments @(
    'rollout', 'status', 'deployment/livescale-api',
    '-n', $namespace,
    "--timeout=${TimeoutSeconds}s"
) | Out-Null

$deployment = Get-KubernetesJson -Arguments @(
    'get', 'deployment/livescale-api', '-n', $namespace
)
if ($deployment.status.readyReplicas -ne $deployment.spec.replicas) {
    throw 'Deployment does not have all desired replicas Ready.'
}

$pods = Get-KubernetesJson -Arguments @(
    'get', 'pods', '-n', $namespace, '-l', $selector
)
$readyPods = @(
    $pods.items | Where-Object {
        $_.status.phase -eq 'Running' -and
        @($_.status.containerStatuses | Where-Object ready).Count -eq 1
    }
)
if ($readyPods.Count -lt 2) {
    throw "Expected at least two Ready API Pods, found $($readyPods.Count)."
}

$workerNodes = @($readyPods.spec.nodeName | Sort-Object -Unique)
if ($workerNodes -contains 'livescale-control') {
    throw 'An application Pod was scheduled on the control plane.'
}
if ($workerNodes.Count -lt 2) {
    throw 'Application Pods are not spread across both worker nodes.'
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$currentCpu = $null
do {
    $hpa = Get-KubernetesJson -Arguments @(
        'get', 'hpa/livescale-api', '-n', $namespace
    )
    $resourceMetric = $null
    if ($null -ne $hpa.status.currentMetrics) {
        $resourceMetric = @(
            $hpa.status.currentMetrics | Where-Object type -eq 'Resource'
        ) | Select-Object -First 1
    }
    if ($null -ne $resourceMetric) {
        $currentCpu = $resourceMetric.resource.current.averageUtilization
    }
    if ($null -eq $currentCpu) {
        Start-Sleep -Seconds 2
    }
} while ($null -eq $currentCpu -and (Get-Date) -lt $deadline)

if ($null -eq $currentCpu) {
    throw 'HPA CPU utilization remained unknown.'
}

$headers = @{ Host = 'livescale.local' }
$health = Invoke-RestMethod -Uri 'http://172.16.8.50/health' `
    -Headers $headers -TimeoutSec 10
$streams = Invoke-RestMethod -Uri 'http://172.16.8.50/streams' `
    -Headers $headers -TimeoutSec 10
$watch = Invoke-RestMethod -Uri 'http://172.16.8.50/streams/1/watch' `
    -Headers $headers -TimeoutSec 10

if ($health.status -ne 'live') {
    throw 'Health endpoint returned an unexpected payload.'
}
if (@($streams).Count -lt 2) {
    throw 'Streams endpoint returned fewer than two streams.'
}
if ($watch.stream_id -ne 1 -or -not $watch.served_by) {
    throw 'Watch endpoint returned an unexpected payload.'
}

Write-Output "rollout=ready replicas=$($deployment.status.readyReplicas)"
Write-Output "workers=$($workerNodes -join ',')"
Write-Output "hpa_cpu=$currentCpu%"
Write-Output "ingress_health=$($health.status) watch_served_by=$($watch.served_by)"
Write-Output 'smoke_verification=passed'
