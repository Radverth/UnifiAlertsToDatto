#Requires -Version 5.1
<#
.SYNOPSIS
    UniFi Health Monitor for Datto RMM — polls all managed UniFi sites via
    the Site Manager API and writes structured alerts into the Datto RMM
    monitoring pipeline.

.NOTES
    Affinity IT · Internal Technical Documentation · June 2026 · v3
    Firmware monitoring intentionally excluded (auto-updates enabled on all sites).
#>

# ==============================================================================
# CONFIGURATION — edit these variables before deployment
# ==============================================================================

# --- Mode & API Key ---
$TestMode          = $true       # $true = terminal output, no Datto markers, no exit
$MergeAlerts       = $true       # $true = one alert per site; $false = one per device
$ApiKeySource      = 'SiteVar'   # 'SiteVar' = $env:UniFiApiKey | 'Script' = $ScriptApiKey
$ScriptApiKey      = ''          # Local testing only — never deploy with a value here
$DattoSiteVarName  = 'UniFiApiKey'
$UseTwoTierDeviceCheck = $true   # $false = always fetch full device detail

# --- Alert Thresholds ---
$ThresholdPacketLossWarnPct  = 50
$ThresholdPacketLossCritPct  = 55
$ThresholdAvgLatencyMs       = 100
$ThresholdWanUptimeCritPct   = 99.0
$ThresholdWanUptimeWarnPct   = 99.9
$IspMetricsWindowMinutes     = 30   # Min 5, max 1440

# --- API Base URLs ---
$BaseUrl        = 'https://api.ui.com/v1'
$IspMetricsUrl  = 'https://api.ui.com/ea/isp-metrics/5m/query'

# ==============================================================================
# FUNCTIONS
# ==============================================================================

function Get-UniFiApiKey {
    if ($ApiKeySource -eq 'Script') {
        $key = $ScriptApiKey
    } else {
        $key = [System.Environment]::GetEnvironmentVariable($DattoSiteVarName, 'Process')
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "API key is empty. Source='$ApiKeySource'. Ensure the Datto site variable '$DattoSiteVarName' is configured."
    }
    return $key
}

function Invoke-UniFiApi {
    param(
        [string] $Method = 'GET',
        [string] $Uri,
        [object] $Body = $null,
        [string] $ApiKey,
        [switch] $Raw   # Return full response envelope instead of just .data
    )

    $headers = @{
        'X-API-Key' = $ApiKey
        'Accept'    = 'application/json'
    }

    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $headers
        ErrorAction = 'Stop'
    }

    if ($Body) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params['ContentType'] = 'application/json'
    }

    $attempt = 0
    while ($attempt -lt 2) {
        try {
            $response = Invoke-RestMethod @params
            if ($Raw) { return $response } else { return $response.data }
        } catch {
            # Resolve HTTP status code — works on both WinPS 5.1 (WebException) and PS 7+ (HttpResponseException)
            $statusCode = 0
            if ($_.Exception.Response -ne $null) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } elseif ($_.Exception -is [System.Net.Http.HttpRequestException] -and $_.Exception.StatusCode) {
                $statusCode = [int]$_.Exception.StatusCode
            }

            if ($statusCode -eq 429) {
                if ($attempt -eq 0) {
                    $retryAfter = 60
                    try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
                    Write-Host "Rate limit hit. Sleeping $retryAfter seconds before retry."
                    Start-Sleep -Seconds $retryAfter
                    $attempt++
                    continue
                }
                throw "API rate limit exceeded after retry."
            }

            if ($statusCode -eq 401) {
                throw "Invalid API key — check Datto site variable '$DattoSiteVarName'."
            }

            if ($statusCode -eq 502 -and $Uri -like '*/isp-metrics/*') {
                Write-Host "WARNING: ISP metrics returned 502 for URI: $Uri — skipping ISP data for affected sites."
                return $null
            }

            # Attempt to extract traceId from response body
            $traceId = ''
            try {
                $stream   = $_.Exception.Response.GetResponseStream()
                $reader   = New-Object System.IO.StreamReader($stream)
                $bodyText = $reader.ReadToEnd()
                $traceId  = ($bodyText | ConvertFrom-Json).traceId
            } catch {}

            if ($statusCode -gt 0) {
                throw "HTTP $statusCode from $Uri (traceId: $traceId): $($_.Exception.Message)"
            } else {
                throw "Request failed for $Uri : $($_.Exception.Message)"
            }
        }
    }
}

