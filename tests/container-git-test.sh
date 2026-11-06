#!/bin/sh
# container-git-test.sh -- check which container container-git picks.
#
#   sh tests/container-git-test.sh
#
# Runs container-git against a temporary HOME and container map, with fake
# `docker', `podman' and `git' first on PATH that print their argv instead
# of running anything. Touches neither the real ~/.config nor any container.
# Exits non-zero if any case fails.

here=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)
wrapper=$here/container-git

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
tmp=$(cd -P -- "$tmp" && pwd -P)   # macOS: /var is a link to /private/var

mkdir -p "$tmp/bin" "$tmp/home/.config/claude-container"
for tool in docker podman git; do
  printf '#!/bin/sh\necho %s "$@"\n' "$tool" > "$tmp/bin/$tool"
  chmod +x "$tmp/bin/$tool"
done

H=$tmp/home
map=$H/.config/claude-container/containers
for d in projects projects/repo projects/work/repo projects-old/repo \
         client/repo elsewhere/repo; do
  mkdir -p "$H/$d"
done

failures=0

# check NAME DIR EXPECTED [VAR=VALUE...]: run `container-git status' in DIR
# with only HOME, PATH and the VAR=VALUE pairs given in its environment.
check() {
  name=$1 dir=$2 expected=$3
  shift 3
  actual=$(cd "$dir" && env -i HOME="$H" PATH="$tmp/bin:/usr/bin:/bin" \
             "$@" sh "$wrapper" status 2>&1)
  if [ "$actual" = "$expected" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    failures=$((failures + 1))
  fi
}

# The fake docker's output for `git status' run in container $2 at $1.
inside() { echo "docker exec -i -w $1 $2 git status"; }

# --- No map file: exactly the old behaviour.
rm -f "$map"
check 'no map: ~/projects goes to claude-dev' \
      "$H/projects/repo" "$(inside "$H/projects/repo" claude-dev)"
check 'no map: ~/projects itself goes to claude-dev' \
      "$H/projects" "$(inside "$H/projects" claude-dev)"
check 'no map: elsewhere runs locally' \
      "$H/elsewhere/repo" "git status"
check 'no map: a sibling sharing the prefix runs locally' \
      "$H/projects-old/repo" "git status"
check 'no map: CLAUDE_CONTAINER replaces claude-dev' \
      "$H/projects/repo" "$(inside "$H/projects/repo" other)" \
      CLAUDE_CONTAINER=other
check 'no map: CLAUDE_CONTAINER leaves elsewhere local' \
      "$H/elsewhere/repo" "git status" CLAUDE_CONTAINER=other

# --- A map with nested entries, comments, blank lines and odd spellings.
cat > "$map" <<MAP
# The personal container.
~/projects claude-dev

   # An indented comment, and a trailing slash on the entry.
~/projects/work/   claude-work
$H/client claude-client   # an absolute path, and a trailing comment
~/half-entry
MAP
check 'map: an entry owns its subdirectories' \
      "$H/projects/repo" "$(inside "$H/projects/repo" claude-dev)"
check 'map: the longest containing directory wins' \
      "$H/projects/work/repo" "$(inside "$H/projects/work/repo" claude-work)"
check 'map: an absolute directory matches' \
      "$H/client/repo" "$(inside "$H/client/repo" claude-client)"
check 'map: an unlisted directory runs locally' \
      "$H/elsewhere/repo" "git status"
check 'map: a sibling sharing the prefix runs locally' \
      "$H/projects-old/repo" "git status"
check 'map: CLAUDE_CONTAINER overrides the map' \
      "$H/projects/work/repo" "$(inside "$H/projects/work/repo" other)" \
      CLAUDE_CONTAINER=other
check 'map: CLAUDE_CONTAINER leaves an unlisted directory local' \
      "$H/elsewhere/repo" "git status" CLAUDE_CONTAINER=other

# --- A map that leaves ~/projects out, as on a work machine.
printf '~/client claude-client' > "$map"     # no final newline
check 'map without ~/projects: ~/projects runs locally' \
      "$H/projects/repo" "git status"
check 'map: a last line with no newline is read' \
      "$H/client/repo" "$(inside "$H/client/repo" claude-client)"

# --- An empty map owns nothing.
: > "$map"
check 'empty map: ~/projects runs locally' "$H/projects/repo" "git status"

# --- An entry reached through a symlink matches the directory's true name.
ln -s "$H/client" "$H/link"
printf '~/link claude-link\n' > "$map"
check 'map: an entry through a symlink owns the real directory' \
      "$H/client/repo" "$(inside "$H/client/repo" claude-link)"
check 'map: and the cwd is resolved through the symlink too' \
      "$H/link/repo" "$(inside "$H/client/repo" claude-link)"

# --- What is passed through to the container.
printf '~/projects claude-dev\n' > "$map"
check 'GIT_* variables are passed by name' \
      "$H/projects/repo" \
      "docker exec -i -w $H/projects/repo -e GIT_EDITOR claude-dev git status" \
      GIT_EDITOR=true
check 'CONTAINER_RUNTIME picks the engine' \
      "$H/projects/repo" \
      "podman exec -i -w $H/projects/repo claude-dev git status" \
      CONTAINER_RUNTIME=podman

if [ "$failures" -eq 0 ]; then
  echo "All passed."
else
  echo "$failures failed."
  exit 1
fi
