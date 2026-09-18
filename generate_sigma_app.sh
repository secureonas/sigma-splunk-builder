#!/bin/bash
#
# Build the Sigma_Alerts Splunk app.
#
# Contract that must NOT change (clients have exception macros keyed on it):
#   - app name           Sigma_Alerts
#   - macro file         default/macros.conf
#   - macro stanza name  [<sigma rule uuid>]
#   - macro definition   *
#   - macro reference    placed at the end of the BASE search
#
set -euo pipefail

# Everything is relative to the directory this script lives in, so the tree
# can be cloned anywhere. Override SIGMA_REPO / STAGING via the environment
# if you keep them elsewhere.
WORKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIGMA_REPO="${SIGMA_REPO:-/opt/sigma}"
STAGING="${STAGING:-$WORKING_DIR/staging}"
BUILD="$WORKING_DIR/build"
APP="$BUILD/Sigma_Alerts"
ARCHIVE_DIR="$WORKING_DIR/sigma_versions"
PIPE="$WORKING_DIR/pipelines"
TPL="$WORKING_DIR/templates"
CURRENT_DATE=$(date +"%Y-%m-%d")

# sigma must be on PATH. If you installed into a venv next to this script,
# pick it up automatically.
if [[ -x "$WORKING_DIR/venv/bin/sigma" ]]; then
    PATH="$WORKING_DIR/venv/bin:$PATH"
fi
command -v sigma >/dev/null || {
    echo "sigma not found on PATH. Activate the venv or add it to PATH." >&2
    exit 1
}

for f in "$PIPE/secureon-windows-builtin.yml" "$TPL/postprocess-savedsearches.yml" \
         "$TPL/create-macro.yml" "$WORKING_DIR/filter_rules.py" \
         "$WORKING_DIR/VERSION" "$WORKING_DIR/skel/app.conf" \
         "$WORKING_DIR/skel/default.meta"; do
    [[ -r "$f" ]] || { echo "missing or unreadable: $f" >&2; exit 1; }
done

echo "==> Working dir: $WORKING_DIR"
echo "==> Sigma repo:  $SIGMA_REPO"

echo "==> Updating Sigma repository"
if ! git -C "$SIGMA_REPO" pull --quiet 2>/dev/null; then
    echo "    git pull failed - continuing with the checkout as-is." >&2
    echo "    If this is the 'dubious ownership' error, run:" >&2
    echo "      sudo chown -R \$USER $SIGMA_REPO" >&2
fi

echo "==> Staging rules"
python3 "$WORKING_DIR/filter_rules.py" --sigma-repo "$SIGMA_REPO" --out "$STAGING"

echo "==> Preparing build tree"
rm -rf "${BUILD:?}"
mkdir -p "$APP/default" "$APP/metadata" "$APP/bin"

SS="$BUILD/savedsearches.conf"
MC="$BUILD/macros.conf"
: > "$SS"
: > "$MC"