function Get-AllPages {
    param(
        [string] $Uri,
        [string] $ApiKey
    )

    $results   = @()
    $nextToken = $null

    do {
        $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
        $pageUri   = "$Uri${separator}pageSize=200"
        if ($nextToken) { $pageUri += "&nextToken=$nextToken" }

        $raw = Invoke-UniFiApi -Uri $pageUri -ApiKey $ApiKey -Raw
        if ($raw.data) { $results += $raw.data }
        $nextToken = $raw.nextToken
    } while (-not [string]::IsNullOrWhiteSpace($nextToken))

    return $results
}

function Get-UniFiHosts {
    param([string] $ApiKey)

    $hosts = Get-AllPages -Uri "$BaseUrl/hosts" -ApiKey $ApiKey

    if ($TestMode) {
        Write-Host "`n=== HOSTS ($($hosts.Count)) ==="
        foreach ($h in $hosts) {
            $state = $h.reportedState.state
            $name  = $h.reportedState.name
            Write-Host "  [$state] $name  (id=$($h.id)  type=$($h.type)  ip=$($h.ipAddress))"
        }
    }

    return $hosts
}

function Get-UniFiSites {
    param([string] $ApiKey)

    $sites = Get-AllPages -Uri "$BaseUrl/sites" -ApiKey $ApiKey

    if ($TestMode) {
        Write-Host "`n=== SITES ($($sites.Count)) ==="
        foreach ($s in $sites) {
            $counts    = $s.statistics.counts
            $label     = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
            Write-Host ("  [{0}]  hostId={1}  total={2}  offline={3}  gw_offline={4}" -f
                $label, $s.hostId,
                $counts.totalDevice, $counts.offlineDevice, $counts.offlineGatewayDevice)
        }
    }

    return $sites
}

function Get-UniFiDevices {
    param(
        [array]  $Sites,
        [string] $ApiKey
    )

    $deviceMap = @{}

    if ($TestMode) {
        Write-Host "`n=== DEVICE CHECK ==="
    }

    foreach ($site in $Sites) {
        $siteId  = $site.siteId
        $hostId  = $site.hostId
        $siteName = $site.meta.name
        $counts  = $site.statistics.counts

        # Tier 1 — fast check using site counts (treat null as 0 for sites with missing statistics)
        if ($UseTwoTierDeviceCheck -and [int]($counts.offlineDevice) -eq 0) {
            if ($TestMode) {
                Write-Host "  PASS (Tier 1) $siteName — 0 offline devices, skipping device call."
            }
            $deviceMap[$siteId] = $null
            continue
        }

        if ($TestMode) {
            Write-Host "  FETCH (Tier 2) $siteName — $($counts.offlineDevice) offline, fetching devices..."
        }

        # Tier 2 — per-site device call, trying multiple endpoint forms
        $devices = $null
        $baseHostId = $hostId -replace ':.+$', ''   # strip :port suffix

        $endpointsToTry = @(
            "$BaseUrl/hosts/$baseHostId/sites/$siteId/devices",
            "$BaseUrl/hosts/$hostId/sites/$siteId/devices",
            "$BaseUrl/sites/$siteId/devices"
        )

        foreach ($endpoint in $endpointsToTry) {
            try {
                $devices = Get-AllPages -Uri $endpoint -ApiKey $ApiKey
                if ($TestMode) { Write-Host "    OK: $endpoint" }
                break
            } catch {
                if ($TestMode) { Write-Host "    FAIL ($([int]$_.Exception.Response.StatusCode)): $endpoint" }
            }
        }

        if ($null -ne $devices) {
            $deviceMap[$siteId] = $devices
            if ($TestMode) {
                foreach ($d in $devices) {
                    Write-Host ("    [{0}] {1} ({2}) mac={3}" -f $d.status, $d.name, $d.model, $d.mac)
                }
            }
        } else {
            Write-Host "  WARNING: All device endpoints returned 404 for site '$siteName' — using Tier 1 count only."
            $deviceMap[$siteId] = 'ERROR'
        }
    }

    return $deviceMap
}

