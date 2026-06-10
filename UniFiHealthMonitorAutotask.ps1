#Requires -Version 5.1
<#
.SYNOPSIS
    UniFi Health Monitor for Autotask PSA — polls all managed UniFi sites via
    the Site Manager API and raises Autotask tickets through the Autotask
    REST API instead of Datto RMM alerts.

.DESCRIPTION
    Differences from UniFiHealthMonitor.ps1 (the Datto RMM alert version):
      - Alerts are converted into Autotask tickets via POST /V1.0/Tickets.
      - UniFi site names are mapped to Autotask company names via
        $CompanyNameMap (falls back to using the UniFi site name verbatim).
      - The company's primary contact (Contacts.isPrimaryContact = true) is
        attached to the ticket; if the company has no primary contact the
        contact field is left blank.
      - Queue, issue type and sub-issue type are mapped per alert category
        via $TicketCategoryMap; priority is mapped per severity via
        $TicketPriorityMap.
      - The alert title becomes the ticket title; the full alert body
        (site, device, severity, investigation and resolution steps)
        becomes the ticket description.

    Autotask REST API reference:
      - Auth: three HTTP headers — UserName, Secret, ApiIntegrationCode.
      - Zone:  GET https://webservices.autotask.net/ATServicesRest/V1.0/zoneInformation?user=<apiUser>
               returns the tenant-specific base URL (no auth required).
      - Create ticket: POST {zoneUrl}V1.0/Tickets
        Required fields: companyID, title (max 255), status, priority, dueDateTime.
        Optional fields used here: queueID, issueType, subIssueType, source,
        contactID, description (max 8000), ticketType.
      - Queries: POST {zoneUrl}V1.0/<Entity>/query with a JSON filter body,
        e.g. {"filter":[{"op":"eq","field":"companyName","value":"ACME"}]}.
      - Picklist values (status, priority, queue, issue types, source) are
        instance-specific — set $ShowPicklists = $true in test mode to dump
        the valid values for your Autotask instance.

.NOTES
    Affinity IT · Internal Technical Documentation · June 2026 · v1
    Firmware monitoring intentionally excluded (auto-updates enabled on all sites).
#>

# ==============================================================================
# CONFIGURATION — edit these variables before deployment
# ==============================================================================

# --- Mode & UniFi API Key ---
$TestMode          = $true       # $true = terminal output, no tickets created, no exit
$MergeAlerts       = $true       # $true = one ticket per site; $false = one per alert
$ApiKeySource      = 'SiteVar'   # 'SiteVar' = $env:UniFiApiKey | 'Script' = $ScriptApiKey
$ScriptApiKey      = ''          # Local testing only — never deploy with a value here
$DattoSiteVarName  = 'UniFiApiKey'   # Datto site or global variable name for the UniFi API key
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

# --- UniFi API Base URL ---
$BaseUrl = 'https://api.ui.com/v1'

# ==============================================================================
# AUTOTASK CONFIGURATION
# ==============================================================================

# --- Credentials ---
# 'SiteVar' reads the three values below from Datto site/global variables
# (environment variables at runtime). 'Script' uses the inline values —
# local testing only, never deploy with secrets in the script body.
$AutotaskCredSource           = 'SiteVar'
$AutotaskUserVarName          = 'AutotaskApiUser'            # API user email, e.g. abcdef@yourdomain.co.uk
$AutotaskSecretVarName        = 'AutotaskApiSecret'          # API user password/secret
$AutotaskIntegrationVarName   = 'AutotaskApiIntegrationCode' # API tracking identifier
$AutotaskScriptUser           = ''
$AutotaskScriptSecret         = ''
$AutotaskScriptIntegrationCode = ''

# Leave blank to auto-resolve via the zoneInformation endpoint. Set explicitly
# (e.g. 'https://webservices16.autotask.net/ATServicesRest/') to skip the lookup.
$AutotaskBaseUrlOverride      = ''

# --- Company Mapping ---
# Map UniFi site display names to Autotask company names. Any site not listed
# here is looked up in Autotask using its UniFi site name verbatim.
# Keys are the resolved UniFi site name (site description, or the controller
# name for unnamed sites on a dedicated controller).
$CompanyNameMap = @{
    # 'Acme Head Office (UniFi)' = 'Acme Widgets Ltd'
    # 'Smiths Warehouse'         = 'Smith & Sons'
}

# When a company cannot be resolved: if $FallbackCompanyID is set (0 = your
# own MSP account in Autotask), the ticket is raised against it with a note
# in the description; if $null, the alert is skipped with an error logged.
$FallbackCompanyID = 0

# --- Ticket Field Mapping ---
# All values below are Autotask picklist integers and are INSTANCE-SPECIFIC.
# Run once with $TestMode = $true and $ShowPicklists = $true to print the
# valid values for your Autotask instance, then fill these in.

# Severity -> Autotask priority picklist value
$TicketPriorityMap = @{
    'Critical' = 1       # e.g. 1 = Critical
    'Warning'  = 2       # e.g. 2 = High
}

