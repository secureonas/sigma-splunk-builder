# Sigma build host — Ubuntu setup

**For a normal setup, run `bash bootstrap.sh` — it does sections 1 to 5 below.**
The rest of this file explains what it does and why, and is worth reading once
if something goes wrong.


Everything below was run and validated on 2026-09-18. Versions installed:

| Package | Version |
|---|---|
| sigma-cli | 3.1.0 |
| pySigma | 1.5.0 |
| pysigma-backend-splunk | 2.1.0 |
| pysigma-pipeline-sysmon | 2.0.0 |

## 1. Base packages

Ubuntu 24.04 LTS:

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip git
```

## 2. sigma-cli — use a venv, not system pip

This matters. Ubuntu 24.04 ships an externally-managed Python (PEP 668), so
`pip install` into the system interpreter is blocked. If you install sigma-cli
with `pip --break-system-packages`, the CLI itself works but
**`sigma plugin install` fails** — it shells out to `python -m pip install`
without the override flag:

```
subprocess.CalledProcessError: Command '['/usr/bin/python3', '-m', 'pip', '-q',
'--disable-pip-version-check', 'install', 'pysigma-backend-splunk==2.1.0']'
returned non-zero exit status 1
```

You then get `No pipelines. Use sigma plugin list to list available plugins.`
and every conversion fails. Use a venv (or pipx):

```bash
cd /opt/sigma-build
python3 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install sigma-cli
```

Add to `~/.bashrc` so `sigma` resolves without the venv path:

```bash
echo 'export PATH="/opt/sigma-build/venv/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
sigma version
```

`pipx install sigma-cli` also works — pipx puts the CLI in its own venv, so
`sigma plugin install` installs into that venv correctly.

## 3. Backend and pipeline plugins

```bash
sigma plugin install splunk
sigma plugin install sysmon
```

Expected output for each:

```
Successfully installed plugin 'splunk'
pySigma version is compatible with sigma-cli
```

Verify:

```bash
sigma list pipelines
```

```
+----------------------------+----------+----------------------------------------------------+
| Identifier                 | Priority | Processing Pipeline                                |
+----------------------------+----------+----------------------------------------------------+
| splunk_windows             | 20       | Splunk Windows log source conditions               |
| splunk_sysmon_acceleration | 25       | Splunk Windows Sysmon search acceleration keywords |
| splunk_cim                 | 20       | Splunk CIM Data Model Mapping                      |
| sysmon                     | 10       | Generic Log Sources to Sysmon Transformation       |
+----------------------------+----------+----------------------------------------------------+
```

Both plugins are required. The Splunk backend only ships `splunk_windows`,
`splunk_sysmon_acceleration` and `splunk_cim` — the `sysmon` pipeline (which
maps Sigma's generic categories like `process_creation` onto Sysmon EventIDs)
comes from the separate `pysigma-pipeline-sysmon` package.

Do **not** add `splunk_cim` to any of our runs. It rewrites fields into CIM
data-model names, which is the opposite of what we need.

## 4. Sigma rules

```bash
cd /opt
sudo git clone https://github.com/SigmaHQ/sigma.git
sudo chown -R "$USER" /opt/sigma
```

Shallow clone is fine (`--depth 1`) — roughly 62 MB either way.

## 5. Build tree

```bash
mkdir -p /opt/sigma-build/{pipelines,templates,skel}
cd /opt/sigma-build
```

Copy in from this bundle:

```
/opt/sigma-build/
├── filter_rules.py
├── generate_sigma_app.sh
├── pipelines/
│   ├── secureon-windows-builtin.yml
│   ├── secureon-sysmon.yml
│   ├── secureon-cloud.yml
│   └── secureon-linux.yml
└── templates/
    ├── postprocess-savedsearches.yml
    └── create-macro.yml
