[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Kubeconfig,

    [ValidateRange(60, 900)]
    [int]$DurationSeconds = 480,

    [ValidateRange(2, 30)]
    [int]$IntervalSeconds = 5,

    [string]$OutputPath = 'work/results/hpa-observations.csv'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$kubeconfigPath = (Resolve-Path $Kubeconfig).Path
$kubectl = (Get-Command kubectl -ErrorAction Stop).Source
$outputFullPath = [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
$outputDirectory = Split-Path $outputFullPath -Parent
New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null

function Get-KubernetesJson {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    $output = & $kubectl "--kubeconfig=$kubeconfigPath" @Arguments -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "kubectl failed: $($output -join [Environment]::NewLine)"
    }
    return ($output -join [Environment]::NewLine) | ConvertFrom-Json -Depth 100
}

$startedAt = Get-Date
$deadline = $startedAt.AddSeconds($DurationSeconds)
$samples = [Collections.Generic.List[object]]::new()
$scaleOutAt = $null
$scaleInAt = $null
$peakReplicas = 0

while ((Get-Date) -lt $deadline) {
    $hpa = Get-KubernetesJson -Arguments @('get', 'hpa/livescale-api', '-n', 'livescale')
    $pods = Get-KubernetesJson -Arguments @(
        'get', 'pods', '-n', 'livescale',
        '-l', 'app.kubernetes.io/name=livescale-api'
    )

    $currentCpu = $null
    if ($null -ne $hpa.status.currentMetrics) {
        $metric = @(
            $hpa.status.currentMetrics | Where-Object type -eq 'Resource'
        ) | Select-Object -First 1
        if ($null -ne $metric) {
            $currentCpu = $metric.resource.current.averageUtilization
        }
    }

    $readyPods = @(
        $pods.items | Where-Object {
            $_.status.phase -eq 'Running' -and
            @($_.status.containerStatuses | Where-Object ready).Count -eq 1
        }
    ).Count
    $currentReplicas = [int]$hpa.status.currentReplicas
    $desiredReplicas = [int]$hpa.status.desiredReplicas
    $peakReplicas = [Math]::Max($peakReplicas, $desiredReplicas)

    $sample = [pscustomobject]@{
        timestamp        = (Get-Date).ToString('o')
        elapsed_seconds  = [Math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        cpu_percent      = $currentCpu
        current_replicas = $currentReplicas
        desired_replicas = $desiredReplicas
        ready_pods       = $readyPods
    }
    $samples.Add($sample)
    Write-Output (
        "t={0,6}s cpu={1,4}% current={2} desired={3} ready={4}" -f
        $sample.elapsed_seconds, $currentCpu, $currentReplicas,
        $desiredReplicas, $readyPods
    )

    if ($desiredReplicas -gt 2 -and $null -eq $scaleOutAt) {
        $scaleOutAt = Get-Date
        Write-Output "scale_out_detected=$($scaleOutAt.ToString('o'))"
    }
    if ($null -ne $scaleOutAt -and $desiredReplicas -eq 2 -and $null -eq $scaleInAt) {
        $scaleInAt = Get-Date
        Write-Output "scale_in_detected=$($scaleInAt.ToString('o'))"
    }

    Start-Sleep -Seconds $IntervalSeconds
}

$samples | Export-Csv -LiteralPath $outputFullPath -NoTypeInformation -Encoding utf8
Write-Output "observations=$($samples.Count) peak_replicas=$peakReplicas"
Write-Output "output=$outputFullPath"

if ($peakReplicas -le 2) {
    throw 'HPA never scaled above two replicas.'
}