# Alert category -> queue / issue type / sub-issue type picklist values.
# 'Merged' is used when $MergeAlerts = $true (one combined ticket per site).
# Leave a value $null to omit that field from the ticket (Autotask will apply
# its own defaults / workflow rules).
$TicketCategoryMap = @{
    'HostDisconnected' = @{ QueueID = $null; IssueType = $null; SubIssueType = $null }
    'DeviceOffline'    = @{ QueueID = $null; IssueType = $null; SubIssueType = $null }
    'WANUptime'        = @{ QueueID = $null; IssueType = $null; SubIssueType = $null }
    'TxRetry'          = @{ QueueID = $null; IssueType = $null; SubIssueType = $null }
    'Merged'           = @{ QueueID = $null; IssueType = $null; SubIssueType = $null }
}

$TicketStatusNew   = 1           # Status for new tickets (1 = New in a default instance)
$TicketSource      = $null       # Optional source picklist (e.g. 8 = Monitoring Alert); $null = omit
$TicketDueHours    = 24          # dueDateTime = now + this many hours (dueDateTime is required by the API)

# Duplicate suppression: before creating, query Autotask for an open ticket
# with the same title against the same company and skip if one exists.
# Prevents a new ticket every poll cycle while a fault is ongoing.
$SkipIfOpenDuplicate    = $true
$TicketCompleteStatusId = 5      # Status regarded as closed (5 = Complete in a default instance)

# Test-mode helpers
$ShowPicklists       = $false    # Dump ticket picklist values (test mode only)
$TestResolveAutotask = $true     # In test mode, also resolve companies/contacts read-only