function Get-IspMetrics {
    param(
        [array]  $Sites,
        [string] $ApiKey
    )

    $endTime   = [datetime]::UtcNow
    $beginTime = $endTime.AddMinutes(-[Math]::Max(5, [Math]::Min(1440, $IspMetricsWindowMinutes)))

    $siteRequests = $Sites | ForEach-Object {
        @{
            hostId         = $_.hostId
            siteId         = $_.siteId
            beginTimestamp = $beginTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
            endTimestamp   = $endTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }

    $body = @{ sites = $siteRequests }

    $headers = @{
        'X-API-Key'    = $ApiKey
        'Accept'       = 'application/json'
        'Content-Type' = 'application/json'
    }

    $metricsMap = @{}

    try {
        $raw      = Invoke-RestMethod -Method POST -Uri $IspMetricsUrl -Headers $headers `
                        -Body ($body | ConvertTo-Json -Depth 10 -Compress) -ErrorAction Stop
        $rawData  = $raw.data
    } catch [System.Net.WebException] {
        $statusCode = [int]$_.Exception.Response.StatusCode
        if ($statusCode -eq 502) {
            Write-Host "WARNING: ISP metrics endpoint returned 502 — no ISP data will be included."
            return $metricsMap
        }
        Write-Host "WARNING: ISP metrics request failed ($statusCode): $_"
        return $metricsMap
    } catch {
        Write-Host "WARNING: ISP metrics request failed: $_"
        return $metricsMap
    }

    # Group and average buckets per siteId
    foreach ($siteEntry in $rawData) {
        $siteId  = $siteEntry.siteId
        $buckets = $siteEntry.metrics

        if (-not $buckets -or $buckets.Count -eq 0) {
            continue
        }

        $avgLatency  = ($buckets | Measure-Object { $_.wan.avgLatency }  -Average).Average
        $maxLatency  = ($buckets | Measure-Object { $_.wan.maxLatency }  -Maximum).Maximum
        $packetLoss  = ($buckets | Measure-Object { $_.wan.packetLoss }  -Average).Average
        $downKbps    = ($buckets | Measure-Object { $_.wan.download_kbps } -Average).Average
        $upKbps      = ($buckets | Measure-Object { $_.wan.upload_kbps }   -Average).Average
        $uptimePct   = ($buckets | Measure-Object { $_.wan.uptime }       -Average).Average
        $ispName     = $buckets[-1].wan.ispName

        $metricsMap[$siteId] = @{
            AvgLatency  = [Math]::Round($avgLatency, 1)
            MaxLatency  = [Math]::Round($maxLatency, 1)
            PacketLoss  = [Math]::Round($packetLoss, 2)
            DownKbps    = [Math]::Round($downKbps, 0)
            UpKbps      = [Math]::Round($upKbps, 0)
            UptimePct   = [Math]::Round($uptimePct, 3)
            IspName     = $ispName
        }
    }

    if ($TestMode) {
        Write-Host "`n=== ISP METRICS ==="
        foreach ($siteId in $metricsMap.Keys) {
            $m = $metricsMap[$siteId]
            Write-Host ("  siteId={0}  isp={1}  latency={2}ms  loss={3}%  uptime={4}%  dl={5}kbps  ul={6}kbps" -f
                $siteId, $m.IspName, $m.AvgLatency, $m.PacketLoss, $m.UptimePct, $m.DownKbps, $m.UpKbps)
        }
    }

    return $metricsMap
}

function Build-SiteHealthMap {
    param(
        [array]     $Hosts,
        [array]     $Sites,
        [hashtable] $DeviceMap,
        [hashtable] $MetricsMap
    )

    # Build a lookup of host connectivity by hostId
    $hostLookup = @{}
    foreach ($h in $Hosts) {
        $hostLookup[$h.id] = $h
    }

    $healthMap = @{}

    foreach ($site in $Sites) {
        $siteId   = $site.siteId
        $hostId   = $site.hostId
        $hostRecord = $hostLookup[$hostId]

        $allDevices     = $DeviceMap[$siteId]
        $offlineDevices = @()

        if ($allDevices -and $allDevices -ne 'ERROR') {
            $offlineDevices = @($allDevices | Where-Object { $_.status -ne 'online' })
        }

        $hostName  = $hostRecord.reportedState.name
        $siteName  = if (-not [string]::IsNullOrWhiteSpace($site.meta.desc)) { $site.meta.desc } else { $site.meta.name }
        # Use site desc/name directly; fall back to controller name only when site name is still generic
        $displayName = if ($siteName -eq 'default') { $hostName } else { $siteName }

        $healthMap[$siteId] = @{
            SiteId          = $siteId
            SiteName        = $displayName
            HostId          = $hostId
            HostName        = $hostName
            HostConnected   = ($hostRecord.reportedState.state -eq 'connected')
            SiteCounts      = $site.statistics.counts
            Devices         = $allDevices
            OfflineDevices  = $offlineDevices
            WanMetrics      = $MetricsMap[$siteId]
            DeviceFetchError = ($allDevices -eq 'ERROR')
        }
    }

    return $healthMap
}

function Evaluate-Alerts {
    param([hashtable] $HealthMap)

    $alerts = @()

    foreach ($siteId in $HealthMap.Keys) {
        $site = $HealthMap[$siteId]

        $detectedAt = (Get-Date).ToString('dd/MM/yyyy HH:mm')

        # Host / Controller Disconnected
        if (-not $site.HostConnected) {
            $alerts += [PSCustomObject]@{
                SiteId      = $siteId
                SiteName    = $site.SiteName
                Severity    = 'Critical'
                Category    = 'HostDisconnected'
                DeviceName  = $site.HostName
                DeviceMac   = ''
                DeviceModel = ''
                Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      UniFi controller '$($site.HostName)' has lost cloud connectivity.
            All devices at this site may be unmanageable until connectivity is restored.

REMEDIATION:
  1. Check whether the site has an active internet connection.
  2. Log into the UniFi console directly (if reachable on LAN) and check UniFi OS status.
  3. Verify the controller has not been rebooted or had its network settings changed.
  4. If the controller is a Cloud Key or UDM, check its power and physical connections.
  5. If the site internet is down, escalate to ISP before working on the controller.
"@
            }
        }

        # Offline Devices
        if ($site.DeviceFetchError) {
            $count = $site.SiteCounts.offlineDevice
            $gwOffline = [int]$site.SiteCounts.offlineGatewayDevice
            $apOffline = [int]$site.SiteCounts.offlineWifiDevice
            $swOffline = [int]$site.SiteCounts.offlineWiredDevice
            $breakdown = @()
            if ($gwOffline -gt 0) { $breakdown += "$gwOffline gateway" }
            if ($apOffline -gt 0) { $breakdown += "$apOffline access point(s)" }
            if ($swOffline -gt 0) { $breakdown += "$swOffline switch(es)" }
            $breakdownStr = if ($breakdown.Count -gt 0) { " ($($breakdown -join ', '))" } else { '' }

            $alerts += [PSCustomObject]@{
                SiteId      = $siteId
                SiteName    = $site.SiteName
                Severity    = 'Critical'
                Category    = 'DeviceOffline'
                DeviceName  = ''
                DeviceMac   = ''
                DeviceModel = ''
                Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      $count UniFi device(s) offline$breakdownStr.

REMEDIATION:
  1. Log into UniFi ($($site.HostName)) and identify the offline device(s).
  2. Check physical power and ethernet connections on the affected device(s).
  3. If a switch is offline, check upstream connectivity — APs on that switch will also appear offline.
  4. If the gateway is offline, the site may have no internet — check WAN connection first.
  5. Try a power cycle if the device is physically accessible.
  6. If the device does not recover, check for hardware fault indicators (LEDs).
"@
            }
        } else {
            foreach ($d in $site.OfflineDevices) {
                $deviceType = switch -Wildcard ($d.model) {
                    'USW*'   { 'Switch' }
                    'UAP*'   { 'Access Point' }
                    'U6*'    { 'Access Point' }
                    'UDM*'   { 'Gateway / Dream Machine' }
                    'UDR*'   { 'Gateway / Dream Router' }
                    'USG*'   { 'Gateway' }
                    'UXG*'   { 'Gateway' }
                    default  { 'UniFi Device' }
                }
                $gwNote = if ($d.isConsole -or $deviceType -like '*Gateway*') {
                    "`n            NOTE: This is the site gateway — the site may have no internet connectivity."
                } else { '' }

                $alerts += [PSCustomObject]@{
                    SiteId      = $siteId
                    SiteName    = $site.SiteName
                    Severity    = 'Critical'
                    Category    = 'DeviceOffline'
                    DeviceName  = $d.name
                    DeviceMac   = $d.mac
                    DeviceModel = $d.model
                    Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Critical
DETECTED:   $detectedAt
DEVICE:     $($d.name) ($deviceType)
MODEL:      $($d.model)
MAC:        $($d.mac)$gwNote

REMEDIATION:
  1. Check physical power and ethernet connections on $($d.name).
  2. Verify upstream network connectivity (the switch port / uplink it connects to).
  3. Try a power cycle if the device is physically accessible.
  4. Log into UniFi ($($site.HostName)) to check for any adoption or config errors.
  5. If the device does not recover after a power cycle, check for hardware fault indicators (LEDs).
"@
                }
            }
        }

        # ISP / WAN Metrics
        $wan = $site.WanMetrics
        if ($wan) {
            $ispStr = if ($wan.IspName) { " via $($wan.IspName)" } else { '' }

            # Packet Loss
            if ($wan.PacketLoss -gt $ThresholdPacketLossCritPct) {
                $alerts += [PSCustomObject]@{
                    SiteId      = $siteId
                    SiteName    = $site.SiteName
                    Severity    = 'Critical'
                    Category    = 'ISPPacketLoss'
                    DeviceName  = ''
                    DeviceMac   = ''
                    DeviceModel = ''
                    Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      WAN packet loss $($wan.PacketLoss)%$ispStr (threshold: $ThresholdPacketLossCritPct%).
            Measured over the last $IspMetricsWindowMinutes minutes. Users are likely experiencing
            significant connectivity problems.

REMEDIATION:
  1. Check the ISP status page for reported outages$ispStr.
  2. Log into the gateway and check the WAN interface for errors or flapping.
  3. Reboot the ISP router/modem if accessible.
  4. If persistent, raise a fault with the ISP.
"@
                }
            } elseif ($wan.PacketLoss -gt $ThresholdPacketLossWarnPct) {
                $alerts += [PSCustomObject]@{
                    SiteId      = $siteId
                    SiteName    = $site.SiteName
                    Severity    = 'Warning'
                    Category    = 'ISPPacketLoss'
                    DeviceName  = ''
                    DeviceMac   = ''
                    DeviceModel = ''
                    Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Warning
DETECTED:   $detectedAt
ISSUE:      WAN packet loss $($wan.PacketLoss)%$ispStr (threshold: $ThresholdPacketLossWarnPct%).
            Measured over the last $IspMetricsWindowMinutes minutes. Users may notice intermittent
            connectivity issues.

REMEDIATION:
  1. Monitor — if loss increases above $ThresholdPacketLossCritPct%, escalate to Critical.
  2. Check the ISP status page for reported issues$ispStr.
  3. Log into the gateway and check the WAN interface for errors.
  4. If persistent over the next poll cycle, raise a fault with the ISP.
"@
                }
            }

            # Latency
            if ($wan.AvgLatency -gt $ThresholdAvgLatencyMs) {
                $alerts += [PSCustomObject]@{
                    SiteId      = $siteId
                    SiteName    = $site.SiteName
                    Severity    = 'Warning'
                    Category    = 'ISPLatency'
                    DeviceName  = ''
                    DeviceMac   = ''
                    DeviceModel = ''
                    Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Warning
DETECTED:   $detectedAt
ISSUE:      WAN average latency $($wan.AvgLatency)ms (peak $($wan.MaxLatency)ms)$ispStr.
            Threshold: $($ThresholdAvgLatencyMs)ms. Measured over the last $IspMetricsWindowMinutes minutes.
            Users may experience slow page loads, laggy video calls, or VoIP quality issues.

REMEDIATION:
  1. Check the ISP status page for reported issues$ispStr.
  2. Check for bandwidth saturation — high throughput can inflate latency.
  3. Log into the gateway and review WAN interface statistics.
  4. If persistent, raise a fault with the ISP referencing the latency figures above.
"@
                }
            }

            # WAN Uptime
            if ($wan.UptimePct -lt $ThresholdWanUptimeCritPct) {
                $alerts += [PSCustomObject]@{
                    SiteId      = $siteId
                    SiteName    = $site.SiteName
                    Severity    = 'Critical'
                    Category    = 'WANUptime'
                    DeviceName  = ''
                    DeviceMac   = ''
                    DeviceModel = ''
                    Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      WAN uptime $($wan.UptimePct)%$ispStr in the last $IspMetricsWindowMinutes minutes.
            Threshold: $ThresholdWanUptimeCritPct%. The WAN connection has been dropping repeatedly.
            Users are likely experiencing internet outages.

REMEDIATION:
  1. Check the ISP status page for reported outages$ispStr.
  2. Reboot the ISP router/modem if accessible.
  3. Log into the gateway and check the WAN interface for link drops or errors.
  4. Raise a fault with the ISP if drops continue — reference the uptime percentage above.
"@
                }
            } elseif ($wan.UptimePct -lt $ThresholdWanUptimeWarnPct) {
                $alerts += [PSCustomObject]@{
                    SiteId      = $siteId
                    SiteName    = $site.SiteName
                    Severity    = 'Warning'
                    Category    = 'WANUptime'
                    DeviceName  = ''
                    DeviceMac   = ''
                    DeviceModel = ''
                    Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Warning
DETECTED:   $detectedAt
ISSUE:      WAN uptime $($wan.UptimePct)%$ispStr in the last $IspMetricsWindowMinutes minutes.
            Threshold: $ThresholdWanUptimeWarnPct%. The WAN link has experienced brief drops.

REMEDIATION:
  1. Monitor — if uptime drops below $ThresholdWanUptimeCritPct%, escalate to Critical.
  2. Check the ISP status page for reported issues$ispStr.
  3. Log into the gateway and review WAN interface event logs.
"@
                }
            }
        }
    }

    return $alerts
}

function Merge-Alerts {
    param([array] $Alerts)

    if (-not $MergeAlerts) { return $Alerts }

    $grouped = $Alerts | Group-Object -Property SiteId
    $merged  = @()

    foreach ($group in $grouped) {
        $items    = $group.Group
        $siteName = $items[0].SiteName
        $siteId   = $group.Name

        # Highest severity: Critical > Warning
        $severity = if ($items | Where-Object { $_.Severity -eq 'Critical' }) { 'Critical' } else { 'Warning' }

        $details  = ($items | ForEach-Object { $_.Detail }) -join "`n$('=' * 60)`n"

        $merged += [PSCustomObject]@{
            SiteId      = $siteId
            SiteName    = $siteName
            Severity    = $severity
            Category    = 'Merged'
            DeviceName  = ''
            DeviceMac   = ''
            DeviceModel = ''
            Detail      = $details
        }
    }

    return $merged
}

function Write-DattoOutput {
    param([array] $Alerts)

    Write-Host '<-Start Diagnostic->'

    if ($Alerts.Count -eq 0) {
        Write-Host 'All monitored UniFi sites are healthy.'
    } else {
        $critCount = ($Alerts | Where-Object { $_.Severity -eq 'Critical' }).Count
        $warnCount = ($Alerts | Where-Object { $_.Severity -eq 'Warning' }).Count
        Write-Host "UniFi Health Monitor — $($Alerts.Count) alert(s) detected: $critCount Critical, $warnCount Warning"
        Write-Host "Generated: $((Get-Date).ToString('dd/MM/yyyy HH:mm')) UTC"
        Write-Host ""
        $sep = '=' * 60
        foreach ($a in $Alerts) {
            Write-Host $sep
            Write-Host $a.Detail
        }
        Write-Host $sep
    }

    Write-Host '<-End Diagnostic->'
    Write-Host '<-Start Result->'

    if ($Alerts.Count -eq 0) {
        Write-Host 'Status=OK: All sites healthy'
        Write-Host '<-End Result->'
        exit 0
    } else {
        $critSites = ($Alerts | Where-Object { $_.Severity -eq 'Critical' } | Select-Object -ExpandProperty SiteName -Unique) -join ', '
        $warnSites = ($Alerts | Where-Object { $_.Severity -eq 'Warning'  } | Select-Object -ExpandProperty SiteName -Unique) -join ', '
        $summary   = @()
        if ($critSites) { $summary += "CRITICAL: $critSites" }
        if ($warnSites) { $summary += "WARNING: $warnSites" }
        Write-Host "Status=ALERT: $($summary -join '; ')"
        Write-Host '<-End Result->'
        exit 1
    }
}

function Write-TestOutput {
    param(
        [array]     $Hosts,
        [array]     $Sites,
        [hashtable] $DeviceMap,
        [hashtable] $MetricsMap,
        [hashtable] $HealthMap,
        [array]     $RawAlerts,
        [array]     $FinalAlerts
    )

    Write-Host "`n============================================================"
    Write-Host " UniFi Health Monitor — TEST MODE OUTPUT"
    Write-Host "============================================================"

    Write-Host "`n--- Section 1: API Connectivity ---"
    Write-Host "Authentication successful. $($Hosts.Count) controller(s) found."

    Write-Host "`n--- Section 2: Topology Map ---"
    $hostLookup = @{}
    foreach ($h in $Hosts) { $hostLookup[$h.id] = $h }
    foreach ($h in $Hosts) {
        $sitesOnHost = @($Sites | Where-Object { $_.hostId -eq $h.id })
        Write-Host "  Controller: $($h.reportedState.name) [$($h.reportedState.state)] — $($sitesOnHost.Count) site(s)"
        foreach ($s in $sitesOnHost) {
            $label = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
            Write-Host "    -> $label (siteId=$($s.siteId))"
        }
    }

    Write-Host "`n--- Section 3: Tier 1 Site Counts ---"
    foreach ($s in $Sites) {
        $c = $s.statistics.counts
        Write-Host ("  {0,-30} total={1}  offline={2}  gw_offline={3}  ap_offline={4}  sw_offline={5}" -f
            $s.meta.name, $c.totalDevice, $c.offlineDevice, $c.offlineGatewayDevice, $c.offlineWifiDevice, $c.offlineWiredDevice)
    }

    Write-Host "`n--- Section 4: Tier 2 Device Call Decisions ---"
    foreach ($s in $Sites) {
        $d = $DeviceMap[$s.siteId]
        if ($null -eq $d) {
            Write-Host "  SKIPPED   $($s.meta.name) (passed Tier 1 clean)"
        } elseif ($d -eq 'ERROR') {
            Write-Host "  ERROR     $($s.meta.name) (device fetch failed)"
        } else {
            Write-Host "  FETCHED   $($s.meta.name) ($($d.Count) device(s))"
        }
    }

    Write-Host "`n--- Section 5: Full Device List (Tier 2 sites) ---"
    foreach ($s in $Sites) {
        $d = $DeviceMap[$s.siteId]
        if ($d -and $d -ne 'ERROR') {
            Write-Host "  $($s.meta.name):"
            foreach ($dev in $d) {
                Write-Host ("    [{0,-7}] {1} ({2}) mac={3}" -f $dev.status, $dev.name, $dev.model, $dev.mac)
            }
        }
    }

    Write-Host "`n--- Section 6: ISP Metrics ---"
    if ($MetricsMap.Count -eq 0) {
        Write-Host "  No ISP metrics available."
    }
    foreach ($siteId in $MetricsMap.Keys) {
        $m = $MetricsMap[$siteId]
        $n = ($Sites | Where-Object { $_.siteId -eq $siteId }).meta.name
        Write-Host ("  {0,-30} isp={1}  latency={2}ms  loss={3}%  uptime={4}%  dl={5}kbps  ul={6}kbps" -f
            $n, $m.IspName, $m.AvgLatency, $m.PacketLoss, $m.UptimePct, $m.DownKbps, $m.UpKbps)
    }

    Write-Host "`n--- Section 7: Alerts Before Merge ---"
    if ($RawAlerts.Count -eq 0) {
        Write-Host "  No alerts."
    }
    foreach ($a in $RawAlerts) {
        Write-Host "  [$($a.Severity)] $($a.Category) @ $($a.SiteName)"
    }

    $sep = '=' * 60
    Write-Host "`n--- Section 8: Final Alerts (ticket preview) ---"
    if ($FinalAlerts.Count -eq 0) {
        Write-Host "  No alerts."
    }
    foreach ($a in $FinalAlerts) {
        Write-Host $sep
        Write-Host $a.Detail
    }
    if ($FinalAlerts.Count -gt 0) { Write-Host $sep }

    Write-Host "`n--- Section 9: Datto Status Line (preview) ---"
    if ($FinalAlerts.Count -eq 0) {
        Write-Host "  Status=OK: All sites healthy"
    } else {
        $critSites = ($FinalAlerts | Where-Object { $_.Severity -eq 'Critical' } | Select-Object -ExpandProperty SiteName -Unique) -join ', '
        $warnSites = ($FinalAlerts | Where-Object { $_.Severity -eq 'Warning'  } | Select-Object -ExpandProperty SiteName -Unique) -join ', '
        $summary   = @()
        if ($critSites) { $summary += "CRITICAL: $critSites" }
        if ($warnSites) { $summary += "WARNING: $warnSites" }
        Write-Host "  Status=ALERT: $($summary -join '; ')"
    }

    Write-Host "`n============================================================`n"
}

# ==============================================================================
# MAIN
# ==============================================================================

function Main {
    try {
        $apiKey    = Get-UniFiApiKey
        $hosts     = Get-UniFiHosts  -ApiKey $apiKey
        $sites     = Get-UniFiSites  -ApiKey $apiKey
        $deviceMap = Get-UniFiDevices -Sites $sites -ApiKey $apiKey
        $metricsMap = Get-IspMetrics  -Sites $sites -ApiKey $apiKey
        $healthMap = Build-SiteHealthMap -Hosts $hosts -Sites $sites -DeviceMap $deviceMap -MetricsMap $metricsMap
        $rawAlerts = Evaluate-Alerts -HealthMap $healthMap
        $finalAlerts = Merge-Alerts -Alerts $rawAlerts

        if ($TestMode) {
            Write-TestOutput `
                -Hosts       $hosts `
                -Sites       $sites `
                -DeviceMap   $deviceMap `
                -MetricsMap  $metricsMap `
                -HealthMap   $healthMap `
                -RawAlerts   $rawAlerts `
                -FinalAlerts $finalAlerts
        } else {
            Write-DattoOutput -Alerts $finalAlerts
        }

    } catch {
        $errMsg = $_.Exception.Message

        if ($TestMode) {
            Write-Host "ERROR: $errMsg"
        } else {
            Write-Host '<-Start Diagnostic->'
            Write-Host "ERROR: $errMsg"
            Write-Host '<-End Diagnostic->'
            Write-Host '<-Start Result->'
            Write-Host "Status=ERROR: $errMsg"
            Write-Host '<-End Result->'
            exit 1
        }
    }
}

Main
