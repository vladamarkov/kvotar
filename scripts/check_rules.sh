#!/bin/bash
# Static checks for Kvotar's absolute rules (STEP_239). Usage: scripts/check_rules.sh
#
# Static checks catch drift; the behavior tests are the protection (docs/safety-checks.md).
# Everything here is lexical — string concatenation fools it. It is a tripwire for honest mistakes
# by contributors and agents, not a proof.
#
#   R1 never store prompts, code, transcripts, tool outputs or refresh tokens
#   R2 never write credential files (~/.claude/, ~/.codex/auth.json, the Keychain)
#   R3 never refresh an OAuth or Codex token; no refresh trigger of any shape
#   R4 read-only credential posture: the Claude token only via `security find-generic-password`
#
# Each failure prints `R<n> <file>:<line>: <what>`. Exceptions live in scripts/check_rules.exceptions
# (file<TAB>pattern<TAB>reason); an exception whose pattern is no longer in its file fails the run.
# Bash 3.2 + grep + find only, so it runs on a clean Mac.
set -uo pipefail
cd "$(dirname "$0")/.."

EXCEPTIONS="scripts/check_rules.exceptions"
FAILED=0
fail() { echo "$1"; FAILED=1; }

# Every text file under the shipped source trees, nested folders included (no globstar in 3.2).
SOURCES=$(find Packages/*/Sources App -type f -not -path '*/.build/*' 2>/dev/null | sort)
[ -n "$SOURCES" ] || { echo "check_rules: no sources found" >&2; exit 2; }

# True when `file` has an exception whose pattern occurs in `text`.
excepted() {
    local file="$1" text="$2" efile pattern reason
    [ -f "$EXCEPTIONS" ] || return 1
    while IFS=$'\t' read -r efile pattern reason; do
        case "$efile" in ''|'#'*) continue ;; esac
        if [ "$efile" = "$file" ] && [[ "$text" == *"$pattern"* ]]; then return 0; fi
    done < "$EXCEPTIONS"
    return 1
}

# scan RULE GREP_FLAGS REGEX MESSAGE ALLOWED_FILE_REGEX
# Fails on every matching line outside the allowed files that no exception covers.
scan() {
    local rule="$1" flags="$2" regex="$3" message="$4" allowed="${5:-}" hit file rest line text
    while IFS= read -r hit; do
        file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
        if [ -n "$allowed" ] && [[ "$file" =~ $allowed ]]; then continue; fi
        excepted "$file" "$text" && continue
        fail "$rule $file:$line: $message"
    done < <(echo "$SOURCES" | xargs grep -n -I $flags -E -- "$regex" 2>/dev/null)
}

# --- R2: no Keychain writes --------------------------------------------------------------------
scan R2 "" 'SecItem(Add|Update|Delete)' "Keychain write API"

# --- R2/R4: the security tool only ever reads -------------------------------------------------
while IFS= read -r hit; do
    file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; match="${rest#*:}"
    [ "$match" = "find-generic-password" ] && continue
    excepted "$file" "$match" && continue
    fail "R2/R4 $file:$line: security subcommand '$match' (only find-generic-password is allowed)"
done < <(echo "$SOURCES" | xargs grep -n -o -I -E -- '[a-z]+-(generic|internet)-password|[a-z]+-keychain' 2>/dev/null)
scan R4 "" '"/usr/bin/security"' "/usr/bin/security launched outside KeychainTokenProvider" \
    'ClaudeAdapter/KeychainTokenProvider\.swift$'

# --- R3: no refresh strings or token endpoints ------------------------------------------------
scan R3 "-i" 'refresh_?token|grant_type|/oauth2?/token|auth\.openai\.com|console\.anthropic\.com' \
    "refresh token, grant type or token endpoint"

# --- R2: file writes only in the approved writers ---------------------------------------------
# A new writer fails here. A bad destination inside an approved writer is the behavior test's job
# (CredentialTreesUntouchedTests).
#   SQLiteStore + migrations  the app database        LogFileWriter   the log ring
#   PIDLock                   the single-instance lock LegacyDataMigrator  copy-only AgentPilot import
#   DiagnosticsBundle         the user-requested zip   ProductIdentity creates the support folder
#   CLI BundleReader          expands a bundle to tmp  CLI AnalysisStore   the import corpus (STEP_74)
WRITERS='(KvotarCore/Storage/SQLiteStore[^/]*|KvotarCore/Logging/LogFileWriter|KvotarCore/Lifecycle/PIDLock|KvotarCore/Storage/LegacyDataMigrator|KvotarCore/Diagnostics/DiagnosticsBundle|KvotarCore/ProductIdentity|KvotarCLI/BundleReader|KvotarCLI/AnalysisStore)\.swift$'
scan R2 "" 'write\(to:|createFile|moveItem|copyItem|removeItem|replaceItemAt|createDirectory|O_CREAT|O_WRONLY|DatabasePool\(|DatabaseQueue\(|VACUUM INTO' \
    "file write outside the approved writers" "$WRITERS"

# --- R3: network hosts --------------------------------------------------------------------------
#   api.anthropic.com, chatgpt.com  quota API traffic     claude.ai  user-facing links only
#   updates.kvotar.com              Sparkle feed, Info.plist only
#   www.apple.com/DTDs/             property-list headers
while IFS= read -r hit; do
    file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; url="${rest#*:}"
    host="${url#*://}"; host="${host%%/*}"
    case "$host" in
        api.anthropic.com|chatgpt.com|claude.ai) continue ;;
        updates.kvotar.com) [ "$file" = "App/Info.plist" ] && continue ;;
        www.apple.com) [[ "$url" == */DTDs/* ]] && continue ;;
    esac
    excepted "$file" "$url" && continue
    fail "R3 $file:$line: network host '$host' is not on the known list"
done < <(echo "$SOURCES" | xargs grep -n -o -I -E -- 'https?://[A-Za-z0-9.-]+(/DTDs/)?' 2>/dev/null)

# --- R2/R4: process launches only from the known sites ----------------------------------------
#   KeychainTokenProvider      /usr/bin/security find-generic-password (the Claude token)
#   CodexProcessTransportLive  codex app-server (quota RPC)
#   CodexRPCSeams              /usr/bin/env which codex (binary discovery)
#   DiagnosticsBundle          ditto (the zip), zsh -lc "<tool> --version", codex --version
#   CLI BundleReader           ditto -x (expands a bundle)
LAUNCHERS='(ClaudeAdapter/KeychainTokenProvider|CodexAdapter/CodexProcessTransportLive|CodexAdapter/CodexRPCSeams|KvotarCore/Diagnostics/DiagnosticsBundle|KvotarCLI/BundleReader)\.swift$'
scan R2/R4 "" 'Process\(\)|NSTask|posix_spawn' "process launch outside the known sites" "$LAUNCHERS"

# --- Exceptions must still match something -----------------------------------------------------
if [ -f "$EXCEPTIONS" ]; then
    n=0
    while IFS=$'\t' read -r efile pattern reason; do
        n=$((n + 1))
        case "$efile" in ''|'#'*) continue ;; esac
        if [ ! -f "$efile" ] || ! grep -qF -- "$pattern" "$efile"; then
            fail "EXC $EXCEPTIONS:$n: stale exception — '$pattern' no longer in $efile"
        fi
    done < "$EXCEPTIONS"
fi

# --- Agent docs: every repository path they name must exist ------------------------------------
# Private layout (oss/overlay/ present): the agent files, skills and the public overlay, whose paths
# resolve at the root or inside the overlay. Exported layout: the root and docs/ markdown.
# Only backticked tokens whose first segment is a top-level folder count; placeholders are skipped.
if [ -d oss/overlay ]; then
    DOCS=$( { ls AGENTS.md CLAUDE.md 2>/dev/null; find .claude/skills oss/overlay -name '*.md' 2>/dev/null; } | sort)
else
    DOCS=$( { ls ./*.md 2>/dev/null | sed 's|^\./||'; find docs .claude/skills -name '*.md' 2>/dev/null; } | sort)
fi
for doc in $DOCS; do
    while IFS= read -r hit; do
        line="${hit%%:*}"; path="${hit#*:}"; path="${path#\`}"; path="${path%\`}"; path="${path%%:*}"
        case "$path" in *'*'*|*'<'*|*'...'*|*'{'*) continue ;; esac
        case "${path%%/*}" in
            App|AppTests|Packages|Resources|scripts|docs|oss|.claude|TASKS|planning|site|prototypes) ;;
            *) continue ;;
        esac
        [ -e "$path" ] || [ -e "oss/overlay/$path" ] && continue
        fail "DOC $doc:$line: names '$path', which does not exist"
    done < <(grep -n -o -E '`[A-Za-z0-9_.-]+/[^` ]*`' "$doc" 2>/dev/null)
done

if [ "$FAILED" -ne 0 ]; then
    echo "FAIL (scripts/check_rules.sh)"
    exit 1
fi
echo "PASS (scripts/check_rules.sh)"
