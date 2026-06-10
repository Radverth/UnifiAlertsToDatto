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

### Autotask prerequisites

1. Create an **API-only user** in Autotask (Admin → Resources/Users → API User) and note the username, secret, and API integration code.
2. Set the environment variables on the machine running the script:

| Environment variable | Contents |
|---|---|
| `UniFiApiKey` | UniFi Site Manager API key |
| `UniFiNetworks` | *(optional)* `"HostID\|SiteID,..."` site filter |
| `AutotaskApiUser` | API user email |
| `AutotaskApiSecret` | API user secret |
| `AutotaskApiIntegrationCode` | API tracking identifier |

The tenant-specific API zone is resolved automatically via the `zoneInformation` endpoint; set `$AutotaskBaseUrlOverride` to skip the lookup.

### How tickets are created

- **Company** — the UniFi site name is mapped to an Autotask company name via `$CompanyNameMap`; sites without a map entry are looked up by their UniFi site name verbatim. If no company matches, the ticket is raised against `$FallbackCompanyID` (default `0`, your own account) with a note in the description, or skipped if that is `$null`.
- **Contact** — the company's active primary contact (`isPrimaryContact`) is attached when one exists; otherwise the contact field is left blank.
- **Contract** *(optional)* — with `$AssignContract = $true`, the script checks the company's active contracts and sets the ticket's `contractID`. `$DesiredContract` accepts a numeric contract ID (verified to belong to the company), a contract name, or `''` for the company's default contract. `$RequireContractMatch` decides whether a missing match skips the alert (`$true`) or creates the ticket without a contract and notes it (`$false`, default).
- **Fields** — priority is mapped per severity (`$TicketPriorityMap`); queue, issue type, and sub-issue type are mapped per alert category (`$TicketCategoryMap`). Values left `$null` are omitted so Autotask defaults and workflow rules apply. Status, source, and due date are set via `$TicketStatusNew`, `$TicketSource`, and `$TicketDueHours`.
- **Duplicate suppression** (`$SkipIfOpenDuplicate`, default on) — before creating a ticket, the script checks for an open ticket with the same title against the same company and skips it, so an ongoing fault does not spawn a new ticket every poll cycle.

### Finding your picklist values

Priority, status, queue, issue type, sub-issue type, and source are instance-specific integers. Run once with:

```powershell
$TestMode      = $true
$ShowPicklists = $true
```

and the script dumps every valid value (including sub-issue → parent issue relationships) from your instance via `Tickets/entityInformation/fields`. Fill the mapping tables with the values you want, then re-run in test mode: the ticket previews show the resolved company, primary contact, contract, and field values for every alert — without creating anything.

### Going live

Set `$TestMode = $false` and schedule the script, e.g. every 15 minutes:

```powershell
# Windows Task Scheduler action
powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\Scripts\UniFiHealthMonitorAutotask.ps1
```

The script exits `0` when all tickets were created (or none were needed) and `1` when any ticket failed, so the scheduler can alert on failures. Per-alert failures are logged and do not abort the rest of the run.

### Key configuration variables

| Variable | Default | Purpose |
|---|---|---|
| `$TestMode` | `$true` | Preview tickets without creating them |
| `$MergeAlerts` | `$true` | One ticket per site instead of one per issue |
| `$CompanyNameMap` | `@{}` | UniFi site name → Autotask company name |
| `$FallbackCompanyID` | `0` | Company used when no match is found (`$null` = skip) |
| `$AssignContract` | `$false` | Toggle contract checking/assignment |
| `$DesiredContract` | `''` | Contract ID, contract name, or `''` for the company default |
| `$RequireContractMatch` | `$false` | Skip the alert when no contract matches |
| `$TicketPriorityMap` | Critical=1, Warning=2 | Severity → priority picklist value |
| `$TicketCategoryMap` | all `$null` | Category → queue / issue type / sub-issue type |
| `$TicketStatusNew` | `1` | Status for new tickets |
| `$TicketDueHours` | `24` | Due date offset from creation time |
| `$SkipIfOpenDuplicate` | `$true` | Suppress duplicate open tickets |
| `$ShowPicklists` | `$false` | Dump instance picklist values in test mode |