# ==============================================================================
# UNIFI FUNCTIONS
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
    param(
        [string]    $ApiKey,
        [hashtable] $SiteFilter = $null
    )

    $hosts = Get-AllPages -Uri "$BaseUrl/hosts" -ApiKey $ApiKey

    # Trim to only hosts referenced in the filter
    if ($null -ne $SiteFilter -and $SiteFilter.Count -gt 0) {
        $hosts = @($hosts | Where-Object {
            $baseId = $_.id -replace ':.+$', ''
            $matched = $false
            foreach ($fhid in $SiteFilter.Keys) {
                if (($fhid -replace ':.+$', '') -eq $baseId -or $fhid -eq $_.id) { $matched = $true; break }
            }
            $matched
        })
    }

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
    param(
        [string]    $ApiKey,
        [array]     $Hosts,
        [hashtable] $SiteFilter = $null
    )

    $sites = Get-AllPages -Uri "$BaseUrl/sites" -ApiKey $ApiKey

    # Filter to exact host/site pairs from the Datto variable (PowerShell-side only —
    # the /v1/sites endpoint does not support hostIds query params).
    if ($null -ne $SiteFilter -and $SiteFilter.Count -gt 0) {
        $filtered = @($sites | Where-Object {
            $sid     = $_.siteId
            $hid     = $_.hostId
            $baseHid = $hid -replace ':.+$', ''
            $matched = $false
            foreach ($fhid in $SiteFilter.Keys) {
                if (($fhid -replace ':.+$', '') -eq $baseHid -or $fhid -eq $hid) {
                    if ($SiteFilter[$fhid] -contains $sid) { $matched = $true; break }
                }
            }
            $matched
        })

        if ($filtered.Count -eq 0) {
            Write-Host "WARNING: $DattoNetworksVarName produced no matching sites — monitoring all sites as fallback."
        } else {
            $sites = $filtered
        }
    }

    if ($TestMode) {
        $hostLookup    = @{}; foreach ($h in $Hosts) { $hostLookup[$h.id] = $h }
        $hostSiteCount = @{}; foreach ($s in $sites) { $hostSiteCount[$s.hostId] = ($hostSiteCount[$s.hostId] + 1) }

        Write-Host "`n=== SITES ($($sites.Count)) ==="
        foreach ($s in $sites) {
            $counts   = $s.statistics.counts
            $siteName = if (-not [string]::IsNullOrWhiteSpace($s.meta.desc)) { $s.meta.desc } else { $s.meta.name }
            $hostName = $hostLookup[$s.hostId].reportedState.name
            $label    = if ($siteName -ne 'default') {
                $siteName
            } elseif ($hostSiteCount[$s.hostId] -eq 1) {
                $hostName
            } else {
                "$hostName (unnamed site)"
            }
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
        [array]  $Hosts,
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

    # Build host lookup for display name resolution in test output
    $hostLookup    = @{}; foreach ($h in $Hosts) { $hostLookup[$h.id] = $h }

    if ($TestMode) {
        Write-Host "`n=== DEVICE CHECK ==="
    }

    foreach ($site in $Sites) {
        $siteId   = $site.siteId
        $hostId   = $site.hostId
        $counts   = $site.statistics.counts

        # Resolve display name (same logic as Build-SiteHealthMap)
        $siteMeta = if (-not [string]::IsNullOrWhiteSpace($site.meta.desc)) { $site.meta.desc } else { $site.meta.name }
        $hostName = $hostLookup[$hostId].reportedState.name
        $siteName = if ($siteMeta -ne 'default') {
            $siteMeta
        } elseif ($hostSiteCount[$hostId] -eq 1) {
            $hostName
        } else {
            "$hostName (unnamed site)"
        }

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
                Title       = "UniFi: Controller '$($site.HostName)' offline — $($site.SiteName)"
                Detail      = @"
SITE:       $($site.SiteName)
SITE ID:    $siteId
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      UniFi controller '$($site.HostName)' has lost cloud connectivity.
            All devices at this site may be unmanageable until connectivity is restored.
            Users may also have lost internet access.

BEFORE ACTING:
  - Contact the customer to confirm whether they have internet access and if they
    are aware of any disruption before attempting any remote or on-site intervention.
  - Do not reboot or reconfigure anything without customer awareness — this may
    cause additional downtime for active users.

INVESTIGATION (remote):
  1. Log into unifi.ui.com and check whether the controller appears online or offline.
  2. If offline, check whether other sites on the same ISP are also affected
     (may indicate a wider ISP outage rather than a site-specific issue).
  3. Try pinging the site's WAN IP if known — if unreachable, the internet connection
     is likely down rather than just the controller.

RESOLUTION:
  4. If the controller is online locally but not in cloud: ask the customer to reboot
     the controller (power cycle) — advise this will briefly drop WiFi.
  5. If the site internet is down: raise a fault with the ISP. Do not attempt on-site
     work until internet is confirmed restored unless a physical visit is agreed.
  6. If the controller remains offline after internet is confirmed up, a physical visit
     may be required to inspect the device.
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
                Title       = "UniFi: $count device(s) offline — $($site.SiteName)"
                Detail      = @"
SITE:       $($site.SiteName)
SITE ID:    $siteId
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      $count UniFi device(s) offline$breakdownStr.
            Note: detailed per-device information is unavailable for this site —
            log into unifi.ui.com to identify the specific offline device(s).

BEFORE ACTING:
  - Contact the customer to confirm the impact and whether they are aware.
  - If a power cycle or physical intervention is needed, agree a convenient time
    with the customer first — any action on a switch or gateway will cause downtime.

INVESTIGATION (remote):
  1. Log into unifi.ui.com, navigate to $($site.SiteName) and review the device list
     to identify which device(s) are offline and for how long.
  2. Check whether the gateway is among the offline devices — if so, the site may
     have lost internet and users will be fully impacted.
  3. If only APs are offline, check whether they share a common upstream switch
     (a single offline PoE switch will take down all connected APs).

RESOLUTION:
  4. If the device is reachable via SSH or local management, attempt a remote reboot.
  5. If a power cycle is needed and the device is on a managed PoE switch, this may
     be possible remotely via unifi.ui.com — check before requesting a site visit.
  6. If no remote options are available, arrange an on-site visit with the customer.
  7. If the device does not recover after a power cycle, check UniFi for adoption
     errors or firmware issues, and consider hardware replacement if the fault persists.
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
                    Title       = "UniFi: $($d.name) ($deviceType) offline — $($site.SiteName)"
                    Detail      = @"
SITE:       $($site.SiteName)
SITE ID:    $siteId
SEVERITY:   Critical
DETECTED:   $detectedAt
DEVICE:     $($d.name) ($deviceType)
MODEL:      $($d.model)
MAC:        $($d.mac)$gwNote

BEFORE ACTING:
  - Contact the customer to confirm the impact and whether they are aware of the issue.
  - Agree any power cycle or physical intervention with the customer before proceeding —
    rebooting a switch or gateway will cause downtime for connected users and devices.

INVESTIGATION (remote):
  1. Log into unifi.ui.com, navigate to $($site.SiteName) and review $($d.name)'s status,
     uptime history, and any alerts or adoption errors shown in UniFi.
  2. Check how long the device has been offline — a recent drop may resolve itself
     (e.g. firmware update reboot), whereas a persistent offline suggests a fault.
  3. If this is a switch or AP, check whether upstream devices are healthy — an offline
     uplink or PoE switch will take down all devices connected to it.

RESOLUTION:
  4. If the device is on a managed PoE switch, attempt a remote power cycle via
     unifi.ui.com (Devices > select switch > Ports > toggle PoE on the affected port).
  5. If the device supports it, attempt a remote reboot via unifi.ui.com
     (Devices > select device > Settings > Restart).
  6. If no remote power options are available, arrange an on-site visit with the
     customer — bring a replacement unit in case of hardware failure.
  7. On site: check physical connections, power indicators (LEDs), and re-adopt
     the device in UniFi if it has lost its configuration.
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
                        Title       = "UniFi: WAN instability ($wanUp% uptime) — $($site.SiteName)"
                        Detail      = @"
SITE:       $($site.SiteName)
SITE ID:    $siteId
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      Primary WAN uptime $wanUp%$ispStr.
            Threshold: $ThresholdWanUptimeCritPct%. The WAN connection has been dropping
            repeatedly. Users are likely experiencing internet outages.

BEFORE ACTING:
  - Contact the customer to confirm impact and whether they are aware.
  - Do not reboot the gateway or ISP equipment without customer agreement —
    this will cause a brief additional outage during the reboot.

INVESTIGATION (remote):
  1. Log into unifi.ui.com, navigate to $($site.SiteName) > Gateway > WAN and review
     the uptime graph and event log to understand when drops are occurring and how long
     they last (brief blips vs sustained outages suggest different root causes).
  2. Check the ISP status page$ispStr for any reported incidents in the area.
  3. If failover (WAN2) is configured and active, the site may still have internet —
     confirm with the customer before escalating urgency.

RESOLUTION:
  4. If an ISP outage is confirmed, raise a fault with$ispStr and monitor for resolution.
     Share the UniFi WAN uptime data with the ISP as evidence.
  5. If no ISP outage is reported, ask the customer to power cycle the ISP
     router/modem — advise this will cause a brief internet drop.
  6. If drops persist after a modem reboot, escalate to the ISP with line quality
     data and request an engineer visit or line test.
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
                        Title       = "UniFi: High TX retry rate ($txRetry%) — $($site.SiteName)"
                        Detail      = @"
SITE:       $($site.SiteName)
SITE ID:    $siteId
SEVERITY:   Critical
DETECTED:   $detectedAt
ISSUE:      TX retry rate $txRetry% (threshold: $ThresholdTxRetryCritPct%).
            High retry rates indicate significant RF interference, channel congestion,
            or failing wireless hardware. Wireless clients will experience slow speeds,
            dropped connections, and poor reliability.

BEFORE ACTING:
  - Contact the customer to understand whether they have noticed wireless performance
    issues and if anything has changed recently (new equipment, building works, etc).
  - Any channel or RF changes made remotely will cause a brief WiFi disruption
    while APs re-associate — agree timing with the customer before making changes.

INVESTIGATION (remote):
  1. Log into unifi.ui.com, navigate to $($site.SiteName) > Access Points and check
     each AP's TX retry rate individually to identify whether one AP is the source
     or whether the issue is site-wide.
  2. Review the RF environment in UniFi (Insights > WiFi > Channel Utilisation) for
     signs of channel congestion from neighbouring networks.
  3. Check whether any APs have recently been added, moved, or updated — these
     can temporarily affect RF performance.

RESOLUTION:
  4. If a single AP has an elevated retry rate, consider it may have a hardware fault
     (failing radio). Monitor and arrange replacement if it does not improve.
  5. If site-wide, adjust AP channel assignments to less congested channels via
     unifi.ui.com — or enable auto-optimise (Settings > WiFi > Advanced).
     Advise the customer of a brief WiFi disruption before applying.
  6. If interference is suspected from physical sources (new microwave, cordless
     phone, neighbouring office), switching to 5GHz-only for affected APs may help.
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
                        Title       = "UniFi: Elevated TX retry rate ($txRetry%) — $($site.SiteName)"
                        Detail      = @"
SITE:       $($site.SiteName)
SITE ID:    $siteId
SEVERITY:   Warning
DETECTED:   $detectedAt
ISSUE:      TX retry rate $txRetry% (threshold: $ThresholdTxRetryWarnPct%).
            Elevated retries may indicate RF interference or channel congestion.
            Wireless performance may be degraded for some users.

INVESTIGATION (remote — no customer contact required at this stage):
  1. Log into unifi.ui.com, navigate to $($site.SiteName) > Access Points and check
     which APs have elevated retry rates to determine if this is isolated or site-wide.
  2. Review channel utilisation in UniFi (Insights > WiFi) for signs of congestion.
  3. Monitor over the next few poll cycles — if the rate rises above $ThresholdTxRetryCritPct%,
     escalate to Critical and contact the customer.

NOTE: Do not make any channel or RF changes without first contacting the customer,
as this will cause a brief WiFi disruption while APs re-associate.
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

        # Summarise the categories in the merged ticket title, e.g.
        # "UniFi: 3 issue(s) at Acme HQ — DeviceOffline, WANUptime [Critical]"
        $categories = ($items | Select-Object -ExpandProperty Category -Unique) -join ', '
        $title = if ($items.Count -eq 1) {
            $items[0].Title
        } else {
            "UniFi: $($items.Count) issue(s) at $siteName — $categories [$severity]"
        }

        $merged += [PSCustomObject]@{
            SiteId      = $siteId
            SiteName    = $siteName
            Severity    = $severity
            Category    = 'Merged'
            DeviceName  = ''
            DeviceMac   = ''
            DeviceModel = ''
            Title       = $title
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

# ==============================================================================
# AUTOTASK FUNCTIONS
# ==============================================================================

function Get-AutotaskCredentials {
    <#
    Resolves the Autotask API credentials from Datto site/global variables
    (environment variables) or from inline script values, mirroring
    Get-UniFiApiKey behaviour.
    #>
    if ($AutotaskCredSource -eq 'Script') {
        $user   = $AutotaskScriptUser
        $secret = $AutotaskScriptSecret
        $integ  = $AutotaskScriptIntegrationCode
    } else {
        $user   = [System.Environment]::GetEnvironmentVariable($AutotaskUserVarName, 'Process')
        if ([string]::IsNullOrWhiteSpace($user))   { $user   = [System.Environment]::GetEnvironmentVariable($AutotaskUserVarName, 'Machine') }
        $secret = [System.Environment]::GetEnvironmentVariable($AutotaskSecretVarName, 'Process')
        if ([string]::IsNullOrWhiteSpace($secret)) { $secret = [System.Environment]::GetEnvironmentVariable($AutotaskSecretVarName, 'Machine') }
        $integ  = [System.Environment]::GetEnvironmentVariable($AutotaskIntegrationVarName, 'Process')
        if ([string]::IsNullOrWhiteSpace($integ))  { $integ  = [System.Environment]::GetEnvironmentVariable($AutotaskIntegrationVarName, 'Machine') }
    }

    if ([string]::IsNullOrWhiteSpace($user) -or
        [string]::IsNullOrWhiteSpace($secret) -or
        [string]::IsNullOrWhiteSpace($integ)) {
        throw "Autotask credentials are incomplete. Set Datto variables '$AutotaskUserVarName', '$AutotaskSecretVarName' and '$AutotaskIntegrationVarName', or set `$AutotaskCredSource = 'Script'` with the inline values."
    }

    return @{
        UserName           = $user
        Secret             = $secret
        ApiIntegrationCode = $integ
    }
}

function Get-AutotaskBaseUrl {
    <#
    Resolves the tenant-specific REST API base URL. The zoneInformation call
    requires no authentication and returns e.g.:
      { "zoneName":"...", "url":"https://webservices16.autotask.net/ATServicesRest/", ... }
    Returns the base URL WITHOUT a trailing slash and WITHOUT the V1.0 segment.
    #>
    param([hashtable] $Credentials)

    if (-not [string]::IsNullOrWhiteSpace($AutotaskBaseUrlOverride)) {
        return $AutotaskBaseUrlOverride.TrimEnd('/')
    }

    $userEsc = [uri]::EscapeDataString($Credentials.UserName)
    $zoneUri = "https://webservices.autotask.net/ATServicesRest/V1.0/zoneInformation?user=$userEsc"

    try {
        $zone = Invoke-RestMethod -Method GET -Uri $zoneUri -ErrorAction Stop
    } catch {
        throw "Failed to resolve Autotask zone for user '$($Credentials.UserName)': $($_.Exception.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($zone.url)) {
        throw "Autotask zoneInformation returned no URL for user '$($Credentials.UserName)'."
    }

    return $zone.url.TrimEnd('/')
}

function Invoke-AutotaskApi {
    param(
        [string]    $Method = 'GET',
        [string]    $Path,            # path under {base}/V1.0/, e.g. 'Tickets' or 'Companies/query'
        [object]    $Body = $null,
        [hashtable] $Credentials,
        [string]    $BaseApiUrl
    )

    $headers = @{
        'UserName'           = $Credentials.UserName
        'Secret'             = $Credentials.Secret
        'ApiIntegrationCode' = $Credentials.ApiIntegrationCode
        'Accept'             = 'application/json'
    }

    $params = @{
        Method      = $Method
        Uri         = "$BaseApiUrl/V1.0/$Path"
        Headers     = $headers
        ErrorAction = 'Stop'
    }

    if ($null -ne $Body) {
        $params['Body']        = ($Body | ConvertTo-Json -Depth 10 -Compress)
        $params['ContentType'] = 'application/json'
    }

    $attempt = 0
    while ($attempt -lt 2) {
        try {
            return Invoke-RestMethod @params
        } catch {
            $statusCode = 0
            if ($_.Exception.Response -ne $null) {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } elseif ($_.Exception -is [System.Net.Http.HttpRequestException] -and $_.Exception.StatusCode) {
                $statusCode = [int]$_.Exception.StatusCode
            }

            # Autotask threshold limiting — back off once, then give up
            if ($statusCode -eq 429 -and $attempt -eq 0) {
                Write-Host "Autotask API rate limit hit. Sleeping 30 seconds before retry."
                Start-Sleep -Seconds 30
                $attempt++
                continue
            }

            if ($statusCode -eq 401) {
                throw "Autotask authentication failed (401) — check the API user, secret and integration code."
            }

            # Pull the error detail out of the response body — Autotask returns
            # { "errors": ["..."] } with useful validation messages on 4xx/500.
            $apiErrors = ''
            try {
                $stream   = $_.Exception.Response.GetResponseStream()
                $reader   = New-Object System.IO.StreamReader($stream)
                $bodyText = $reader.ReadToEnd()
                $parsed   = $bodyText | ConvertFrom-Json
                if ($parsed.errors) { $apiErrors = ($parsed.errors -join '; ') }
            } catch {}

            if ($statusCode -gt 0) {
                throw "Autotask HTTP $statusCode from $Path : $apiErrors $($_.Exception.Message)"
            } else {
                throw "Autotask request failed for $Path : $($_.Exception.Message)"
            }
        }
    }
}

function Resolve-AutotaskCompany {
    <#
    Maps a UniFi site name to an Autotask company id and name.
    Lookup order:
      1. $CompanyNameMap[$SiteName] (explicit mapping) -> company name to query
      2. The UniFi site name verbatim
    Queries POST Companies/query with an exact (case-insensitive on the
    Autotask side) companyName match. Results are cached per run.
    Returns @{ Id; Name; Mapped } or $null when no match is found.
    #>
    param(
        [string]    $SiteName,
        [hashtable] $Credentials,
        [string]    $BaseApiUrl,
        [hashtable] $Cache
    )

    if ($Cache.ContainsKey($SiteName)) { return $Cache[$SiteName] }

    $companyName = if ($CompanyNameMap.ContainsKey($SiteName)) { $CompanyNameMap[$SiteName] } else { $SiteName }

    $query = @{
        MaxRecords    = 2
        IncludeFields = @('id', 'companyName', 'isActive')
        filter        = @(
            @{ op = 'eq'; field = 'companyName'; value = $companyName }
        )
    }

    $result  = Invoke-AutotaskApi -Method 'POST' -Path 'Companies/query' -Body $query -Credentials $Credentials -BaseApiUrl $BaseApiUrl
    $items   = @($result.items)
    $company = $null

    if ($items.Count -ge 1) {
        if ($items.Count -gt 1) {
            Write-Host "WARNING: Multiple Autotask companies named '$companyName' — using the first (id=$($items[0].id))."
        }
        $company = @{
            Id     = [long]$items[0].id
            Name   = $items[0].companyName
            Mapped = $CompanyNameMap.ContainsKey($SiteName)
        }
    }

    $Cache[$SiteName] = $company
    return $company
}

function Get-AutotaskPrimaryContact {
    <#
    Returns the id of the active primary contact for a company, or $null when
    the company has no primary contact (ticket contact is then left blank).
    Results are cached per run.
    #>
    param(
        [long]      $CompanyId,
        [hashtable] $Credentials,
        [string]    $BaseApiUrl,
        [hashtable] $Cache
    )

    if ($Cache.ContainsKey($CompanyId)) { return $Cache[$CompanyId] }

    $query = @{
        MaxRecords    = 1
        IncludeFields = @('id', 'firstName', 'lastName', 'emailAddress')
        filter        = @(
            @{ op = 'eq'; field = 'companyID';        value = $CompanyId }
            @{ op = 'eq'; field = 'isPrimaryContact'; value = $true }
            @{ op = 'eq'; field = 'isActive';         value = 1 }
        )
    }

    $contactId = $null
    try {
        $result = Invoke-AutotaskApi -Method 'POST' -Path 'Contacts/query' -Body $query -Credentials $Credentials -BaseApiUrl $BaseApiUrl
        $items  = @($result.items)
        if ($items.Count -ge 1) { $contactId = [long]$items[0].id }
    } catch {
        # A failed contact lookup should never block ticket creation
        Write-Host "WARNING: Primary contact lookup failed for companyID $CompanyId — leaving contact blank. $($_.Exception.Message)"
    }

    $Cache[$CompanyId] = $contactId
    return $contactId
}

function Test-OpenDuplicateTicket {
    <#
    Returns $true if an open (status != complete) ticket with the same title
    already exists for the company — used to suppress duplicate tickets while
    a fault is ongoing across poll cycles.
    #>
    param(
        [long]      $CompanyId,
        [string]    $Title,
        [hashtable] $Credentials,
        [string]    $BaseApiUrl
    )

    $query = @{
        MaxRecords    = 1
        IncludeFields = @('id', 'ticketNumber', 'status')
        filter        = @(
            @{ op = 'eq';    field = 'companyID'; value = $CompanyId }
            @{ op = 'eq';    field = 'title';     value = $Title }
            @{ op = 'noteq'; field = 'status';    value = $TicketCompleteStatusId }
        )
    }

    try {
        $result = Invoke-AutotaskApi -Method 'POST' -Path 'Tickets/query' -Body $query -Credentials $Credentials -BaseApiUrl $BaseApiUrl
        $items  = @($result.items)
        if ($items.Count -ge 1) {
            Write-Host "  SKIP: open ticket $($items[0].ticketNumber) already exists with the same title."
            return $true
        }
    } catch {
        # If the duplicate check fails, err on the side of creating the ticket
        Write-Host "WARNING: Duplicate-ticket check failed — proceeding with creation. $($_.Exception.Message)"
    }

    return $false
}

function Build-AutotaskTicketBody {
    <#
    Builds the POST /V1.0/Tickets body for one alert. The alert title becomes
    the ticket title (truncated to the API's 255-char limit) and the alert
    detail becomes the ticket description (truncated to 8000 chars).
    Optional picklist fields are only included when configured (non-null) so
    Autotask defaults and workflow rules still apply.
    #>
    param(
        [PSCustomObject] $Alert,
        [long]           $CompanyId,
        [object]         $ContactId,      # $null = leave blank
        [string]         $CompanyNote = ''
    )

    $title = $Alert.Title
    if ($title.Length -gt 255) { $title = $title.Substring(0, 252) + '...' }

    $description = @"
Ticket raised automatically by UniFi Health Monitor on $((Get-Date).ToString('dd/MM/yyyy HH:mm')) UTC.
$CompanyNote
$($Alert.Detail)
"@.Trim()
    if ($description.Length -gt 8000) { $description = $description.Substring(0, 7997) + '...' }

    $priority = $TicketPriorityMap[$Alert.Severity]
    if ($null -eq $priority) {
        throw "No Autotask priority mapped for severity '$($Alert.Severity)' — check `$TicketPriorityMap."
    }

    $body = @{
        companyID   = $CompanyId
        title       = $title
        description = $description
        status      = $TicketStatusNew
        priority    = $priority
        dueDateTime = (Get-Date).ToUniversalTime().AddHours($TicketDueHours).ToString('yyyy-MM-ddTHH:mm:ssZ')
    }

    if ($null -ne $ContactId) { $body['contactID'] = $ContactId }
    if ($null -ne $TicketSource) { $body['source'] = $TicketSource }

    $catMap = $TicketCategoryMap[$Alert.Category]
    if ($null -eq $catMap) { $catMap = $TicketCategoryMap['Merged'] }
    if ($catMap) {
        if ($null -ne $catMap.QueueID)      { $body['queueID']      = $catMap.QueueID }
        if ($null -ne $catMap.IssueType)    { $body['issueType']    = $catMap.IssueType }
        if ($null -ne $catMap.SubIssueType) { $body['subIssueType'] = $catMap.SubIssueType }
    }

    return $body
}

function Submit-AutotaskTickets {
    <#
    Production-mode output stage: resolves each alert's company and primary
    contact, then creates one Autotask ticket per alert. Per-alert failures
    are logged and counted but do not abort the run.
    #>
    param([array] $Alerts)

    if ($Alerts.Count -eq 0) {
        Write-Host 'All monitored UniFi sites are healthy — no tickets to raise.'
        exit 0
    }

    $creds   = Get-AutotaskCredentials
    $baseUrl = Get-AutotaskBaseUrl -Credentials $creds

    $companyCache = @{}
    $contactCache = @{}
    $created      = 0
    $skipped      = 0
    $failed       = 0

    Write-Host "UniFi Health Monitor — $($Alerts.Count) alert(s) to raise as Autotask tickets."

    foreach ($alert in $Alerts) {
        Write-Host "`n[$($alert.Severity)] $($alert.Title)"
        try {
            $companyNote = ''
            $company     = Resolve-AutotaskCompany -SiteName $alert.SiteName -Credentials $creds -BaseApiUrl $baseUrl -Cache $companyCache

            if ($null -ne $company) {
                $companyId = $company.Id
                Write-Host "  Company: '$($company.Name)' (id=$companyId)"
            } elseif ($null -ne $FallbackCompanyID) {
                $companyId   = [long]$FallbackCompanyID
                $companyNote = "NOTE: UniFi site '$($alert.SiteName)' could not be matched to an Autotask company — ticket raised against the fallback company. Add a `$CompanyNameMap entry for this site.`n"
                Write-Host "  WARNING: No Autotask company found for site '$($alert.SiteName)' — using fallback companyID $companyId."
            } else {
                Write-Host "  ERROR: No Autotask company found for site '$($alert.SiteName)' and no fallback configured — alert skipped."
                $failed++
                continue
            }

            if ($SkipIfOpenDuplicate) {
                $dupTitle = $alert.Title
                if ($dupTitle.Length -gt 255) { $dupTitle = $dupTitle.Substring(0, 252) + '...' }
                if (Test-OpenDuplicateTicket -CompanyId $companyId -Title $dupTitle -Credentials $creds -BaseApiUrl $baseUrl) {
                    $skipped++
                    continue
                }
            }

            $contactId = Get-AutotaskPrimaryContact -CompanyId $companyId -Credentials $creds -BaseApiUrl $baseUrl -Cache $contactCache
            if ($null -ne $contactId) {
                Write-Host "  Contact: primary contact id=$contactId"
            } else {
                Write-Host "  Contact: none (company has no primary contact — left blank)"
            }

            $body   = Build-AutotaskTicketBody -Alert $alert -CompanyId $companyId -ContactId $contactId -CompanyNote $companyNote
            $result = Invoke-AutotaskApi -Method 'POST' -Path 'Tickets' -Body $body -Credentials $creds -BaseApiUrl $baseUrl

            Write-Host "  CREATED: Autotask ticket id=$($result.itemId)"
            $created++
        } catch {
            Write-Host "  ERROR: Failed to create ticket — $($_.Exception.Message)"
            $failed++
        }
    }

    Write-Host "`nSummary: $created created, $skipped skipped (open duplicates), $failed failed."

    if ($failed -gt 0) { exit 1 } else { exit 0 }
}

function Show-AutotaskPicklists {
    <#
    Test-mode helper: dumps the instance-specific picklist values needed to
    populate $TicketPriorityMap / $TicketCategoryMap / $TicketStatusNew /
    $TicketSource. Sub-issue types list their parent issue type value.
    #>
    param(
        [hashtable] $Credentials,
        [string]    $BaseApiUrl
    )

    Write-Host "`n=== AUTOTASK TICKET PICKLISTS ==="
    try {
        $info   = Invoke-AutotaskApi -Method 'GET' -Path 'Tickets/entityInformation/fields' -Credentials $Credentials -BaseApiUrl $BaseApiUrl
        $wanted = @('status', 'priority', 'queueID', 'issueType', 'subIssueType', 'source', 'ticketType')

        foreach ($fieldName in $wanted) {
            $field = $info.fields | Where-Object { $_.name -eq $fieldName }
            if (-not $field -or -not $field.picklistValues) { continue }

            Write-Host "`n  --- $fieldName ---"
            foreach ($pv in ($field.picklistValues | Where-Object { $_.isActive })) {
                $parent = if ($pv.parentValue) { "  (parent issueType=$($pv.parentValue))" } else { '' }
                Write-Host ("    {0,-6} {1}{2}" -f $pv.value, $pv.label, $parent)
            }
        }
    } catch {
        Write-Host "  ERROR: Could not fetch picklists — $($_.Exception.Message)"
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
    Write-Host " UniFi Health Monitor (Autotask) — TEST MODE OUTPUT"
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
        $label = $HealthMap[$s.siteId].SiteName
        Write-Host ("  {0,-35} total={1}  offline={2}  gw_offline={3}  ap_offline={4}  sw_offline={5}" -f
            $label, $c.totalDevice, $c.offlineDevice, $c.offlineGatewayDevice, $c.offlineWifiDevice, $c.offlineWiredDevice)
    }

    Write-Host "`n--- Section 4: Tier 2 Device Call Decisions ---"
    foreach ($s in $Sites) {
        $d     = $DeviceMap[$s.siteId]
        $label = $HealthMap[$s.siteId].SiteName
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
        $label = $HealthMap[$s.siteId].SiteName
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
        $m   = $MetricsMap[$siteId]
        $lbl = $HealthMap[$siteId].SiteName
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

    # --- Autotask resolution (read-only; no tickets are created in test mode) ---
    $atCreds   = $null
    $atBaseUrl = $null
    if ($TestResolveAutotask -or $ShowPicklists) {
        try {
            $atCreds   = Get-AutotaskCredentials
            $atBaseUrl = Get-AutotaskBaseUrl -Credentials $atCreds
            Write-Host "`n--- Section 8: Autotask Connectivity ---"
            Write-Host "  Zone resolved: $atBaseUrl"
        } catch {
            Write-Host "`n--- Section 8: Autotask Connectivity ---"
            Write-Host "  SKIPPED: $($_.Exception.Message)"
            $atCreds = $null
        }
    }

    if ($ShowPicklists -and $atCreds) {
        Show-AutotaskPicklists -Credentials $atCreds -BaseApiUrl $atBaseUrl
    }

    $sep = '=' * 60
    Write-Host "`n--- Section 9: Ticket Previews (not created) ---"
    if ($FinalAlerts.Count -eq 0) {
        Write-Host "  No alerts — no tickets would be raised."
    }

    $companyCache = @{}
    $contactCache = @{}

    foreach ($a in $FinalAlerts) {
        Write-Host $sep
        Write-Host "TICKET TITLE: $($a.Title)"

        # Show what the field mapping would produce
        $priority = $TicketPriorityMap[$a.Severity]
        $catMap   = $TicketCategoryMap[$a.Category]
        if ($null -eq $catMap) { $catMap = $TicketCategoryMap['Merged'] }
        Write-Host ("FIELDS:       status={0}  priority={1}  queueID={2}  issueType={3}  subIssueType={4}  source={5}" -f
            $TicketStatusNew, $priority, $catMap.QueueID, $catMap.IssueType, $catMap.SubIssueType, $TicketSource)

        # Resolve company + primary contact read-only if Autotask creds are available
        if ($atCreds) {
            try {
                $company = Resolve-AutotaskCompany -SiteName $a.SiteName -Credentials $atCreds -BaseApiUrl $atBaseUrl -Cache $companyCache
                if ($company) {
                    $mapNote = if ($company.Mapped) { 'via $CompanyNameMap' } else { 'direct site-name match' }
                    Write-Host "COMPANY:      '$($company.Name)' (id=$($company.Id), $mapNote)"
                    $contactId = Get-AutotaskPrimaryContact -CompanyId $company.Id -Credentials $atCreds -BaseApiUrl $atBaseUrl -Cache $contactCache
                    if ($null -ne $contactId) {
                        Write-Host "CONTACT:      primary contact id=$contactId"
                    } else {
                        Write-Host "CONTACT:      none (no primary contact — would be left blank)"
                    }
                } else {
                    Write-Host "COMPANY:      NOT FOUND for site '$($a.SiteName)' — would use fallback companyID $FallbackCompanyID. Add a `$CompanyNameMap entry."
                }
            } catch {
                Write-Host "COMPANY:      lookup failed — $($_.Exception.Message)"
            }
        } else {
            $mappedName = if ($CompanyNameMap.ContainsKey($a.SiteName)) { $CompanyNameMap[$a.SiteName] } else { "$($a.SiteName) (no map entry — verbatim)" }
            Write-Host "COMPANY:      would query Autotask for '$mappedName'"
        }

        Write-Host "BODY:"
        Write-Host $a.Detail
    }
    if ($FinalAlerts.Count -gt 0) { Write-Host $sep }

    Write-Host "`n============================================================`n"
}

# ==============================================================================
# MAIN
# ==============================================================================

function Main {
    try {
        $apiKey     = Get-UniFiApiKey
        $siteFilter = Get-ProactiveSiteFilter
        $hosts      = Get-UniFiHosts -ApiKey $apiKey -SiteFilter $siteFilter
        $sites      = Get-UniFiSites -ApiKey $apiKey -Hosts $hosts -SiteFilter $siteFilter

        $deviceMap   = Get-UniFiDevices      -Sites $sites -Hosts $hosts -ApiKey $apiKey
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
            Submit-AutotaskTickets -Alerts $finalAlerts
        }

    } catch {
        $errMsg = $_.Exception.Message

        if ($TestMode) {
            Write-Host "ERROR: $errMsg"
        } else {
            Write-Host "ERROR: $errMsg"
            exit 1
        }
    }
}

Main
