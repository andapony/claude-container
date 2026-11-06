#!/bin/sh
# repo-token-test.sh -- check which token git uses for which GitHub repo.
#
#   sh tests/repo-token-test.sh
#
# Writes the image's GitHub credential config into a temporary global git
# config -- the github.com helper as the Dockerfile sets it, then
# git-credential-repo-token's entry for andapony/emacs.d -- and asks the
# real git, with `git credential fill', which password it would send. A
# fake `gh' first on PATH answers with GH_TOKEN, as the real one does.
# Touches neither the real git config nor the network. Exits non-zero if
# any case fails.

here=$(cd -P -- "$(dirname -- "$0")/.." && pwd -P)

tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home"
ln -s "$here/git-credential-repo-token" "$tmp/bin/git-credential-repo-token"
cat > "$tmp/bin/gh" <<'GH'
#!/bin/sh
# Only `gh auth git-credential get' is expected.
cat > /dev/null
[ "$*" = "auth git-credential get" ] || exit 1
[ -n "${GH_TOKEN-}" ] || exit 1
printf 'username=x-access-token\npassword=%s\n' "$GH_TOKEN"
GH
chmod +x "$tmp/bin/gh"

# Run git with nothing of the caller's: only this HOME, PATH and config.
g() {
  env -i HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin" \
      GIT_CONFIG_GLOBAL="$tmp/gitconfig" GIT_CONFIG_NOSYSTEM=1 \
      GIT_TERMINAL_PROMPT=0 "$@"
}

# The Dockerfile's github.com helper, then the emacs.d entry, in its order.
g git config --global credential.https://github.com.helper ''
g git config --global --add credential.https://github.com.helper '!gh auth git-credential'
g sh "$here/git-credential-repo-token" --add \
  https://github.com/andapony/emacs.d GH_TOKEN_EMACS_D

failures=0

# check NAME URL EXPECTED [VAR=VALUE...]: the password `git credential fill'
# gives for URL, with GH_TOKEN=general and the VAR=VALUE pairs given.
check() {
  name=$1 url=$2 expected=$3
  shift 3
  actual=$(printf 'url=%s\n\n' "$url" \
             | g GH_TOKEN=general "$@" git credential fill 2>&1 \
             | sed -n 's/^password=//p')
  if [ "$actual" = "$expected" ]; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    echo "       expected: $expected"
    echo "       actual:   $actual"
    failures=$((failures + 1))
  fi
}

e=https://github.com/andapony/emacs.d

# --- Without the variable: GH_TOKEN everywhere, as with no entry at all.
check 'unset: emacs.d uses GH_TOKEN'        "$e"      general
check 'unset: emacs.d.git uses GH_TOKEN'    "$e.git"  general
check 'unset: another repo uses GH_TOKEN'   https://github.com/andapony/setup general
check 'empty: emacs.d uses GH_TOKEN'        "$e"      general GH_TOKEN_EMACS_D=

# --- With it: the repo's own token for emacs.d, GH_TOKEN for the rest.
set -- GH_TOKEN_EMACS_D=personal
check 'set: emacs.d uses its own token'     "$e"      personal "$@"
check 'set: emacs.d.git uses its own token' "$e.git"  personal "$@"
check 'set: a trailing slash still matches' "$e/"     personal "$@"
check 'set: another repo uses GH_TOKEN' \
      https://github.com/andapony/setup general "$@"
check 'set: a repo sharing the prefix uses GH_TOKEN' \
      https://github.com/andapony/emacs.d-old general "$@"
check 'set: the same name elsewhere uses GH_TOKEN' \
      https://github.com/robcetos/emacs.d general "$@"
check 'set: github.com without a path uses GH_TOKEN' \
      https://github.com general "$@"

# --- store and erase leave the token alone, and say nothing.
out=$(printf 'url=%s\nusername=x\npassword=y\n\n' "$e" \
        | g GH_TOKEN_EMACS_D=personal git credential-repo-token GH_TOKEN_EMACS_D erase)
if [ $? -eq 0 ] && [ -z "$out" ]; then
  echo "ok   erase is a no-op"
else
  echo "FAIL erase is a no-op"; failures=$((failures + 1))
fi

# --- --add refuses what isn't a variable name.
if g sh "$here/git-credential-repo-token" --add "$e" 'X;rm' 2>/dev/null; then
  echo "FAIL --add refuses a bad variable name"; failures=$((failures + 1))
else
  echo "ok   --add refuses a bad variable name"
fi

if [ "$failures" -eq 0 ]; then
  echo "All passed."
else
  echo "$failures failed."
  exit 1
fi
