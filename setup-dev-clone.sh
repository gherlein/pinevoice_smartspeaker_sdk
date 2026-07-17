#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a development clone of the PineVoice SmartSpeaker SDK laid out for
# the standard fork workflow: develop locally, push branches to your fork, open
# PRs against pine64.
#
#   origin   -> your fork      (push here; PR branches live here)
#   upstream -> pine64         (fetch latest here; PRs target this)
#
# The superproject's .gitmodules uses RELATIVE submodule URLs. Cloning from your
# fork therefore makes the firmware submodules (c906, e907) resolve to YOUR
# forks as their origin with no extra wiring -- this script only layers the
# 'upstream' remote on top. The gamelaster-hosted submodules (wyoming,
# microwakeword) have no forks and are left pointing at their upstream.
#
# Usage:
#   ./setup-dev-clone.sh [target-dir]
#
# Env overrides:
#   GH_USER=<user>        your GitHub user      (default: gherlein)
#   UPSTREAM_ORG=<org>    upstream org          (default: pine64)
#   PROTO=ssh|https       remote protocol       (default: ssh)
#   BRANCH=<name>         branch to check out   (default: fork default branch)

# ---- Configuration ---------------------------------------------------------
GH_USER="${GH_USER:-gherlein}"
UPSTREAM_ORG="${UPSTREAM_ORG:-pine64}"
PROTO="${PROTO:-ssh}"
SUPERPROJECT="pinevoice_smartspeaker_sdk"
TARGET_DIR="${1:-$SUPERPROJECT}"
BRANCH="${BRANCH:-}"

# Submodules you maintain forks of. The relative .gitmodules URL already points
# their origin at your fork; we add upstream here. Format: <path>:<repo-name>
FORKED_SUBMODULES=(
  "solutions/pinevoice_fw_c906:pinevoice_fw_c906"
  "solutions/pinevoice_fw_e907:pinevoice_fw_e907"
)
# ----------------------------------------------------------------------------

info()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

url_for() { # url_for <owner> <repo>
  case "$PROTO" in
    ssh)   printf 'ssh://git@github.com/%s/%s.git' "$1" "$2" ;;
    https) printf 'https://github.com/%s/%s.git' "$1" "$2" ;;
    *)     die "PROTO must be 'ssh' or 'https', got '$PROTO'" ;;
  esac
}

set_remote() { # set_remote <repo-dir> <name> <url>  (idempotent)
  local dir="$1" name="$2" url="$3"
  if git -C "$dir" remote | grep -qx "$name"; then
    git -C "$dir" remote set-url "$name" "$url"
  else
    git -C "$dir" remote add "$name" "$url"
  fi
}

command -v git >/dev/null || die "git is not installed"

FORK_URL="$(url_for "$GH_USER" "$SUPERPROJECT")"

# ---- Clone (or adopt an existing clone) ------------------------------------
if [ -d "$TARGET_DIR/.git" ]; then
  info "Target '$TARGET_DIR' already a git repo; reusing and re-syncing remotes"
  set_remote "$TARGET_DIR" origin "$FORK_URL"
  git -C "$TARGET_DIR" submodule update --init --recursive
elif [ -e "$TARGET_DIR" ]; then
  die "'$TARGET_DIR' exists and is not a git repo; refusing to touch it"
else
  info "Cloning $FORK_URL -> $TARGET_DIR"
  clone_args=(--recurse-submodules)
  [ -n "$BRANCH" ] && clone_args+=(--branch "$BRANCH")
  git clone "${clone_args[@]}" "$FORK_URL" "$TARGET_DIR"
fi

# ---- Superproject remotes --------------------------------------------------
info "Configuring superproject remotes"
set_remote "$TARGET_DIR" upstream "$(url_for "$UPSTREAM_ORG" "$SUPERPROJECT")"

# 'git push' with no args pushes the current branch to its own name on origin.
git -C "$TARGET_DIR" config push.default current
# Never accidentally push to the read-only upstream.
git -C "$TARGET_DIR" remote set-url --push upstream DISABLED-push-to-origin-instead

# ---- Forked submodule remotes ----------------------------------------------
for entry in "${FORKED_SUBMODULES[@]}"; do
  path="${entry%%:*}"
  repo="${entry##*:}"
  sub_dir="$TARGET_DIR/$path"
  [ -e "$sub_dir/.git" ] || { warn "submodule '$path' not initialized; skipping"; continue; }

  info "Configuring submodule '$path'"
  # origin already resolves to your fork via the relative .gitmodules URL.
  set_remote "$sub_dir" upstream "$(url_for "$UPSTREAM_ORG" "$repo")"
  git -C "$sub_dir" config push.default current
  git -C "$sub_dir" remote set-url --push upstream DISABLED-push-to-origin-instead
done

# ---- Prime upstream refs (best effort) -------------------------------------
info "Fetching upstream refs"
git -C "$TARGET_DIR" fetch upstream || warn "could not fetch superproject upstream"
for entry in "${FORKED_SUBMODULES[@]}"; do
  sub_dir="$TARGET_DIR/${entry%%:*}"
  [ -e "$sub_dir/.git" ] && { git -C "$sub_dir" fetch upstream || warn "could not fetch upstream for ${entry%%:*}"; }
done

# ---- Summary ---------------------------------------------------------------
echo
info "Done. Remote layout:"
echo
echo "superproject ($TARGET_DIR):"
git -C "$TARGET_DIR" remote -v | sed 's/^/  /'
for entry in "${FORKED_SUBMODULES[@]}"; do
  sub_dir="$TARGET_DIR/${entry%%:*}"
  [ -e "$sub_dir/.git" ] || continue
  echo
  echo "submodule (${entry%%:*}):"
  git -C "$sub_dir" remote -v | sed 's/^/  /'
done
echo
cat <<EOF
Everyday workflow (works the same in the superproject and forked submodules):
  git fetch upstream && git rebase upstream/main   # catch up with pine64
  git switch -c my-feature                         # start work
  git push origin my-feature                       # push to your fork
  gh pr create --repo $UPSTREAM_ORG/<repo> --head $GH_USER:my-feature
EOF
