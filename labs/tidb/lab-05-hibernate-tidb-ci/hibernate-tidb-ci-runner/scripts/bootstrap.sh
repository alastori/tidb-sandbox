#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/hibernate/hibernate-orm.git"
REF="nightly"

usage() {
  cat <<USAGE
Usage: $0 [repo-url] [--ref <ref>]
  repo-url    Git repository to clone (default: $REPO_URL)
  --ref       Branch or tag to check out (default: nightly -> main)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ref)
      [[ $# -lt 2 ]] && { echo "--ref requires an argument" >&2; exit 1; }
      REF="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      REPO_URL="$1"
      shift
      ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE_DIR="$ROOT_DIR/workspace"
REPO_DIR="$WORKSPACE_DIR/hibernate-orm"

mkdir -p "$WORKSPACE_DIR"

if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "Cloning $REPO_URL into $REPO_DIR"
  git clone "$REPO_URL" "$REPO_DIR"
else
  echo "Repository already exists at $REPO_DIR"
fi

TARGET_REF="$REF"
if [[ "$REF" == "nightly" ]]; then
  TARGET_REF="main"
fi

cd "$REPO_DIR"

echo "Fetching latest changes..."
git fetch --all --tags --prune

checkout_ref() {
  local ref="$1"
  if git show-ref --verify --quiet "refs/heads/$ref"; then
    git checkout "$ref"
    git pull --ff-only origin "$ref"
    return 0
  fi
  if git show-ref --verify --quiet "refs/remotes/origin/$ref"; then
    git checkout "$ref" || git checkout -b "$ref" "origin/$ref"
    git pull --ff-only origin "$ref"
    return 0
  fi
  if git show-ref --verify --quiet "refs/tags/$ref"; then
    git checkout "tags/$ref"
    return 0
  fi
  return 1
}

if ! checkout_ref "$TARGET_REF"; then
  echo "ERROR: Unable to checkout ref '$TARGET_REF'" >&2
  exit 1
fi

echo "Current HEAD: $(git rev-parse --abbrev-ref HEAD) @ $(git rev-parse --short HEAD)"
