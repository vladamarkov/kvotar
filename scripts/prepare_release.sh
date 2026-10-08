#!/bin/bash
# Writes and pushes the release-bump commit (docs/releasing.md, step 1). Usage: make prepare-release
#
# On `main`, with a clean tree that is not behind `origin/main`, it raises the build number and the
# beta label in project.yml by one, repeats the new values on the updates and releases page, opens a
# changelog section for them under "Unreleased", runs `make check`, commits `Bump to <version>
# <label> (<build>)` and pushes. It refuses, with one line and no change, when a precondition fails.
# The push to `main` is the maintainer's release bump (CONTRIBUTING.md, "Merging").
#
# Bash 3.2, git and python3 only, so it runs on a clean Mac. Nothing here builds, signs or tags.
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT=project.yml
SPEC=docs/spec/updates-and-releases.md
CHANGELOG=CHANGELOG.md
RELEASES=https://github.com/vladamarkov/kvotar/releases/tag

refuse() { echo "prepare_release: $1" >&2; exit 1; }

# --- Preconditions: nothing below changes a file until all of these hold ------------------------
[ "$(git rev-parse --abbrev-ref HEAD)" = main ] || refuse "not on main"
[ -z "$(git status --porcelain --untracked-files=no)" ] || refuse "the tree is not clean"
git fetch -q origin main || refuse "cannot fetch origin"
[ "$(git rev-list --count HEAD..origin/main)" = 0 ] || refuse "main is behind origin/main"

version=$(sed -n 's/^ *MARKETING_VERSION: "\([^"]*\)"$/\1/p' "$PROJECT")
build=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\([0-9][0-9]*\)"$/\1/p' "$PROJECT")
label=$(sed -n 's/^ *KVOTAR_PRERELEASE_LABEL: "beta\.\([0-9][0-9]*\)"$/\1/p' "$PROJECT")
for v in version build label; do
    [ "$(printf '%s\n' "${!v}" | grep -c .)" = 1 ] || refuse "cannot read one $v from $PROJECT"
done
label="beta.$label"
new_build=$((build + 1))
new_label="beta.$((${label#beta.} + 1))"
new_name="$version $new_label ($new_build)"
today=$(date +%Y-%m-%d)

# Lines between "## Unreleased" and the next heading, blank ones excluded.
unreleased=$(awk '/^## Unreleased/ { u = 1; next } u && /^## / { exit } u && NF { n++ } END { print n + 0 }' "$CHANGELOG")
[ "$unreleased" -gt 0 ] || refuse "Unreleased has no lines in $CHANGELOG"

# --- The seven lines, computed in memory and written together or not at all --------------------
python3 - "$PROJECT" "$SPEC" "$CHANGELOG" "$version" "$build" "$label" "$new_build" "$new_label" \
    "$RELEASES/v$version-$new_label" "$today" <<'PY'
import sys
project, spec, changelog, version, build, label, new_build, new_label, link, today = sys.argv[1:]

def replace(text, path, old, new):
    n = text.count(old)
    if n != 1:
        sys.exit(f"prepare_release: expected '{old}' once in {path}, found it {n} times")
    return text.replace(old, new)

out = {}
text = open(project).read()
text = replace(text, project, f'CURRENT_PROJECT_VERSION: "{build}"', f'CURRENT_PROJECT_VERSION: "{new_build}"')
text = replace(text, project, f'KVOTAR_PRERELEASE_LABEL: "{label}"', f'KVOTAR_PRERELEASE_LABEL: "{new_label}"')
out[project] = text

text = open(spec).read()
text = replace(text, spec, f'| `CURRENT_PROJECT_VERSION` | `{build}` |', f'| `CURRENT_PROJECT_VERSION` | `{new_build}` |')
text = replace(text, spec, f'| `KVOTAR_PRERELEASE_LABEL` | `{label}` |', f'| `KVOTAR_PRERELEASE_LABEL` | `{new_label}` |')
text = replace(text, spec, f"The `{label}` in a release's name", f"The `{new_label}` in a release's name")
text = replace(text, spec, f'`{version} {label} ({build})`', f'`{version} {new_label} ({new_build})`')
out[spec] = text

lines = open(changelog).read().split('\n')
i = lines.index('## Unreleased') + 1  # the awk above has already proven the heading and its lines exist
while lines[i] == '':
    i += 1
heading = f'## [{version} {new_label} ({new_build})]({link}) — {today}'
out[changelog] = '\n'.join(lines[:i] + [heading, ''] + lines[i:])

for path, text in out.items():
    open(path, 'w').write(text)
PY

# --- Check, commit, push --------------------------------------------------------------------------
if ! make check; then
    git checkout -q -- "$PROJECT" "$SPEC" "$CHANGELOG"
    refuse "make check failed; the bump was not written"
fi
git add -- "$PROJECT" "$SPEC" "$CHANGELOG"
git commit -q -m "Bump to $new_name"
git push -q origin main

echo "Bumped to $new_name: $(git rev-parse HEAD)"
echo "Next: build this commit with the private tooling (docs/releasing.md, step 2)."
