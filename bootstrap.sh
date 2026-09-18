#!/bin/bash
#
# One-shot setup for the build VM. Idempotent - safe to re-run after a
# `git pull` to pick up new dependencies.
#
#   ./bootstrap.sh
#
# Environment overrides:
#   SIGMA_REPO=/opt/sigma     where the SigmaHQ rules live
#   SKIP_APT=1                skip the apt step (no sudo available)
#
set -euo pipefail

WORKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGMA_REPO="${SIGMA_REPO:-/opt/sigma}"
VENV="$WORKING_DIR/venv"
SKIP_APT="${SKIP_APT:-0}"

ok()   { echo "  [ok]   $*"; }
info() { echo "  [..]   $*"; }
warn() { echo "  [warn] $*" >&2; }
die()  { echo "  [FAIL] $*" >&2; exit 1; }

echo "==> Build tree: $WORKING_DIR"
echo "==> Sigma repo: $SIGMA_REPO"

# ------------------------------------------------------------------ 1. apt
echo
echo "==> System packages"
if [[ "$SKIP_APT" == "1" ]]; then
    info "skipped (SKIP_APT=1)"
else
    missing=()
    command -v git      >/dev/null || missing+=(git)
    command -v python3  >/dev/null || missing+=(python3)
    python3 -c "import venv" 2>/dev/null || missing+=(python3-venv)
    python3 -c "import yaml" 2>/dev/null || missing+=(python3-yaml)
    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "git, python3, venv, yaml present"
    else
        info "installing: ${missing[*]}"
        sudo apt-get update -qq
        sudo apt-get install -y -qq "${missing[@]}"
        ok "installed"
    fi
fi

# ----------------------------------------------------------------- 2. venv
#
# Ubuntu 24.04 ships an externally-managed Python (PEP 668). Installing
# sigma-cli with system pip leaves `sigma plugin install` broken, because it
# shells out to `python -m pip install` without --break-system-packages. A
# venv avoids that entirely.
#
echo
echo "==> Python environment"
if [[ -x "$VENV/bin/sigma" ]]; then
    ok "venv exists: $($VENV/bin/sigma version 2>/dev/null | head -1)"
else
    info "creating venv"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install --quiet --upgrade pip
    info "installing sigma-cli"
    "$VENV/bin/pip" install --quiet sigma-cli
    ok "sigma-cli $($VENV/bin/sigma version 2>/dev/null | head -1)"
fi

# -------------------------------------------------------------- 3. plugins
#
# Both are required. The Splunk backend ships splunk_windows,
# splunk_sysmon_acceleration and splunk_cim; the `sysmon` pipeline (Sigma
# categories -> Sysmon EventIDs) is a separate package.
#
echo
echo "==> sigma-cli plugins"
have_pipelines=$("$VENV/bin/sigma" list pipelines 2>/dev/null || true)
for plug in splunk sysmon; do
    case "$plug" in
        splunk) probe="splunk_windows" ;;
        sysmon) probe="| sysmon " ;;
    esac
    if grep -q "$probe" <<< "$have_pipelines"; then
        ok "$plug already installed"
    else
        info "installing plugin: $plug"
        "$VENV/bin/sigma" plugin install "$plug" >/dev/null
        ok "$plug installed"
    fi
done
echo
"$VENV/bin/sigma" list pipelines | sed 's/^/    /'

# ----------------------------------------------------------- 4. sigma rules
echo
echo "==> SigmaHQ rules"
if [[ -d "$SIGMA_REPO/.git" ]]; then
    if git -C "$SIGMA_REPO" pull --quiet 2>/dev/null; then
        ok "updated $SIGMA_REPO"
    else
        warn "could not pull $SIGMA_REPO"
        warn "if this is 'dubious ownership', run: sudo chown -R \$USER $SIGMA_REPO"
    fi
else
    info "cloning into $SIGMA_REPO"
    if [[ -w "$(dirname "$SIGMA_REPO")" ]]; then
        git clone --quiet https://github.com/SigmaHQ/sigma.git "$SIGMA_REPO"
    else
        sudo git clone --quiet https://github.com/SigmaHQ/sigma.git "$SIGMA_REPO"
        sudo chown -R "$USER":"$USER" "$SIGMA_REPO"
    fi
    ok "cloned"
fi
echo "    rules: $(find "$SIGMA_REPO/rules" -name '*.yml' 2>/dev/null | wc -l)"

# ------------------------------------------------------------- 5. app files
#
# skel/app.conf and skel/default.meta are the real app metadata and belong in
# the repository, committed from a workstation. The build host only reads
# them, so `git pull` never conflicts.
#
echo
echo "==> App metadata"
for f in skel/app.conf skel/default.meta skel/bin/README \
         skel/default/data/ui/nav/default.xml VERSION; do
    [[ -r "$WORKING_DIR/$f" ]] || die "missing: $f"
done
ok "skel/ complete"

if grep -q "Replace this file" "$WORKING_DIR/skel/app.conf" 2>/dev/null; then
    warn "skel/app.conf is still the placeholder."
    warn "Commit your deployed app.conf to the repo, or the app metadata"
    warn "at the clients will be replaced by the sample."
fi
if grep -q "Replace with the metadata" "$WORKING_DIR/skel/default.meta" 2>/dev/null; then
    warn "skel/default.meta is still the placeholder - same caveat."
fi
ok "version base: $(tr -d '[:space:]' < "$WORKING_DIR/VERSION")"

# ------------------------------------------------------------------ 6. done
echo
echo "==> Ready. Build with:"
echo
echo "      cd $WORKING_DIR && bash generate_sigma_app.sh"
echo
echo "    Output lands in sigma_versions/ as a dated tarball. Copy it to the"
echo "    client search head and extract over \$SPLUNK_HOME/etc/apps/ -"
echo "    default/ is replaced, local/ (your exception macros) is untouched."
echo
