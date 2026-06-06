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
$DattoSiteVarName  = 'UniFiApiKey'   # Datto site or global variable name for the API key
$DattoNetworksVarName = 'UniFiNetworks' # Datto site variable: "HostID|SiteID,HostID2|SiteID2,..."
$UseTwoTierDeviceCheck = $true   # $false = always fetch full device detail

# --- Alert Thresholds ---
$ThresholdPacketLossWarnPct  = 50    # kept for future use
$ThresholdPacketLossCritPct  = 55
$ThresholdAvgLatencyMs       = 100
$ThresholdWanUptimeCritPct   = 99.0
$ThresholdWanUptimeWarnPct   = 99.9
$ThresholdTxRetryWarnPct     = 50    # TX retry rate — Warning
$ThresholdTxRetryCritPct     = 55    # TX retry rate — Critical

# --- API Base URL ---
$BaseUrl = 'https://api.ui.com/v1'

# ==============================================================================
# FUNCTIONS
# ==============================================================================

function Get-UniFiApiKey {
    if ($ApiKeySource -eq 'Script') {
        $key = $ScriptApiKey
    } else {
        # Try Datto site variable first, then global (machine-level) variable as fallback
        $key = [System.Environment]::GetEnvironmentVariable($DattoSiteVarName, 'Process')
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = [System.Environment]::GetEnvironmentVariable($DattoSiteVarName, 'Machine')
        }
    }
    if ([string]::IsNullOrWhiteSpace($key)) {
        throw "API key is empty. Set Datto site variable '$DattoSiteVarName' (or a global/account-level variable with the same name), or set `$ApiKeySource = 'Script'` with `$ScriptApiKey."
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

    # Pre-fetch bulk device lists per unique hostId and cache them.
    # GET /v1/devices?hostIds[]=... is the only reliably working device endpoint
    # in the Site Manager API. For controllers with a single site we can attribute
    # all returned devices to that site. For shared controllers we skip the bulk
    # fallback (can't distinguish which device belongs to which site).
    $hostSiteCount = @{}
    foreach ($s in $Sites) { $hostSiteCount[$s.hostId] = ($hostSiteCount[$s.hostId] + 1) }

    $bulkDeviceCache = @{}
    foreach ($hostId in ($hostSiteCount.Keys | Where-Object { $hostSiteCount[$_] -eq 1 })) {
        $baseHostId = $hostId -replace ':.+$', ''
        try {
            $bulkDeviceCache[$hostId] = Get-AllPages -Uri "$BaseUrl/devices?hostIds[]=$baseHostId" -ApiKey $ApiKey
        } catch {
            $bulkDeviceCache[$hostId] = $null
        }
    }

    if ($TestMode) {
        Write-Host "`n=== DEVICE CHECK ==="
    }

    foreach ($site in $Sites) {
        $siteId   = $site.siteId
        $hostId   = $site.hostId
        $siteName = $site.meta.name
        $counts   = $site.statistics.counts

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

        # Tier 2a — try per-site endpoint forms (may work in future API versions)
        $devices    = $null
        $baseHostId = $hostId -replace ':.+$', ''

        $endpointsToTry = @(
            "$BaseUrl/hosts/$baseHostId/sites/$siteId/devices",
            "$BaseUrl/sites/$siteId/devices"
        )

        foreach ($endpoint in $endpointsToTry) {
            try {
                $devices = Get-AllPages -Uri $endpoint -ApiKey $ApiKey
                if ($TestMode) { Write-Host "    OK (per-site): $endpoint" }
                break
            } catch {
                if ($TestMode) { Write-Host "    FAIL: $endpoint" }
            }
        }

        # Tier 2b — fall back to bulk host endpoint for single-site controllers
        if ($null -eq $devices -and $bulkDeviceCache.ContainsKey($hostId)) {
            $devices = $bulkDeviceCache[$hostId]
            if ($devices -and $TestMode) {
                Write-Host "    OK (bulk host fallback): $BaseUrl/devices?hostIds[]=$baseHostId"
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
            if ($hostSiteCount[$hostId] -gt 1) {
                Write-Host "  WARNING: Cannot retrieve per-device detail for '$siteName' — shared controller, bulk endpoint not usable."
            } else {
                Write-Host "  WARNING: Could not fetch devices for '$siteName' — using Tier 1 count only."
            }
            $deviceMap[$siteId] = 'ERROR'
        }
    }

    return $deviceMap
}

function Get-SiteWanMetrics {
    <#
    Extracts WAN and TX-retry metrics from the already-fetched sites data — no extra
    API call needed. Data comes from statistics.percentages and statistics.wans which
    are returned by GET /v1/sites.

    Skips sites where statistics is null (e.g. unmanaged/read-only sites) or where
    wans is empty (client sites on a shared controller without their own gateway).
    #>
    param([array] $Sites)

    $metricsMap = @{}

    foreach ($site in $Sites) {
        $siteId = $site.siteId
        $stats  = $site.statistics
        if ($null -eq $stats) { continue }

        $pct  = $stats.percentages
        $wans = $stats.wans

        # Skip sites with no WAN data (client sites on shared controllers)
        $hasWan = ($null -ne $wans -and ($wans.PSObject.Properties.Name | Where-Object { $_ -ne 'WAN2' -and $_ -ne 'WAN3' }).Count -gt 0)

        $txRetry    = if ($pct.txRetry)    { [Math]::Round([double]$pct.txRetry, 2) }    else { $null }
        $wanUptime  = if ($pct.wanUptime -ne $null) { [Math]::Round([double]$pct.wanUptime, 3) } else { $null }
        $ispName    = $stats.ispInfo.name

        # Per-WAN uptime (primary WAN only — WAN2/WAN3 being 0 is normal for standby links)
        $primaryWanUptime = $null
        if ($hasWan -and $wans.WAN) {
            $primaryWanUptime = if ($wans.WAN.wanUptime -ne $null) { [Math]::Round([double]$wans.WAN.wanUptime, 3) } else { $null }
        }

        # Only include in map if we have at least some metric to evaluate
        if ($null -ne $txRetry -or $null -ne $primaryWanUptime) {
            $metricsMap[$siteId] = @{
                TxRetryPct       = $txRetry
                WanUptimePct     = $primaryWanUptime   # primary WAN only
                OverallWanUptime = $wanUptime           # rolled-up (from percentages)
                IspName          = $ispName
                Wans             = $wans
            }
        }
    }

    if ($TestMode) {
        Write-Host "`n=== WAN / TX METRICS (from sites API) ==="
        foreach ($siteId in $metricsMap.Keys) {
            $m = $metricsMap[$siteId]
            Write-Host ("  siteId={0}  isp={1}  txRetry={2}%  wanUptime={3}%" -f
                $siteId, $m.IspName, $m.TxRetryPct, $m.WanUptimePct)
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
        # For unnamed (default) sites on a dedicated controller, use the controller name.
        # For unnamed sites on a shared controller, append "(unnamed site)" so it's clear
        # it's a client site and not the controller itself.
        $sitesOnThisHost = @($Sites | Where-Object { $_.hostId -eq $hostId })
        $displayName = if ($siteName -ne 'default') {
            $siteName
        } elseif ($sitesOnThisHost.Count -eq 1) {
            $hostName
        } else {
            "$hostName (unnamed site)"
        }

        $healthMap[$siteId] = @{
            SiteId           = $siteId
            SiteName         = $displayName
            HostId           = $hostId
            HostName         = $hostName
            HostConnected    = ($hostRecord.reportedState.state -eq 'connected')
            SiteCounts       = $site.statistics.counts
            Devices          = $allDevices
            OfflineDevices   = $offlineDevices
            WanMetrics       = $MetricsMap[$siteId]
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

        # WAN / TX Metrics (sourced from sites API — no separate call needed)
        $wan = $site.WanMetrics
        if ($wan) {
            $ispStr = if ($wan.IspName) { " via $($wan.IspName)" } else { '' }

            # WAN Uptime (primary WAN only; WAN2/WAN3 = 0 is normal for standby/failover links)
            $wanUp = $wan.WanUptimePct
            if ($null -ne $wanUp) {
                if ($wanUp -lt $ThresholdWanUptimeCritPct) {
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
ISSUE:      Primary WAN uptime $wanUp%$ispStr.
            Threshold: $ThresholdWanUptimeCritPct%. The WAN connection has been dropping.
            Users are likely experiencing internet outages.

REMEDIATION:
  1. Check the ISP status page for reported outages$ispStr.
  2. Reboot the ISP router/modem if accessible.
  3. Log into the gateway and check the WAN interface for link drops or errors.
  4. Raise a fault with the ISP if drops continue — reference the uptime percentage above.
"@
                    }
                } elseif ($wanUp -lt $ThresholdWanUptimeWarnPct) {
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
ISSUE:      Primary WAN uptime $wanUp%$ispStr.
            Threshold: $ThresholdWanUptimeWarnPct%. The WAN link has experienced brief drops.

REMEDIATION:
  1. Monitor — if uptime drops below $ThresholdWanUptimeCritPct%, escalate to Critical.
  2. Check the ISP status page for reported issues$ispStr.
  3. Log into the gateway and review WAN interface event logs.
"@
                    }
                }
            }

            # TX Retry Rate — high values indicate RF interference or poor wireless conditions
            $txRetry = $wan.TxRetryPct
            if ($null -ne $txRetry) {
                if ($txRetry -gt $ThresholdTxRetryCritPct) {
                    $alerts += [PSCustomObject]@{
                        SiteId      = $siteId
                        SiteName    = $site.SiteName
                        Severity    = 'Critical'
                        Category    = 'TxRetry'
                        DeviceName  = ''
                        DeviceMac   = ''
                        DeviceModel = ''
                        Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      TX retry rate $txRetry% (threshold: $ThresholdTxRetryCritPct%).
            High retry rates indicate significant RF interference, channel congestion,
            or failing wireless hardware. Wireless clients will experience poor performance.

REMEDIATION:
  1. Log into UniFi ($($site.HostName)) and review the RF environment (channel utilisation).
  2. Check for neighbouring networks on the same channel — adjust channel/width settings.
  3. Look for physical obstructions or new interference sources near APs.
  4. Check AP hardware — a failing radio can cause elevated retries.
  5. Consider enabling auto-channel if not already active.
"@
                    }
                } elseif ($txRetry -gt $ThresholdTxRetryWarnPct) {
                    $alerts += [PSCustomObject]@{
                        SiteId      = $siteId
                        SiteName    = $site.SiteName
                        Severity    = 'Warning'
                        Category    = 'TxRetry'
                        DeviceName  = ''
                        DeviceMac   = ''
                        DeviceModel = ''
                        Detail      = @"
SITE:       $($site.SiteName)
SEVERITY:   Warning
DETECTED:   $detectedAt
ISSUE:      TX retry rate $txRetry% (threshold: $ThresholdTxRetryWarnPct%).
            Elevated retries may indicate RF interference or channel congestion.
            Wireless performance may be degraded.

REMEDIATION:
  1. Monitor — if retry rate exceeds $ThresholdTxRetryCritPct%, escalate to Critical.
  2. Log into UniFi ($($site.HostName)) and review the RF environment.
  3. Check for neighbouring networks on the same channel.
"@
                    }
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

function Get-ProactiveSiteFilter {
    <#
    Reads the Datto site variable $DattoNetworksVarName (e.g. "UniFiNetworks") which
    contains a comma-separated list of "HostID|SiteID" pairs, and returns a hashtable
    keyed by hostId with a list of allowed siteIds.

    Returns $null if the variable is not set (caller interprets as "no filter").
    #>
    $raw = [System.Environment]::GetEnvironmentVariable($DattoNetworksVarName, 'Process')
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }

    $filter = @{}
    foreach ($entry in ($raw -split ',')) {
        $entry = $entry.Trim()
        if (-not $entry.Contains('|')) { continue }
        $parts  = $entry -split '\|', 2
        $hostId = $parts[0].Trim()
        $siteId = $parts[1].Trim()
        if (-not $filter.ContainsKey($hostId)) { $filter[$hostId] = [System.Collections.Generic.List[string]]::new() }
        $filter[$hostId].Add($siteId)
    }

    if ($filter.Count -eq 0) { return $null }
    return $filter
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
        $c     = $s.statistics.counts
        $label = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
        Write-Host ("  {0,-35} total={1}  offline={2}  gw_offline={3}  ap_offline={4}  sw_offline={5}" -f
            $label, $c.totalDevice, $c.offlineDevice, $c.offlineGatewayDevice, $c.offlineWifiDevice, $c.offlineWiredDevice)
    }

    Write-Host "`n--- Section 4: Tier 2 Device Call Decisions ---"
    foreach ($s in $Sites) {
        $d     = $DeviceMap[$s.siteId]
        $label = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
        if ($null -eq $d) {
            Write-Host "  SKIPPED   $label (passed Tier 1 clean)"
        } elseif ($d -eq 'ERROR') {
            Write-Host "  ERROR     $label (device fetch failed)"
        } else {
            Write-Host "  FETCHED   $label ($($d.Count) device(s))"
        }
    }

    Write-Host "`n--- Section 5: Full Device List (Tier 2 sites) ---"
    foreach ($s in $Sites) {
        $d     = $DeviceMap[$s.siteId]
        $label = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
        if ($d -and $d -ne 'ERROR') {
            Write-Host "  ${label}:"
            foreach ($dev in $d) {
                Write-Host ("    [{0,-7}] {1} ({2}) mac={3}" -f $dev.status, $dev.name, $dev.model, $dev.mac)
            }
        }
    }

    Write-Host "`n--- Section 6: WAN / TX Metrics (from sites API) ---"
    if ($MetricsMap.Count -eq 0) {
        Write-Host "  No WAN metrics available (sites may have no gateway or statistics)."
    }
    foreach ($siteId in $MetricsMap.Keys) {
        $m = $MetricsMap[$siteId]
        $s = $Sites | Where-Object { $_.siteId -eq $siteId }
        $lbl = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
        Write-Host ("  {0,-35} isp={1,-22} wanUptime={2}%  txRetry={3}%" -f
            $lbl, $m.IspName, $m.WanUptimePct, $m.TxRetryPct)
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
        $apiKey = Get-UniFiApiKey
        $hosts  = Get-UniFiHosts -ApiKey $apiKey
        $sites  = Get-UniFiSites -ApiKey $apiKey

        # --- Proactive customer filtering (production mode only) ---
        # When $TestMode = $false, read the Datto site variable $DattoNetworksVarName
        # (e.g. "UniFiNetworks" = "HostID|SiteID,HostID2|SiteID2,...") and restrict
        # monitoring to only the listed host/site pairs for this customer.
        $siteFilter = $null
        if (-not $TestMode) {
            $siteFilter = Get-ProactiveSiteFilter
            if ($null -ne $siteFilter) {
                $before = $sites.Count
                $sites  = @($sites | Where-Object {
                    $sid = $_.siteId
                    $hid = $_.hostId
                    # Match by exact siteId; hostId in the filter is the base part before ':'
                    $baseHid = $hid -replace ':.+$', ''
                    $matched = $false
                    foreach ($fhid in $siteFilter.Keys) {
                        $fbaseHid = $fhid -replace ':.+$', ''
                        if ($fbaseHid -eq $baseHid -or $fhid -eq $hid) {
                            if ($siteFilter[$fhid] -contains $sid) { $matched = $true; break }
                        }
                    }
                    $matched
                })
                Write-Host "Proactive filter applied: monitoring $($sites.Count) of $before site(s) from variable '$DattoNetworksVarName'."
            }
        } elseif ($TestMode) {
            # Show what filter would do in test mode (informational only — all sites still checked)
            $testFilter = Get-ProactiveSiteFilter
            if ($null -ne $testFilter) {
                $wouldMonitor = @($sites | Where-Object {
                    $sid     = $_.siteId
                    $hid     = $_.hostId
                    $baseHid = $hid -replace ':.+$', ''
                    $matched = $false
                    foreach ($fhid in $testFilter.Keys) {
                        $fbaseHid = $fhid -replace ':.+$', ''
                        if ($fbaseHid -eq $baseHid -or $fhid -eq $hid) {
                            if ($testFilter[$fhid] -contains $sid) { $matched = $true; break }
                        }
                    }
                    $matched
                })
                Write-Host "`n[TEST MODE] '$DattoNetworksVarName' variable is set — in production, only $($wouldMonitor.Count) of $($sites.Count) site(s) would be monitored."
                foreach ($s in $wouldMonitor) {
                    $lbl = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
                    Write-Host "  -> $lbl (hostId=$($s.hostId)  siteId=$($s.siteId))"
                }
            }
        }

        $deviceMap   = Get-UniFiDevices      -Sites $sites -ApiKey $apiKey
        $metricsMap  = Get-SiteWanMetrics    -Sites $sites
        $healthMap   = Build-SiteHealthMap   -Hosts $hosts -Sites $sites -DeviceMap $deviceMap -MetricsMap $metricsMap
        $rawAlerts   = Evaluate-Alerts       -HealthMap $healthMap
        $finalAlerts = Merge-Alerts          -Alerts $rawAlerts

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
