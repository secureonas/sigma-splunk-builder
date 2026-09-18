# Sigma → Splunk app builder

Builds the `Sigma_Alerts` Splunk app from the SigmaHQ rule repository:
Windows builtin channels, Sysmon, Microsoft cloud and Linux syslog, with
per-rule exception macros that survive every rebuild.

```bash
git clone https://github.com/secureonas/sigma-splunk-builder.git /opt/sigma-build
cd /opt/sigma-build
bash bootstrap.sh          # venv, sigma-cli, plugins, SigmaHQ rules
bash generate_sigma_app.sh # build the app
```

```
  windows-builtin      449 rules
  windows-sysmon       895 rules
  cloud                 75 rules
  linux                 21 rules
  TOTAL               1440 rules

    rewrote 7 field references
    stanzas=1440 unique=1440
    macros=1440 unique=1440
    macro refs=1440  unique rule ids=1440
    version 2.0.9 -> 2.0.10
```

See **[SETUP.md](SETUP.md)** for the build host.

---

## The exception macro contract

Every generated search ends with a macro named after the Sigma rule UUID:

```
search = index="windows" source="WinEventLog:System" EventCode=7045 ... `7045abcd-...` | table _time, host, _raw
```

```ini
# default/macros.conf
[7045abcd-1234-5678-9abc-def012345678]
definition = *
iseval = 0
```

Per-client exclusions go in `local/macros.conf` on that search head:

```ini
[7045abcd-1234-5678-9abc-def012345678]
definition = NOT host IN ("BACKUP01","BACKUP02")
iseval = 0
```

`default/` is replaced on every deploy, `local/` is not, so exclusions
persist. **This contract must not change** — app name, macro file path,
stanza naming and the `definition = *` default are all load-bearing.

Two consequences:

- **One app only.** `default.meta` does not export macros to system scope, and
  macros resolve in the app context of the search. Splitting Sysmon rules into
  a second app would leave every `` `uuid` `` reference unresolved and the
  searches would run *without* their exclusions.
- **Keep `local/` in version control.** One repo per client, as the exceptions
  are the accumulated tuning work.

## Layout

```
.
├── bootstrap.sh                   one-shot VM setup, idempotent
├── generate_sigma_app.sh          build entry point
├── filter_rules.py                stages rules by group and level
├── VERSION                        MAJOR.MINOR, edited in git only
├── pipelines/
│   ├── secureon-windows-builtin.yml   non-XML WinEventLog field mapping
│   ├── secureon-sysmon.yml            index only, no mapping needed
│   ├── secureon-cloud.yml             Entra sign-in / audit, M365 UAL
│   └── secureon-linux.yml             syslog
├── templates/
│   ├── postprocess-savedsearches.yml  stanza, severity, schedule, macro
│   └── create-macro.yml               the macro stanza
└── skel/                          static app files (replace before first build)
```

`build/`, `staging/` and `sigma_versions/` are generated and gitignored.

## Rule selection

`filter_rules.py` stages rules per group, with the level threshold set by how
trustworthy the underlying data is:

| group | source directories | levels |
|---|---|---|
| windows-builtin | `windows/builtin`, `windows/powershell` | critical, high, medium |
| windows-sysmon | 15 category dirs | critical, high |
| cloud | `azure/signin_logs`, `azure/audit_logs`, `m365` | critical, high, medium |
| linux | `linux/builtin` | critical, high, medium |

Status is always `test` or `stable`. Sysmon stays at high+critical because
the category dirs alone hold ~1200 rules and adding medium roughly doubles
them.

Cloud coverage is `azure/signin_logs` + `azure/audit_logs` + `m365` — 75 rules
against `index=o365`, mapped to `azure:aad:signin`, `azure:aad:audit` and
`o365:management:activity` respectively.

Deliberately excluded:

| path | why |
|---|---|
| `cloud/azure/activity_logs` | Azure IaaS resource logs, not collected |
| `cloud/azure/privileged_identity_management` | posture checks, not log detections |
| `cloud/azure/identity_protection` | 19 rules keyed on `riskEventType`, which needs the Identity Protection sourcetype. Mapped onto sign-in logs they miss offline detections (leaked credentials), and an `atRisk` catch-all alert already covers the same ground. The pipeline maps the field if you want them — add the directory to the `cloud` group. |
| `cloud/aws`, `cloud/gcp`, `macos`, `identity` | not in scope |
| `network` | 53 rules, none for Palo Alto or Sophos |
| `application` | github, bitbucket, kubernetes, opencanary |
| `linux/{auditd,process_creation,file_event,network_connection}` | need auditd or Sysmon-for-Linux |

Rules are staged flat as `<uuid>.yml`, so a rule that upstream renames or
moves cannot produce two copies.

## Scheduling

| level | cron | dispatch window | schedule_window |
|---|---|---|---|
| critical | `*/15` | `-20m@m` → `-5m@m` | 600 |
| high | hourly at `:12` | `-70m@m` → `-10m@m` | 2400 |
| medium | every 2h at `:42` | `-130m@m` → `-10m@m` | 3600 |

