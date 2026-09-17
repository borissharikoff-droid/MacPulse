#!/bin/bash
# =============================================================================
# MacPulse — the whole "ship it to everyone" workflow, in one command.
#
#   ./release.sh 1.0.0                 DRY RUN (default). Writes nothing,
#                                      builds nothing, touches no remote.
#                                      Prints every command it would run,
#                                      with every value already resolved.
#
#   ./release.sh 1.0.0 --local         For real, but NOTHING leaves this
#                                      machine: bump Info.plist, build,
#                                      stage the distribution copy under the
#                                      correct name, re-sign it ad-hoc, zip
#                                      it, build the .dmg. No git, no network.
#
#   ./release.sh 1.0.0 --publish       All of --local, then git commit, tag,
#                                      push, and create the GitHub Release
#                                      with both artifacts attached.
#
#   --no-build                         Re-use the existing Build/MacPulse.app
#                                      instead of running ./build.sh (2-4 min).
#                                      Packaging-only shortcut. REFUSED with
#                                      --publish: what gets published must
#                                      come from a fresh compile of the source
#                                      that is being tagged.
#
# WHY THE DEFAULT IS A DRY RUN: publishing is irreversible in the way that
# matters — the moment a Release exists, strangers have the binary and the
# version number is spent. So the safe mode is the one you get by accident.
#
# WHY GIT IS IN --publish AND NOT IN --local: a tag is a claim about what
# shipped. Making it before the artifacts have been looked at produces a tag
# you then have to force-move, which is exactly the state where someone ends
# up shipping v1.0.1 from the v1.0.0 tree. --local produces artifacts you can
# inspect; --publish is the step that makes claims.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="MacPulse"
REPO_OWNER="borissharikoff-droid"
REPO_NAME="MacPulse"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
VERSION=""
MODE="dry"
NO_BUILD=0

for arg in "$@"; do
  case "$arg" in
    --publish) MODE="publish" ;;
    --local)   [ "$MODE" = "publish" ] || MODE="local" ;;
    --no-build) NO_BUILD=1 ;;
    -h|--help)
      sed -n '2,40p' "$ROOT/release.sh" | sed 's|^# \{0,1\}||'
      exit 0 ;;
    -*)
      echo "error: unknown flag $arg" >&2
      echo "       usage: ./release.sh <version> [--local | --publish] [--no-build]" >&2
      exit 2 ;;
    *)
      if [ -n "$VERSION" ]; then
        echo "error: two versions given ($VERSION and $arg)" >&2
        exit 2
      fi
      VERSION="$arg" ;;
  esac
done

if [ -z "$VERSION" ]; then
  echo "error: usage: ./release.sh <version, e.g. 1.0.0> [--local | --publish] [--no-build]" >&2
  exit 2
fi

# A version that is not plain dotted-numeric would break any future updater
# that compares components as integers, and tags like "v1.0" sort strangely
# against "v1.0.0". Refuse it here rather than discover it in the wild.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be MAJOR.MINOR.PATCH (all numeric), got '$VERSION'" >&2
  exit 2
fi

if [ "$MODE" = "publish" ] && [ "$NO_BUILD" = "1" ]; then
  echo "error: --no-build cannot be combined with --publish." >&2
  echo "       A published binary must come from a fresh compile of the source" >&2
  echo "       being tagged, or the tag is a lie about what people downloaded." >&2
  exit 2
fi

TAG="v$VERSION"
DIST_STAGE="Build/dist-stage"
DIST_APP="$DIST_STAGE/$APP_NAME.app"
ZIP_PATH="Build/$APP_NAME.zip"
DMG_PATH="Build/$APP_NAME-$VERSION.dmg"

CUR_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Info.plist)
CUR_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" Info.plist)
NEW_BUILD=$((CUR_BUILD + 1))
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Info.plist)

# ---------------------------------------------------------------------------
# say / run — the dry run and the real run walk exactly the same code path.
# Every mutating command goes through run(); in dry mode run() prints it and
# returns. That is the only way the printed plan cannot drift from the thing
# the script actually does.
# ---------------------------------------------------------------------------
DRY=0
[ "$MODE" = "dry" ] && DRY=1

step() { echo; echo "==> $*"; }
note() { echo "    $*"; }

