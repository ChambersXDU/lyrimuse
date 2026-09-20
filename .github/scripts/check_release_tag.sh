#!/usr/bin/env bash
set -euo pipefail

usage() { echo "usage: $0 <tag> [--body-out FILE]" >&2; exit 2; }
[ $# -ge 1 ] || usage
TAG="$1"; shift
BODY_OUT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --body-out) [ $# -ge 2 ] || usage; BODY_OUT="$2"; shift 2 ;;
    *) usage ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fail() { echo "check_release_tag: $*" >&2; exit 1; }

[[ "$TAG" == v* ]] || fail "tag '$TAG' must start with 'v' (vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N)"
if ! bash "$REPO_ROOT/lyrimuse/scripts/build-version.sh" "${TAG#v}" >/dev/null; then
  fail "tag '$TAG' is not vX.Y.Z or vX.Y.Z-(alpha|beta|rc).N -- see lyrimuse/scripts/build-version.sh"
fi

git rev-parse -q --verify "refs/tags/$TAG" >/dev/null 2>&1 || fail "refs/tags/$TAG does not exist in this checkout"
OBJ_TYPE="$(git cat-file -t "refs/tags/$TAG")"
if [ "$OBJ_TYPE" != "tag" ]; then
  fail "refs/tags/$TAG is a '$OBJ_TYPE' object, not an annotated tag. Either it was created without -a/-m/-F (lightweight), or this is a shallow clone that peeled the tag (CI needs fetch-depth: 0). The release notes are read from the tag annotation -- a lightweight tag would ship the commit message as the changelog."
fi

BODY="$(git for-each-ref "refs/tags/$TAG" --format='%(contents)')"
if [ -z "$(printf '%s' "$BODY" | LC_ALL=C tr -d '[:space:]')" ]; then
  fail "tag '$TAG' has an empty annotation. Write the bilingual changelog into the tag: git tag -a $TAG <commit> -F RELEASE_NOTES_$TAG.md"
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
printf '%s\n' "$BODY" > "$TMP_DIR/notes.md"
if ! python3 "$SCRIPT_DIR/split_release_notes.py" "$TMP_DIR/notes.md" "$TMP_DIR/split" >/dev/null; then
  fail "tag '$TAG' annotation could not be split into English + Chinese release notes (see split_release_notes.py output above). Accepted formats (AGENTS.md, 提交): <!-- lang:en --> / <!-- lang:zh-Hans --> blocks, or the interleaved style (English line first, Chinese continuation indented). Each side needs real content."
fi

if [ -n "$BODY_OUT" ]; then
  printf '%s\n' "$BODY" > "$BODY_OUT"
fi
echo "check_release_tag: $TAG ok (annotated, $(printf '%s' "$BODY" | wc -c | tr -d ' ') bytes, splits into en + zh-Hans)"
