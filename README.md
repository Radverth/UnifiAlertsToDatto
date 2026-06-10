# UniFi Health Monitor

PowerShell scripts that poll the [UniFi Site Manager API](https://developer.ui.com/site-manager-api/) for the health of all your managed UniFi sites and raise alerts when something is wrong. Two variants are included, sharing the same monitoring engine but with different outputs:

| Script | Output | Runs on |
|---|---|---|
| `UniFiHealthMonitor.ps1` | Datto RMM monitor alerts | Datto RMM (monitor component) |
| `UniFiHealthMonitorAutotask.ps1` | Autotask PSA tickets via the Autotask REST API | Any scheduler (Task Scheduler, cron, automation platform) |

## What is monitored

Both scripts evaluate the same checks on every run:

| Category | Trigger | Severity |
|---|---|---|
| `HostDisconnected` | UniFi controller has lost cloud connectivity | Critical |
| `DeviceOffline` | One or more UniFi devices (gateway, switch, AP) offline | Critical |
| `WANUptime` | Primary WAN uptime below 99.0% | Critical |
| `TxRetry` | Wireless TX retry rate above 55% / above 50% | Critical / Warning |

Every alert body is written for the engineer who picks it up: site and device identifiers, what the issue means, customer-contact guidance, remote investigation steps, and resolution steps including remote PoE power-cycling before an on-site visit is considered.

Notes on behaviour shared by both scripts:

- **Two-tier device check** (`$UseTwoTierDeviceCheck`): sites reporting zero offline devices in the bulk sites call are not queried for per-device detail, keeping API usage low across many sites.
- **Alert merging** (`$MergeAlerts`): when `$true` (default), all issues at one site are combined into a single alert/ticket; when `$false`, each issue raises its own.
- **Site filtering**: an optional `UniFiNetworks` variable (`"HostID|SiteID,HostID2|SiteID2,..."`) restricts monitoring to specific host/site pairs. If the filter matches nothing, all sites are monitored as a fallback.
- **Test mode** (`$TestMode = $true`, the default): prints a full diagnostic walkthrough — topology, per-site counts, device fetch decisions, WAN metrics, and a preview of every alert/ticket — without raising anything. Set to `$false` for production.
- **Thresholds** are set at the top of each script (`$Threshold*` variables).
- Firmware monitoring is intentionally excluded (auto-updates are enabled on all sites).

## Requirements

- PowerShell 5.1 or later (PowerShell 7 also supported).
- A UniFi Site Manager API key, created at [unifi.ui.com](https://unifi.ui.com) → API.
- Outbound HTTPS to `api.ui.com` (and, for the Autotask variant, `*.autotask.net`).

---

## UniFiHealthMonitor.ps1 (Datto RMM)

Deploy as a Datto RMM **monitor component**. The script writes `<-Start Diagnostic->` / `<-Start Result->` markers and exits `0` (healthy) or `1` (alert), so Datto raises and clears alerts from the result line.

**Setup**

1. Create a Datto site variable (or account-level variable) named `UniFiApiKey` containing the UniFi API key.
2. Optionally create a site variable `UniFiNetworks` to restrict which host/site pairs are monitored.
3. Upload the script as a component, set `$TestMode = $false`, and schedule it against one agent per site (or a single agent for the full estate).

**Key configuration variables**

| Variable | Default | Purpose |
|---|---|---|
| `$TestMode` | `$true` | Diagnostic output only, no Datto markers or exit codes |
| `$MergeAlerts` | `$true` | One alert per site instead of one per issue |
| `$ApiKeySource` | `'SiteVar'` | `'SiteVar'` = Datto variable, `'Script'` = inline `$ScriptApiKey` |
| `$DattoSiteVarName` | `'UniFiApiKey'` | Name of the Datto variable holding the API key |
| `$DattoNetworksVarName` | `'UniFiNetworks'` | Name of the optional site-filter variable |

---

## UniFiHealthMonitorAutotask.ps1 (Autotask PSA)

Standalone script for any scheduler. Each alert becomes an Autotask ticket: the alert title is the ticket title and the detailed alert body is the ticket description.

### Step 1 — Create the Autotask API user

In Autotask: **Admin → Resources (Users) → New API User**. Note the three values the script needs:

- the API user's **username** (email format)
- the API user's **secret** (password)
- the **API integration code** (tracking identifier)

The API user needs permission to query Companies, Contacts and Contracts, and to create Tickets.

### Step 2 — Set the environment variables

| Environment variable | Required | Contents |
|---|---|---|
| `UniFiApiKey` | Yes | UniFi Site Manager API key |
| `AutotaskApiUser` | Yes | API user email |
| `AutotaskApiSecret` | Yes | API user secret |
| `AutotaskApiIntegrationCode` | Yes | API tracking identifier |
| `UniFiNetworks` | No | `"HostID\|SiteID,..."` site filter |

**Windows — persistent machine-level variables** (run PowerShell *as Administrator* once; the script's env lookup checks process scope first, then machine scope):

```powershell
[System.Environment]::SetEnvironmentVariable('UniFiApiKey',                'your-unifi-api-key',          'Machine')
[System.Environment]::SetEnvironmentVariable('AutotaskApiUser',            'apiuser@yourdomain.co.uk',    'Machine')
[System.Environment]::SetEnvironmentVariable('AutotaskApiSecret',          'your-api-user-secret',        'Machine')
[System.Environment]::SetEnvironmentVariable('AutotaskApiIntegrationCode', 'YOUR-INTEGRATION-CODE',       'Machine')

# Optional: restrict monitoring to specific UniFi host/site pairs
[System.Environment]::SetEnvironmentVariable('UniFiNetworks', 'F4E2C6AABBCC|default,941C57DDEEFF|66a1b2c3d4e5f6a7b8c9d0e1', 'Machine')
```

Already-running sessions (including Task Scheduler) pick machine variables up on next start. To verify:

```powershell
[System.Environment]::GetEnvironmentVariable('AutotaskApiUser', 'Machine')
```

**Windows — per-session (testing only):**

```powershell
$env:UniFiApiKey                = 'your-unifi-api-key'
$env:AutotaskApiUser            = 'apiuser@yourdomain.co.uk'
$env:AutotaskApiSecret          = 'your-api-user-secret'
$env:AutotaskApiIntegrationCode = 'YOUR-INTEGRATION-CODE'
.\UniFiHealthMonitorAutotask.ps1
```

**Linux / macOS (PowerShell 7) — wrapper script for cron:**

```bash
#!/bin/bash
# /opt/unifi-monitor/run.sh  — chmod 700, owned by the service user
export UniFiApiKey='your-unifi-api-key'
export AutotaskApiUser='apiuser@yourdomain.co.uk'
export AutotaskApiSecret='your-api-user-secret'
export AutotaskApiIntegrationCode='YOUR-INTEGRATION-CODE'
pwsh -NoProfile -File /opt/unifi-monitor/UniFiHealthMonitorAutotask.ps1
```

```cron
# crontab: run every 15 minutes
*/15 * * * * /opt/unifi-monitor/run.sh >> /var/log/unifi-monitor.log 2>&1
```

The Autotask API zone is resolved automatically via the `zoneInformation` endpoint; set `$AutotaskBaseUrlOverride` (e.g. `'https://webservices16.autotask.net/ATServicesRest/'`) to skip the lookup.

### Step 3 — Map UniFi sites to Autotask companies

Sites are matched to companies by name. Any site **not** listed in `$CompanyNameMap` is looked up in Autotask using its UniFi site name verbatim — so if your UniFi site names already match your Autotask company names exactly, the map can stay empty.

```powershell
$CompanyNameMap = @{
    'Acme Head Office (UniFi)' = 'Acme Widgets Ltd'
    'Smiths Warehouse'         = 'Smith & Sons'
    # UniFi site name            Autotask company name (exact)
}
```

If no company matches, the ticket is raised against `$FallbackCompanyID` (default `0`, your own account) with a note in the description prompting you to add a map entry — or skipped entirely if you set `$FallbackCompanyID = $null`.

**Primary contact:** the company's active primary contact (`isPrimaryContact = true`) is attached to the ticket automatically. If the company has no primary contact, the contact field is left blank. No configuration needed.

### Step 4 — Contract checking (optional)

Two independent toggles share one lookup against the company's **active** ("In Effect") contracts:

| | What it does | No match found |
|---|---|---|
| `$AssignContract = $true` | Writes the matching contract's id to the ticket's `contractID` | Ticket still created, without a contract, with a note in the description |
| `$FilterByContract = $true` | **Only raises tickets for companies holding the desired contract** | Alert skipped — logged as `FILTERED`, a normal outcome (not an error, exit code unaffected) |

Both use `$DesiredContract`, which accepts:

- a **contract name** — matched per company; the usual choice for filtering, since each client's contract has its own ID but can share the same name
- a **numeric contract ID** — verified to belong to the alert's company, so this effectively limits ticketing to a single organisation
- `''` (empty) — the company's default contract (`isDefaultContract = true`); valid for assignment only — the filter refuses to start with an empty value, since every company with any default contract would pass

**Example — only ticket companies on your managed-services agreement, and stamp the contract on the ticket:**

```powershell
$AssignContract    = $true
$FilterByContract  = $true
$DesiredContract   = 'Managed Services'
```

**Example — ticket everyone, but assign each company's default contract when it has one:**

```powershell
$AssignContract    = $true
$FilterByContract  = $false
$DesiredContract   = ''
```

**Example — only ticket the one company holding contract 29684123, without assigning it:**

```powershell
$AssignContract    = $false
$FilterByContract  = $true
$DesiredContract   = '29684123'
```

Notes:

- `$ContractActiveStatus = 1` is the "In Effect" status value in a default Autotask instance; adjust if yours differs.
- When filtering, alerts that fell back to `$FallbackCompanyID` are also filtered unless that company holds the desired contract.
- The contract lookup runs before the duplicate/contact queries and is cached per company, so filtered companies cost one API call per run.

### Step 5 — Map ticket fields to your instance

Priority, status, queue, issue type, sub-issue type, and source are instance-specific picklist integers. Discover yours by running once with:

```powershell
$TestMode      = $true
$ShowPicklists = $true
```

This dumps every valid value (including sub-issue → parent issue relationships) from `Tickets/entityInformation/fields`. Then fill in the maps:

```powershell
# Severity -> priority picklist value
$TicketPriorityMap = @{
    'Critical' = 1       # 1 = Critical in this example instance
    'Warning'  = 2       # 2 = High
}

# Alert category -> queue / issue type / sub-issue type.
# 'Merged' is used when $MergeAlerts = $true (one combined ticket per site).
# Leave any value $null to omit the field (Autotask defaults/workflow rules apply).
$TicketCategoryMap = @{
    'HostDisconnected' = @{ QueueID = 29683481; IssueType = 10; SubIssueType = 136 }
    'DeviceOffline'    = @{ QueueID = 29683481; IssueType = 10; SubIssueType = 137 }
    'WANUptime'        = @{ QueueID = 29683481; IssueType = 10; SubIssueType = 138 }
    'TxRetry'          = @{ QueueID = 29683481; IssueType = 10; SubIssueType = $null }
    'Merged'           = @{ QueueID = 29683481; IssueType = 10; SubIssueType = $null }
}

$TicketStatusNew = 1        # 1 = New
$TicketSource    = 8        # e.g. 8 = Monitoring Alert ($null = omit)
$TicketDueHours  = 24       # due date = creation time + 24h
```

**Duplicate suppression** (`$SkipIfOpenDuplicate`, default on): before creating a ticket, the script checks for an open ticket with the same title against the same company and skips it, so an ongoing fault does not spawn a new ticket every poll cycle. `$TicketCompleteStatusId` (default `5` = Complete) defines which status counts as closed.

### Step 6 — Test, then go live

Run in test mode first (`$TestMode = $true`, the default). With credentials in place the preview resolves everything read-only — no tickets are created:

```text
TICKET TITLE: UniFi: Controller 'Acme-UDM' offline — Acme Head Office
FIELDS:       status=1  priority=1  queueID=29683481  issueType=10  subIssueType=136  source=8
COMPANY:      'Acme Widgets Ltd' (id=174, via $CompanyNameMap)
CONTACT:      primary contact id=30682941
CONTRACT:     'Managed Services' (id=29684123) — would be assigned to ticket
BODY:         ...full alert detail...
```

Then set `$TestMode = $false` and schedule it, e.g. every 15 minutes via Task Scheduler:

```powershell
# Task Scheduler action (Program: powershell.exe)
-NoProfile -ExecutionPolicy Bypass -File C:\Scripts\UniFiHealthMonitorAutotask.ps1
```

The script exits `0` when the run succeeded (including runs where alerts were filtered or suppressed as duplicates) and `1` when any ticket failed to create, so the scheduler can alert on failures. Per-alert failures are logged and do not abort the rest of the run. Each run ends with a summary:

```text
Summary: 2 created, 1 skipped (open duplicates), 3 filtered (no matching contract), 0 failed.
```

### Configuration reference

| Variable | Default | Purpose |
|---|---|---|
| `$TestMode` | `$true` | Preview tickets without creating them |
| `$MergeAlerts` | `$true` | One ticket per site instead of one per issue |
| `$ApiKeySource` / `$AutotaskCredSource` | `'Env'` | `'Env'` = environment variables, `'Script'` = inline values (testing only) |
| `$CompanyNameMap` | `@{}` | UniFi site name → Autotask company name |
| `$FallbackCompanyID` | `0` | Company used when no match is found (`$null` = skip) |
| `$AssignContract` | `$false` | Assign the matching contract to the ticket |
| `$FilterByContract` | `$false` | Only raise tickets for companies holding the desired contract |
| `$DesiredContract` | `''` | Contract ID, contract name, or `''` for the company default |
| `$ContractActiveStatus` | `1` | Contracts.status value meaning "In Effect" |
| `$TicketPriorityMap` | Critical=1, Warning=2 | Severity → priority picklist value |
| `$TicketCategoryMap` | all `$null` | Category → queue / issue type / sub-issue type |
| `$TicketStatusNew` | `1` | Status for new tickets |
| `$TicketSource` | `$null` | Source picklist value (`$null` = omit) |
| `$TicketDueHours` | `24` | Due date offset from creation time |
| `$SkipIfOpenDuplicate` | `$true` | Suppress duplicate open tickets |
| `$TicketCompleteStatusId` | `5` | Status regarded as closed for duplicate checks |
| `$AutotaskBaseUrlOverride` | `''` | Set to your zone URL to skip the zone lookup |
| `$ShowPicklists` | `$false` | Dump instance picklist values in test mode |
| `$TestResolveAutotask` | `$true` | Resolve companies/contacts/contracts read-only in test mode |