# Printed commands are re-quoted so they can be copy-pasted and actually work:
# `-c "Set :CFBundleVersion 2"` printed bare would run as three arguments.
quoted() {
  local out="" a
  for a in "$@"; do
    case "$a" in
      *[[:space:]\'\"\$\\\`\(\)\;\&\|\<\>]*) out="$out '$(printf '%s' "$a" | sed "s/'/'\\\\''/g")'" ;;
      "") out="$out ''" ;;
      *) out="$out $a" ;;
    esac
  done
  printf '%s' "${out# }"
}

run() {
  if [ "$DRY" = "1" ]; then
    printf '    $ %s\n' "$(quoted "$@")"
  else
    "$@"
  fi
}

# For pipelines/redirections that cannot be passed as an argv array.
run_sh() {
  if [ "$DRY" = "1" ]; then
    printf '    $ %s\n' "$1"
  else
    bash -c "$1"
  fi
}

echo "============================================================"
case "$MODE" in
  dry)     echo " MacPulse $TAG — DRY RUN. Nothing is written, built or pushed." ;;
  local)   echo " MacPulse $TAG — LOCAL BUILD. Artifacts only; nothing is pushed." ;;
  publish) echo " MacPulse $TAG — PUBLISH. This WILL push and create a Release." ;;
esac
echo "============================================================"
note "version      $CUR_VERSION -> $VERSION"
note "build number $CUR_BUILD -> $NEW_BUILD"
note "bundle id    $BUNDLE_ID"
note "artifacts    $ZIP_PATH"
note "             $DMG_PATH"
note "repo         $REPO_OWNER/$REPO_NAME (tag $TAG)"

# ---------------------------------------------------------------------------
# Preflight. Cheap checks first, and in publish mode they are hard failures:
# finding out that `gh` is logged out AFTER the tag is pushed is how you get a
# tag with no release behind it.
# ---------------------------------------------------------------------------
step "Preflight"

if [ ! -x "$ROOT/build.sh" ]; then
  echo "error: ./build.sh is missing or not executable." >&2
  exit 1
fi
note "build.sh present"

if [ "$NO_BUILD" = "1" ] && [ ! -d "Build/$APP_NAME.app" ]; then
  echo "error: --no-build given but Build/$APP_NAME.app does not exist." >&2
  exit 1
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "?")
note "branch       $BRANCH"

if [ "$MODE" = "publish" ]; then
  if ! git remote get-url origin >/dev/null 2>&1; then
    echo "error: no git remote named 'origin'." >&2
    echo "       This repo has never been pushed. Create the GitHub repo first:" >&2
    echo >&2
    echo "         gh repo create $REPO_OWNER/$REPO_NAME --public --source=. --remote=origin --push" >&2
    echo >&2
    echo "       See RELEASING.md — it has the full first-push sequence." >&2
    exit 1
  fi
  note "origin       $(git remote get-url origin)"
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not authenticated. Run: gh auth login" >&2
    exit 1
  fi
  note "gh           authenticated"
else
  if git remote get-url origin >/dev/null 2>&1; then
    note "origin       $(git remote get-url origin)"
  else
    note "origin       (none — repo has never been pushed; see RELEASING.md)"
  fi
fi

DIRTY=$(git status --porcelain 2>/dev/null | grep -v '^?? Build/' || true)
if [ -n "$DIRTY" ]; then
  note "working tree has uncommitted changes:"
  printf '                 %s\n' $(git status --porcelain | awk '{print $2}' | head -20)
  if [ "$MODE" = "publish" ]; then
    # Only Info.plist and CHANGELOG.md are committed by this script (see the
    # commit step). Anything else dirty would be published in the binary but
    # NOT be in the tagged commit — the artifact and the tag would disagree.
    OTHER=$(git status --porcelain | awk '{print $2}' | grep -vE '^(Info\.plist|CHANGELOG\.md)$' || true)
    if [ -n "$OTHER" ]; then
      echo "error: refusing to publish with unrelated uncommitted changes." >&2
      echo "       The binary would contain them; the tag would not point at them." >&2
      printf '       %s\n' $OTHER >&2
      echo "       Commit or stash them first." >&2
      exit 1
    fi
  fi
else
  note "working tree clean"
fi

# ---------------------------------------------------------------------------
# 1. Version
# ---------------------------------------------------------------------------
step "Bumping Info.plist to $VERSION (build $NEW_BUILD)"
run /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" Info.plist
run /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Info.plist