```

Then populate `skel/` from your **current** app — these are the static files
the build no longer takes from a live directory:

```bash
cd /opt/sigma-build/skel
cp /path/to/Sigma_Alerts/default/app.conf          ./app.conf
cp /path/to/Sigma_Alerts/metadata/default.meta     ./default.meta
cp /path/to/Sigma_Alerts/bin/README                ./bin_README
cp -r /path/to/Sigma_Alerts/default/data           ./data
```

Do **not** copy `metadata/local.meta`. That is per-instance state; shipping it
pushes one client's ownership records and macro ACLs to every other client.

The script locates itself — `WORKING_DIR` is wherever `generate_sigma_app.sh`
lives, so there is nothing to edit. `staging/`, `build/` and `sigma_versions/`
are created beside it. Override the rule repo with `SIGMA_REPO=/path ./generate_sigma_app.sh`
if it isn't at `/opt/sigma`.

If `venv/` sits next to the script it is added to `PATH` automatically, so the
build works from cron without sourcing anything.

```bash
chmod +x /opt/sigma-build/generate_sigma_app.sh
chmod 644 /opt/sigma-build/filter_rules.py
```

## 5a. One user, consistently

Pick the build user and give it the whole tree. Mixing `alen` and `root` causes
two failures:

```bash
sudo chown -R alen:alen /opt/sigma /opt/sigma-build
```

Without this, running as root against a repo owned by `alen` gives:

```
fatal: detected dubious ownership in repository at '/opt/sigma'
```

`git config --global --add safe.directory /opt/sigma` silences it, but only for
whichever user ran it — cron under a different account hits it again. Owning
the tree is the durable fix. Nothing in the build needs root.

## 6. Build

```bash
cd /opt/sigma-build
./generate_sigma_app.sh
```

Validated output on today's SigmaHQ main:

```
  windows-builtin      449 rules
  windows-sysmon       895 rules
  cloud                 75 rules
  linux                 21 rules
  TOTAL               1440 rules

    stanzas=1440 unique=1440
    macros=1440 unique=1440
    macro refs=1440  unique rule ids=1440
```

The build aborts if stanza names collide, macro names collide, stanza count
differs from unique rule IDs, any search is missing its macro, or any macro
lands after a deferred command.

Field-level check against the old build:

| | Old | New |
|---|---|---|
| `Service_File_Name` | 0 | 94 |
| `Provider_Name` (non-existent field) | 48 | 0 |
| `Channel=` (non-existent field) | 18 | 0 |
| macro after `\| regex` (invalid SPL) | 14 | 0 |

## 7. Deploy

```bash
scp /opt/sigma-build/sigma_versions/sigma_alerts_YYYY-MM-DD.tar.gz \
    searchhead:/tmp/
ssh searchhead
cd /opt/splunk/etc/apps
tar -xzf /tmp/sigma_alerts_YYYY-MM-DD.tar.gz
/opt/splunk/bin/splunk btool savedsearches list --debug-app=Sigma_Alerts 2>&1 | grep -i error
/opt/splunk/bin/splunk reload savedsearch -auth admin:xxx
```

Extracting over the existing directory replaces `default/` and leaves `local/`
alone — which is what keeps the client exception macros in place.

After the first build, check for skipped searches:

```
index=_internal sourcetype=scheduler status IN (skipped,deferred) app=Sigma_Alerts
| stats count by reason
```

## 8. Optional: cron

```bash
crontab -e
```

```
0 4 * * 1 /opt/sigma-build/generate_sigma_app.sh >> /var/log/sigma-build.log 2>&1
```

Weekly is plenty — SigmaHQ merges continuously but the delta over a week is
small, and you want to review the diff before pushing to clients rather than
having a tarball appear unattended.

## Known issues on first build

**PowerShell rules (163) may be dead at some clients.** `windows-builtin` now
includes `rules/windows/powershell`, but the 24h source inventory at Calcit has
no PowerShell channel — no `WinEventLog:Microsoft-Windows-PowerShell/Operational`
and no `WinEventLog:Windows PowerShell`. Check per client:

```
| tstats count where index=windows earliest=-24h by source
```

If the channel is missing, either start collecting it (script block logging,
Event 4104, is one of the highest-value Windows detections you don't currently
have) or drop `rules/windows/powershell` from the group.

**Some `signin_logs` rules are written against Sentinel column names, not real
log fields.** Two examples from today's build:

```
sourcetype="azure:aad:signin" status.errorCode="Success" ...
```

`status.errorCode` is numeric — `0` for success, not the string `Success`.
These rules were authored against a Sentinel workbook. Expect a handful of the
75 cloud rules to be silently non-firing; they need individual review, not a
pipeline fix.

**The 19 Identity Protection rules are not in the build.** They key on
`riskEventType`, which in sign-in logs is the multivalue array
`riskEventTypes{}`. The Splunk backend quotes field names containing `{}` with
double quotes, producing a string literal instead of a field reference. Rather
than patch the backend again, hand-write those 19 — each is a single-field
match:

```
index=o365 sourcetype="azure:aad:signin" riskState=atRisk
"riskEventTypes{}"="impossibleTravel"
```

Confirm the exact field name on a real risky sign-in first; the sample event
you sent had `riskState=none`, so the array was absent.
