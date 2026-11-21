#!/bin/zsh
# Publishes Offline Kit's source (GPLv3) to the public repo and beside that version's release.
#
#   Tools/Release/publish-source.sh            # the version in project.yml
#   Tools/Release/publish-source.sh 0.2.4
#
# It takes the committed state of this folder (never unsaved edits), minus the design workspace,
# and makes it one commit on the public repo's main branch. The working repo's history isn't published.
# It also writes dist/OfflineKit-<version>-source.zip and attaches it to the v<version> release when that
# release exists; publish-release.sh runs this script before creating a release, then attaches the zip.
#
# Like publish-release.sh, it uses the JoeyChappel GitHub account's token for this script only.
set -euo pipefail

ROOT=${0:A:h:h:h}
REPO=${RELEASE_REPO:-JoeyChappel/offline-kit}
ACCOUNT=${RELEASE_ACCOUNT:-JoeyChappel}
# GitHub's private address for the account, so no personal email lands in the public history.
EMAIL=${PUBLIC_EMAIL:-7595055+JoeyChappel@users.noreply.github.com}
cd "$ROOT"

VERSION=${1:-$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)}
# Left out: the design workspace, which nothing needs to build the app.
EXCLUDE=(':(exclude)Design' ':(exclude)DESIGN-PROMPT.md')

if [[ -n $(git status --porcelain -- . "${EXCLUDE[@]}") ]]; then
  echo "✗ Commit your changes first: the published source has to match a commit." >&2
  exit 1
fi
COMMIT=$(git rev-parse --short HEAD)

export GH_TOKEN=$(gh auth token --user "$ACCOUNT")
AUTH="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$GH_TOKEN" | base64)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

mkdir -p dist
ZIP="dist/OfflineKit-$VERSION-source.zip"
rm -f "$ZIP"
git archive --format=zip --prefix="offline-kit-$VERSION/" -o "$ZIP" HEAD -- . "${EXCLUDE[@]}"

echo "› Updating the source on $REPO"
git -c http.extraHeader="$AUTH" clone -q "https://github.com/$REPO.git" "$TMP/public"
git -C "$TMP/public" rm -rq --ignore-unmatch .
git archive --format=tar HEAD -- . "${EXCLUDE[@]}" | tar -x -C "$TMP/public"
git -C "$TMP/public" add -A
if git -C "$TMP/public" diff --cached --quiet; then
  echo "  Already current"
else
  git -C "$TMP/public" -c user.name="Joey Chappel" -c user.email="$EMAIL" \
    commit -q -m "Offline Kit $VERSION source" -m "Built from commit $COMMIT of the development repository."
  git -C "$TMP/public" -c http.extraHeader="$AUTH" push -q origin HEAD:main
fi

if gh release view "v$VERSION" -R "$REPO" >/dev/null 2>&1; then
  echo "› Attaching the source to v$VERSION"
  gh release upload "v$VERSION" "$ZIP" -R "$REPO" --clobber
fi
echo "✓ https://github.com/$REPO"