# ---------------------------------------------------------------------------
# 2. Build
#
# ./build.sh is the only thing that knows the SDK pin, the macos13.0 deployment
# target and the contract guards (no Network.framework in the link map, one
# loopback socket, one PF_ROUTE socket). Release must not reimplement any of
# that — it calls the same script a normal build calls, so a release binary is
# the same kind of thing as a dev binary.
#
# --universal, and ONLY here. A release has to run on a friend's 2019 Intel
# MacBook, and an arm64-only bundle on an Intel Mac does not fail with
# "unsupported architecture": Finder says «приложение повреждено», which is
# indistinguishable from a bad download and sends the person looking for the
# wrong problem. Development builds stay single-slice because the second one
# doubles a four-minute compile for a machine that is arm64 anyway.
#
# --no-install, because a release must not silently replace the copy in
# /Applications that the developer is running. The staged copy below is the
# artifact; /Applications is not part of it.
# ---------------------------------------------------------------------------
if [ "$NO_BUILD" = "1" ]; then
  step "Skipping the compile (--no-build) — re-using Build/$APP_NAME.app"
  note "the staged copy still gets the freshly bumped Info.plist below"
else
  step "Building universal (./build.sh — SDK pin, deployment target, contract guards)"
  run ./build.sh --universal --no-install
fi

# ---------------------------------------------------------------------------
# 3. The distribution copy
#
# TWO LESSONS FROM THE SIBLING PROJECT, BOTH PAID FOR IN PUBLIC:
#
# (a) THE PUBLIC ARTIFACT IS RE-SIGNED AD-HOC, not with the local dev
#     certificate build.sh uses. A self-signed cert that a stranger's Mac has
#     never seen chains to nothing it trusts, and current macOS can escalate
#     that to "MacPulse is damaged and can't be opened" — a dead end for a
#     non-technical friend. A plain ad-hoc signature gets the classic,
#     well-trodden "unidentified developer" path instead, which the
#     recovery steps in dmg-assets/ can actually talk someone through. A
#     worse-looking signature with a far better outcome.
#
#     Since macOS 15 even that path is narrower — Apple removed right-click
#     ▸ Открыть for unsigned apps, leaving only System Settings ▸ Приватность
#     и безопасность ▸ «Всё равно открыть». Which is why install.sh exists and
#     is the route the README leads with: a file fetched by curl is never
#     quarantined, so Gatekeeper has nothing to object to in the first place.
#
# (b) THE STAGE DIRECTORY MUST ALREADY CONTAIN THE CORRECT FINAL NAME.
#     `ditto --keepParent` puts whatever the source folder is LITERALLY called
#     inside the zip. Zipping a folder named "MacPulse-dist.app" ships a zip
#     that unpacks to "MacPulse-dist.app", and any updater looking for
#     "MacPulse.app" finds nothing — silently, with no error. That exact bug
#     broke every auto-update in the sibling project from v1.0.2 to v1.0.7.
#     Hence: stage into its own directory, under the real name.
#
# The Info.plist is copied in AFTER the app is staged and BEFORE it is signed,
# so the shipped bundle always carries the version this run just set — which
# is what makes --no-build safe, and what stops a stale plist from riding
# along inside a bundle that was compiled an hour ago.
# ---------------------------------------------------------------------------
step "Staging the distribution copy (ad-hoc signature)"
run rm -rf "$DIST_STAGE"
run mkdir -p "$DIST_STAGE"
run cp -R "Build/$APP_NAME.app" "$DIST_APP"
run cp Info.plist "$DIST_APP/Contents/Info.plist"
run codesign --force --deep --sign - "$DIST_APP"
run_sh "codesign -dv '$DIST_APP' 2>&1 | grep -E 'Identifier|flags'"

# ---------------------------------------------------------------------------
# 4. Zip
# ---------------------------------------------------------------------------
step "Zipping"
run rm -f "$ZIP_PATH"
run ditto -c -k --sequesterRsrc --keepParent "$DIST_APP" "$ZIP_PATH"

# ---------------------------------------------------------------------------
# 5. DMG — make-dmg.sh reads the staged copy above, so it inherits the ad-hoc
#    signature and the correct bundle name for free.
# ---------------------------------------------------------------------------
step "Building the DMG"
run ./make-dmg.sh

