#!/usr/bin/env bash
# Build DavMail from GitHub, optionally applying upstream pull requests,
# or build an existing local DavMail checkout as-is.
#
# Usage:
#   cd /tmp && ./build-davmail.sh [PR_NUMBER ...]   # fresh clone into /tmp/davmail (must run from /tmp)
#   ./build-davmail.sh --repo DIR                   # build existing checkout in DIR (any cwd)
# Examples:
#   cd /tmp && ./build-davmail.sh 554
#   ./build-davmail.sh --repo /tmp/davmail
set -euo pipefail

REPO_URL="https://github.com/mguessan/davmail.git"
WORK_DIR="/tmp/davmail"
INSTALL_DIR="/opt/davmail"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
usage() { sed -n '2,10s/^# \{0,1\}//p' "$0"; }

# --- 0. Parse arguments ------------------------------------------------------
REPO_DIR=""
PRS=()
while (($#)); do
  case "$1" in
    -r|--repo)
      [[ $# -ge 2 && -n "$2" ]] || die "$1 requires a directory argument"
      REPO_DIR="$2"; shift 2 ;;
    --repo=*)
      REPO_DIR="${1#--repo=}"
      [[ -n "$REPO_DIR" ]] || die "--repo requires a directory argument"
      shift ;;
    -h|--help) usage; exit 0 ;;
    -*) die "unknown option: '$1' (see --help)" ;;
    *) PRS+=("$1"); shift ;;
  esac
done

# Validate PR arguments up front
for pr in "${PRS[@]}"; do
  [[ "$pr" =~ ^[0-9]+$ ]] || die "invalid PR number: '$pr'"
done

if [[ -n "$REPO_DIR" ]]; then
  # Existing checkout: build what is there, never rewrite the user's branch
  ((${#PRS[@]} == 0)) || die "PR numbers cannot be combined with --repo; check out the branch you want to build instead"
  [[ -d "$REPO_DIR" ]] || die "repo directory does not exist: $REPO_DIR"
  WORK_DIR="$(cd "$REPO_DIR" && pwd -P)"
  [[ -f "$WORK_DIR/build.xml" ]] || die "$WORK_DIR does not look like a DavMail checkout (no build.xml)"
else
  # --- 1. Refuse to run from an arbitrary folder -----------------------------
  [[ "$(pwd -P)" == "/tmp" ]] || die "run this script from /tmp (current dir: $(pwd -P)), or use --repo DIR"
fi

# --- 3. Check build dependencies (done first so we fail before cloning) ------
info "Checking build dependencies"
missing=()
command -v git   >/dev/null || missing+=(git)
command -v javac >/dev/null || missing+=(default-jdk)
command -v ant   >/dev/null || missing+=(ant)
# build.xml uses OpenJFX from /usr/share/java on Debian
[[ -f /usr/share/java/javafx-base.jar ]] || missing+=(libopenjfx-java)

if ((${#missing[@]})); then
  echo "Missing build dependencies. Install them with:" >&2
  echo "  sudo apt install ${missing[*]}" >&2
  exit 1
fi
echo "All build dependencies present."

if [[ -n "$REPO_DIR" ]]; then
  # --- 1. Use existing checkout ----------------------------------------------
  cd "$WORK_DIR"
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "$WORK_DIR is not a git repository"
  info "Using existing checkout $WORK_DIR"
  echo "Branch: $(git rev-parse --abbrev-ref HEAD)"
  git log --oneline -1
  if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    echo "WARNING: uncommitted changes in tracked files will be included in the build" >&2
  fi
else
  # --- 1. Clone --------------------------------------------------------------
  [[ ! -e "$WORK_DIR" ]] || die "$WORK_DIR already exists; remove it first (rm -rf $WORK_DIR) or build it with --repo $WORK_DIR"
  info "Cloning $REPO_URL into $WORK_DIR"
  git clone "$REPO_URL" "$WORK_DIR"
  cd "$WORK_DIR"
  BASE_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

  # --- 2. Apply PRs (rebased onto current HEAD, fast-forward merged) ---------
  for pr in "${PRS[@]}"; do
    info "Applying PR #$pr"
    git fetch origin "pull/$pr/head:pr-$pr" \
      || die "could not fetch PR #$pr (does it exist?)"
    if ! git rebase HEAD "pr-$pr" >/dev/null 2>&1; then
      git rebase --abort || true
      die "PR #$pr does not rebase cleanly onto the current branch; aborting"
    fi
    git checkout -q "$BASE_BRANCH"
    git merge --ff-only "pr-$pr" >/dev/null
    git branch -d "pr-$pr" >/dev/null
    git log --oneline -1
  done
fi

# --- 4. Build ----------------------------------------------------------------
info "Building"
export LC_ALL=C.UTF-8 # build.xml requires file.encoding=UTF-8
ant clean jar
JAR="$WORK_DIR/dist/davmail.jar"
[[ -f "$JAR" ]] || die "build finished but $JAR is missing"

# --- 5. Installation instructions --------------------------------------------
cat <<EOF

==> Build OK: $JAR

To replace the jar of an existing standalone install in $INSTALL_DIR
(keeps its lib/ and bundled jre/):

  pkill -f davmail.jar                                  # stop running instance
  sudo cp -a $INSTALL_DIR ${INSTALL_DIR}.bak-\$(date +%Y%m%d-%H%M%S)   # backup
  sudo install -m 644 $JAR $INSTALL_DIR/davmail.jar
  $INSTALL_DIR/davmail                                  # start again

Rollback: copy davmail.jar back from the backup directory.
EOF