convert_group () {
    local group="$1"; shift
    local dir="$STAGING/$group"
    [[ -d "$dir" ]] || { echo "    (no rules for $group)"; return; }
    local n; n=$(find "$dir" -name '*.yml' | wc -l)
    [[ "$n" -gt 0 ]] || { echo "    (no rules for $group)"; return; }
    echo "    $group: $n rules"

    sigma convert -t splunk "$@" \
        -p "$TPL/postprocess-savedsearches.yml" \
        --skip-unsupported -o "$BUILD/$group.savedsearches" "$dir"/*.yml \
        2>&1 | grep -v '^Parsing Sigma rules$' || true

    sigma convert -t splunk "$@" \
        -p "$TPL/create-macro.yml" \
        --skip-unsupported -o "$BUILD/$group.macros" "$dir"/*.yml \
        2>&1 | grep -v '^Parsing Sigma rules$' || true

    # Strip the [default] stanza from every run except the first; it is
    # emitted by the finalizer each time and must appear only once.
    if [[ -s "$SS" ]]; then
        sed '/^\[default\]$/,/^$/d' "$BUILD/$group.savedsearches" >> "$SS"
    else
        cat "$BUILD/$group.savedsearches" >> "$SS"
    fi
    cat "$BUILD/$group.macros" >> "$MC"
}

echo "==> Converting"
convert_group "windows-builtin" -p splunk_windows -p "$PIPE/secureon-windows-builtin.yml"
convert_group "windows-sysmon"  -p sysmon -p splunk_windows -p "$PIPE/secureon-sysmon.yml"
convert_group "cloud"           -p "$PIPE/secureon-cloud.yml"
convert_group "linux"           -p "$PIPE/secureon-linux.yml"

# The Splunk backend quotes field names that are not [\w.]+ with double
# quotes. In SPL "a{}.b"="x" compares two strings; 'a{}.b'="x" matches a
# field. Rewrite those to single quotes. Only touches names containing {}.
echo "==> Fixing {} field quoting"
BEFORE=$( { grep -o '"[A-Za-z][A-Za-z0-9_.]*{}[A-Za-z0-9_.{}]*"=' "$SS" || true; } | wc -l)
sed -i -E "s/\"([A-Za-z][A-Za-z0-9_.]*\{\}[A-Za-z0-9_.{}]*)\"=/'\1'=/g" "$SS"
AFTER=$( { grep -o '"[A-Za-z][A-Za-z0-9_.]*{}[A-Za-z0-9_.{}]*"=' "$SS" || true; } | wc -l)
echo "    rewrote $((BEFORE-AFTER)) field references"

echo "==> Validating"
fail=0

STANZAS=$(grep -c '^\[Sigma - ' "$SS" || true)
MACROS=$(grep -c '^\[' "$MC" || true)
REFS=$( { grep -o '`[0-9a-f-]\{36\}`' "$SS" || true; } | wc -l)
UNIQ_IDS=$( { grep -o 'ID: [0-9a-f-]\{36\}' "$SS" || true; } | sort -u | wc -l)
UNIQ_STANZA=$( { grep '^\[Sigma - ' "$SS" || true; } | sort -u | wc -l)
UNIQ_MACRO=$( { grep '^\[' "$MC" || true; } | sort -u | wc -l)

echo "    stanzas=$STANZAS unique=$UNIQ_STANZA"
echo "    macros=$MACROS unique=$UNIQ_MACRO"
echo "    macro refs=$REFS  unique rule ids=$UNIQ_IDS"

[[ "$STANZAS" -eq "$UNIQ_STANZA" ]] || { echo "    FAIL: duplicate stanza names"; fail=1; }
[[ "$MACROS"  -eq "$UNIQ_MACRO"  ]] || { echo "    FAIL: duplicate macro names"; fail=1; }
[[ "$STANZAS" -eq "$UNIQ_IDS"    ]] || { echo "    FAIL: stanza count != unique rule ids"; fail=1; }
[[ "$REFS"    -eq "$STANZAS"     ]] || { echo "    FAIL: not every search references its macro"; fail=1; }

# No macro may sit after a deferred command - that is invalid SPL.
BADSPL=$(grep -c '| regex [^|]*`[0-9a-f-]\{36\}`\|cidrmatch[^|]*`[0-9a-f-]\{36\}`' "$SS" || true)
[[ "$BADSPL" -eq 0 ]] || { echo "    FAIL: $BADSPL searches have the macro after a deferred command"; fail=1; }

# No double-quoted {} field names may survive.
BADQ=$(grep -c '"[A-Za-z][A-Za-z0-9_.]*{}[A-Za-z0-9_.{}]*"=' "$SS" || true)
[[ "$BADQ" -eq 0 ]] || { echo "    FAIL: $BADQ double-quoted {} field names remain"; fail=1; }

# Field names that do not exist in non-XML WinEventLog.
for bad in Provider_Name Channel OriginalFileName Logon_Process_Name; do
    # OriginalFileName is legitimate in Sysmon rules, so only check the
    # builtin output for it.
    c=$(grep -c "source=\"WinEventLog:\(Security\|System\|Application\)\"[^|]*[ (]$bad=" "$SS" || true)
    [[ "$c" -eq 0 ]] || echo "    WARN: $c builtin searches reference $bad"
done

[[ "$fail" -eq 0 ]] || { echo "==> BUILD FAILED"; exit 1; }

echo "==> Assembling app"
cp "$SS" "$APP/default/savedsearches.conf"
cp "$MC" "$APP/default/macros.conf"
cp "$WORKING_DIR/skel/app.conf"     "$APP/default/app.conf"
cp -r "$WORKING_DIR/skel/default/data" "$APP/default/"
cp "$WORKING_DIR/skel/default.meta" "$APP/metadata/default.meta"
cp "$WORKING_DIR/skel/bin/README"   "$APP/bin/README"

# Version lives in the VERSION file so it is tracked in git rather than
# mutated inside skel/. Patch level is bumped on every build.
CUR=$(tr -d '[:space:]' < "$WORKING_DIR/VERSION")
IFS='.' read -r -a V <<< "$CUR"
NEW="${V[0]}.${V[1]}.$((V[2] + 1))"
echo "$NEW" > "$WORKING_DIR/VERSION"
sed -i "s/^description = .*/description = sigma rules clone $CURRENT_DATE/" "$APP/default/app.conf"
sed -i "s/^version = .*/version = $NEW/" "$APP/default/app.conf"
echo "    version $CUR -> $NEW  (commit VERSION after a successful build)"

echo "==> Orphan macro report"
# Exception macros at a client whose rule no longer exists upstream.
{ grep -o '^\[[0-9a-f-]\{36\}\]' "$MC" || true; } | tr -d '[]' | sort > "$BUILD/current_ids.txt"
echo "    current rule ids written to $BUILD/current_ids.txt"
echo "    compare against each client's local/macros.conf to find prunable exceptions:"
echo "      grep -o '^\\[[0-9a-f-]\\{36\\}\\]' local/macros.conf | tr -d '[]' | sort > local_ids.txt"
echo "      comm -23 local_ids.txt $BUILD/current_ids.txt"

echo "==> Packaging"
mkdir -p "$ARCHIVE_DIR"
TAR="$ARCHIVE_DIR/sigma_alerts_$CURRENT_DATE.tar.gz"
tar -czf "$TAR" -C "$BUILD" \
    --exclude='metadata/local.meta' \
    --exclude='local' \
    "Sigma_Alerts"
echo "    $TAR"
echo "==> Done"