~1480 dispatches/hour. Both dispatch bounds are **snapped and absolute**,
which is what makes `schedule_window` safe: a search that runs 30 minutes
late still covers the same slice. With `latest = now` a delayed run would
silently shift its window, producing gaps and duplicate alerts.

The `-10m` lag on the upper bound absorbs indexing delay.

Watch for skipped executions after the first week:

```
index=_internal sourcetype=scheduler app=Sigma_Alerts earliest=-7d
| stats count by status
```

## Alerting

`alert.severity` is set (critical → 5, high → 4, medium → 3) and the level is
in the subject line as `[SEV-HIGH]`, so the SOC mailbox sorts and filters.
Throttling is on by default: `alert.suppress.fields = host`, period 1h.

Change the recipient in `templates/postprocess-savedsearches.yml`.

## Validation gates

The build aborts on any of:

- duplicate stanza names
- duplicate macro names
- stanza count ≠ unique rule IDs (catches stale duplicate rule files)
- any search missing its macro reference
- any macro sitting after a deferred command (`| regex`, `| where cidrmatch`)
  — that is invalid SPL and the search errors out at runtime
- any double-quoted `{}` field name surviving the quoting fix

Plus warnings when a builtin-channel search references a field the non-XML TA
does not emit.

## Field mappings

Windows and cloud field names were verified against real events rather than
inferred. The pipelines carry the details; the significant ones:

| Sigma field | maps to | notes |
|---|---|---|
| `ImagePath` | `Service_File_Name` | 7045 service installs, ~95 rules |
| `ServiceFileName` | `Service_File_Name` | 4697 |
| `Provider_Name` | `SourceName` | non-XML has no `Provider_Name` |
| `Channel` | `LogName` | |
| `LogonProcessName` | `Logon_Process` | not `Logon_Process_Name` |
| `MemberName` | `Member_Account_Name` | 4728/4732 |
| `MemberSid` | `Member_Security_ID` | |
| `AccessList` | `Accesses` | 4663 |
| `SamAccountName` | `SAM_Account_Name` | 4720 |
| `riskEventType` | `riskEventTypes_v2{}` | confirmed from a raw sign-in event |
| `properties.message` | `activityDisplayName` | Sentinel column leaking into azure rules |

Sysmon needs **no mapping** — `TA-microsoft-sysmon` preserves the native
names (`Image`, `CommandLine`, `ParentImage`, `TargetObject`,
`TargetFilename`, `ImageLoaded`, `CallTrace`, `GrantedAccess`, `PipeName`,
`QueryName`, `Details`), all confirmed against sampled events.

If you deploy to a tenant with a different TA version, re-verify before
trusting the build:

```
index=windows earliest=-24h EventCode IN (4688,4697,4720,4728,4732,5140,7045)
| dedup EventCode, source
| fields - _* punct linecount date_* timestartpos timeendpos splunk_server* eventtype tag*
| foreach * [ eval flist = if(isnotnull('<<FIELD>>') AND '<<FIELD>>'!="", mvappend(flist,"<<FIELD>>"), flist) ]
| eval fields = mvjoin(flist,", ")
| table source, EventCode, fields
```

## Known limits

**Sigma's azure rules are inconsistent and partly Sentinel-authored.** Case
varies within the same directory (`Category`/`category`,
`OperationName`/`operationName`) and there are typos (`Initiatedby`,
`Resultdescription`), so every observed spelling is mapped explicitly. Some
rules reference Sentinel workbook columns rather than log fields and can
never fire — `ActivityDetails: Sign-ins`, `Username: 'UPN'`. Expect a handful
of duds in `signin_logs` specifically.

**Sigma's `Status` is a blob.** Sentinel packs result, resultReason and
additionalDetails into one field; Graph splits them. The right target depends
on the *value*, which a field mapping cannot branch on. Rule-scoped overrides
handle the exceptions — see the top of `secureon-cloud.yml`. If that section
grows past a handful, move it to its own pipeline file.

**Sigma has almost no account-management coverage.** Group membership
changes, account lifecycle, lockouts and privileged group additions are
mostly absent or rated `low`, because which groups are privileged is
site-specific. Those detections have to be hand-written alongside this app;
they are not redundant with it.

**A Sysmon include-list config silently caps coverage.** With
`onmatch="include"` on ProcessCreate, ImageLoad, RegistryEvent, FileCreate,
NetworkConnect and ProcessAccess, Sysmon only emits events matching the
listed patterns. Rules looking for anything else never see an event, however
correct the SPL. Check what you actually receive:

```
index=windows source="WinEventLog:Microsoft-Windows-Sysmon/Operational" earliest=-24h
| stats count by EventCode | sort -count
```

**Rules on channels you do not collect are inert.** Roughly 130 of the
windows-builtin rules target PowerShell, Defender, TaskScheduler, DNS Client,
BITS and WMI-Activity. They cost scheduler slots and match nothing. Either
collect those channels — 4104 script block logging is the highest-value one —
or drop the directories from `filter_rules.py`.