if [ "$DRY" != "1" ]; then
  echo
  note "$(ls -lh "$ZIP_PATH" | awk '{print $9, $5}')"
  note "$(ls -lh "$DMG_PATH" | awk '{print $9, $5}')"
fi

# ---------------------------------------------------------------------------
# 6. Git + GitHub. Everything below this line leaves the machine.
# ---------------------------------------------------------------------------
NOTES_FILE="Build/release-notes-$VERSION.md"

if [ "$MODE" = "publish" ] || [ "$DRY" = "1" ]; then
  step "Release notes"
  # Prefer the CHANGELOG section for this version — one source of truth for
  # "what changed", instead of notes that exist only inside a GitHub form.
  if [ -f CHANGELOG.md ] && grep -q "^## $VERSION" CHANGELOG.md; then
    note "from CHANGELOG.md, section '## $VERSION' ($(awk -v v="## $VERSION" '$0 ~ "^"v {f=1; next} /^## /{f=0} f' CHANGELOG.md | grep -c . ) non-empty lines)"
    run_sh "awk -v v='## $VERSION' '\$0 ~ \"^\"v {f=1; next} /^## /{f=0} f' CHANGELOG.md > '$NOTES_FILE'"
  else
    note "CHANGELOG.md has no '## $VERSION' section — the notes will be a bare title"
    run_sh "printf 'MacPulse %s\\n' '$VERSION' > '$NOTES_FILE'"
  fi
fi

# --------------------------------------------------------------------------
# EVERYTHING IN THIS BLOCK IS --publish ONLY.
#
# The guard is on the block and not on run(), because run() only knows about
# dry-vs-real: --local is a REAL run, so without this `if` the commit, the tag
# and the push all happen in the mode whose entire promise is that nothing
# leaves the machine. (They did, once, before this guard existed. The dry run
# did not catch it — it prints the same transcript in both modes, which is
# exactly why the local run has to be tried for real before anyone trusts it.)
# --------------------------------------------------------------------------
if [ "$MODE" = "publish" ] || [ "$DRY" = "1" ]; then
  step "Committing, tagging and publishing   [--publish only]"
  # Deliberately NOT `git add -A`: this script owns exactly two files. Sweeping
  # the whole tree into a "Release" commit is how unrelated work-in-progress
  # ends up inside a tagged release.
  run_sh "git add Info.plist CHANGELOG.md 2>/dev/null || git add Info.plist"
  run_sh "git commit -m 'Release v$VERSION' || echo '(nothing to commit)'"
  run git tag -f "$TAG"
  run git push origin "$BRANCH"
  run git push origin "$TAG" --force
  run_sh "gh release delete '$TAG' --yes 2>/dev/null || true"
  run gh release create "$TAG" "$ZIP_PATH" "$DMG_PATH" \
    --title "$TAG" \
    --notes-file "$NOTES_FILE"
else
  step "Skipping git and GitHub entirely (--local)"
  note "no commit, no tag, no push, no release — run with --publish for those"
fi

echo
case "$MODE" in
  dry)
    echo "============================================================"
    echo " DRY RUN — none of the above ran. Nothing was written."
    echo "============================================================"
    echo " Next:"
    echo "   ./release.sh $VERSION --local      build the artifacts here and look at them"
    echo "   ./release.sh $VERSION --publish    do all of it, for real"
    echo
    echo " This repo has no 'origin' yet, so --publish will stop at the"
    echo " preflight until the GitHub repo exists. RELEASING.md has the"
    echo " two commands that create it."
    ;;
  local)
    echo "============================================================"
    echo " LOCAL BUILD DONE. Nothing was pushed, nothing was tagged."
    echo "============================================================"
    echo "   $ZIP_PATH"
    echo "   $DMG_PATH"
    echo
    echo " Open the DMG and check it looks right, then:"
    echo "   ./release.sh $VERSION --publish"
    ;;
  publish)
    echo "============================================================"
    echo " PUBLISHED: https://github.com/$REPO_OWNER/$REPO_NAME/releases/tag/$TAG"
    echo "============================================================"
    echo " The .dmg is the link to send people. The first launch on their"
    echo " machine WILL show 'unidentified developer' — that is expected for"
    echo " an ad-hoc signature, and 'Если не открывается.txt' inside the DMG"
    echo " walks them through it."
    ;;
esac
