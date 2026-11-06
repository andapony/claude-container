# Limiting what the agent can do outside the container

The container is the boundary, but two things cross it: whatever GitHub
credential is passed in, and the mounted directory -- `~/projects` for
`claude-dev`, `~/cetos` for `claude-cetos` -- which the host reads and
writes too. This covers how to keep both from widening what the agent
can do, and how agents get to build and run images without being given
a third thing: the host's container engine.

The commands use `docker`; on Linux substitute `podman`.

## GitHub: one fine-grained token, and nothing else

Give the agent a **fine-grained personal access token** and make it the
only GitHub credential in the container. GitHub enforces its limits on
every request, so they hold however the agent gets there -- `gh`, `gh api`,
`git push`, `curl`.

GitHub → Settings → Developer settings → Personal access tokens →
Fine-grained tokens:

- **Resource owner:** your own account. A fine-grained token cannot write to
  repos owned by anyone else -- no issues, comments or PRs on other people's
  repos, public or not. It can still read public repos.
- **Repository access:** only selected repositories, or all of your own.
- **Repository permissions:**
  - Contents: read and write -- commits, pushes, merges
  - Pull requests: read and write
  - Issues: read and write -- create, edit, comment, close and label
  - Metadata: read (required)
  - everything else: no access. In particular:
    - *Administration* -- without it the token cannot create or delete
      repos or change their settings.
    - *Workflows* -- without it the token cannot push changes under
      `.github/workflows`. A workflow runs with its own credentials, so
      this closes a route around the other limits.
- **Account permissions:** none -- no gists, stars, follows or profile edits.
- **Expiration:** set one.

What the permissions can't separate:

- Pull requests: write also lets the token comment on PRs and close them.
  You can't grant creating and merging without those. Issues: write
  likewise covers closing, commenting and labelling, though not deleting
  an issue, which needs Administration.
- Contents: write also lets it force-push and delete branches. Protect
  `main` with a ruleset (repo → Settings → Rules → Rulesets) that blocks
  force pushes and deletion. Rulesets are free on public repos; private
  repos on a personal account need GitHub Pro.

### Passing it in

`gh` prefers `GH_TOKEN` over any stored login. Keep the token in an env
file on the host -- outside `~/projects`, so it is neither in the agent's
view of the share nor ever committed:

    mkdir -p ~/.config/claude-dev
    ( umask 077; printf 'GH_TOKEN=%s\n' '<token>' > ~/.config/claude-dev/env )

The run lines in the Dockerfile pass it with `--env-file`. That keeps the
token out of shell history and the process list; `docker inspect` still
shows it, as it does any container env. Env is fixed when the container is
created, so a new token means `docker rm -f claude-dev` and the run line
again. The `claude-config` volume keeps the Claude login across that.

The image routes `git` through the same token: it configures `gh` as the
credential helper for github.com -- what `gh auth setup-git` would write --
and rewrites SSH remotes (`git@github.com:` and the host's
`git@github-andapony:` alias) to HTTPS. The repos' own remotes are left as
they are, so the host still pushes over SSH. Never put the token in a
remote URL, where `.git/config` would keep it in plain text.

To check, from inside the container:

    git -C ~/projects/emacs.d ls-remote origin HEAD
    gh -R andapony/emacs.d repo view --json name

### Keeping it the only credential

- **No SSH.** The run lines in the Dockerfile mount no SSH agent socket and
  no `~/.ssh`. Keep it that way: an SSH key or a forwarded agent can push to
  every repo the key's owner can, force-pushes included. On macOS, OrbStack
  offers the Mac's agent to containers at `/run/host-services/ssh-auth.sock`,
  but only to a container that mounts it -- so never add that `-v`.
- **No `gh auth login`** inside the container -- that stores a much broader
  OAuth token in `~/.config/gh`.

To check it from inside the container:

    echo "$SSH_AUTH_SOCK"; ssh-add -l; ls ~/.ssh ~/.config/gh ~/.git-credentials

And check the token. Don't test refusals by trying the real thing -- if the
token were wrong, `gh repo create` would create a repo. Send each request
with an invalid body instead: GitHub checks the permission first, so a
refused request gets 403, and an allowed one gets 422 for the bad body and
creates nothing.

    probe() { printf '%-28s ' "$1"; shift
              gh api "$@" 2>&1 | grep -oE 'HTTP [0-9]+' | tail -1; }
    probe 'create repo'         -X POST /user/repos -f name=
    echo '{"name":""}' | probe 'repo settings' \
                                -X PATCH /repos/<you>/<repo> --input -
    probe 'issue, others repo'  -X POST /repos/cli/cli/issues -f body=
    probe 'gist'                -X POST /gists -f description=
    probe 'workflow file'       -X PUT /repos/<you>/<repo>/contents/.github/workflows/x.yml -f message=x
    probe 'file, own repo'      -X PUT /repos/<you>/<repo>/contents/x.txt -f message=x
    probe 'issue, own repo'     -X POST /repos/<you>/<repo>/issues -f body=
    probe 'PR, own repo'        -X POST /repos/<you>/<repo>/pulls -f title=

The first five should be 403 and the last three 422. Repo deletion needs
the same Administration permission as repo settings, so it isn't probed:
the only real test would delete a repo. For pushing, use
`git push --dry-run origin HEAD:refs/heads/x`, which authenticates for
push but sends nothing.

## claude-cetos: Cetos work, apart from personal work

`claude-cetos` is a second container from the same Dockerfile, for Cetos
repos only; the Dockerfile header has its build and run lines. It differs
from `claude-dev` in what it can reach, and in nothing else:

| | `claude-dev` | `claude-cetos` |
|---|---|---|
| mounts | `~/projects` | `~/cetos`, and never `~/projects` |
| env file | `~/.config/claude-dev/env` | `~/.config/claude-cetos/env` |
| `GH_TOKEN` owned by | `andapony` | `robcetos`, for the Cetos org |
| other tokens | none | optionally `GH_TOKEN_EMACS_D` |
| Claude login volume | `claude-config` | `claude-cetos-config` |
| podman storage volume | `claude-dev-containers` | `claude-cetos-containers` |
| commits as | `andapony@...` | the Cetos address (`GIT_USER_EMAIL`) |

### Never mount ~/projects

The mount is what keeps the two apart. Never add a `~/projects` mount, or
any directory holding a personal repo other than `emacs.d`, to
`claude-cetos`, and never mount `~/cetos` in `claude-dev`. Cetos repos live
in `~/cetos/`, outside `~/projects`, so `claude-dev` never sees them; and
`claude-cetos` sees nothing of `~/projects`, so an agent on the company's
Claude account, holding a Cetos token, can't read or write personal work.
It has no `~/projects` alias inside either: `MOUNT_DIR=cetos` gives it
`~/cetos` instead. The container map then sends `~/cetos` to
`claude-cetos`, so host git runs there too.

To check, on the host:

    docker inspect claude-cetos --format '{{.HostConfig.Binds}} {{.Config.WorkingDir}}'

It should list `$HOME/cetos` and no `projects`. Inside, `ls ~/projects`
should fail.

### Its GH_TOKEN: owned by robcetos

Make the token as above, signed in to GitHub as `robcetos`, with two
differences:

- **Resource owner:** the Cetos organisation, not `robcetos` itself. A
  fine-grained token reaches an organisation's repos only if the
  organisation allows fine-grained tokens (organisation → Settings →
  Personal access tokens), and the organisation may require an owner to
  approve each one: until then the token is "pending" and every request
  to the org's repos fails as if it had no access.
- **Repository access:** the Cetos repos to work on, or all of them.

The repository permissions are the same as `claude-dev`'s: Contents, Pull
requests and Issues read and write, Metadata read, nothing else -- no
Administration, no Workflows -- and no account permissions.

Put it in its own env file, so it never reaches `claude-dev`:

    mkdir -p ~/.config/claude-cetos
    ( umask 077; printf 'GH_TOKEN=%s\n' '<token>' > ~/.config/claude-cetos/env )

Check it from inside `claude-cetos` with the same probes, where `<you>`
is the Cetos organisation and `<repo>` one of its repos: the first five
403, the last three 422. Then check what it can't reach, which is the
point of a separate token -- every personal repo:

    probe 'file, andapony repo' -X PUT /repos/andapony/emacs.d/contents/x.txt -f message=x
    probe 'issue, andapony repo' -X POST /repos/andapony/emacs.d/issues -f body=
    gh api user --jq .login              # robcetos

Both should be 403 (404 for a private repo). Being public, `emacs.d` can
still be read.

### A token for one repo: GH_TOKEN_EMACS_D

On a work machine `emacs.d` lives in `~/cetos/emacs.d`, so that
`claude-cetos` can work on it, but `robcetos`'s token can't push it. So
`claude-cetos`'s env file can carry a second token, for that repo alone:

- **Owner and resource owner:** `andapony`.
- **Repository access:** only `andapony/emacs.d`.
- **Repository permissions:** Contents read and write, and Metadata read
  (required). Nothing else -- no Issues, no Pull requests.
- **Account permissions:** none. **Expiration:** set one.

Add it to the env file, beside `GH_TOKEN`, then recreate the container:

    ( umask 077; printf 'GH_TOKEN_EMACS_D=%s\n' '<token>' >> ~/.config/claude-cetos/env )

Only git uses it, and only for `https://github.com/andapony/emacs.d`
(with or without `.git`, so the rewritten SSH remote is covered too). The
image's `git-credential-repo-token` is that URL's credential helper,
answering with `GH_TOKEN_EMACS_D` ahead of `gh`; for every other URL `gh`
answers with `GH_TOKEN` as before. `gh` itself only ever reads
`GH_TOKEN`, so `gh pr create` and the like on `emacs.d` act as `robcetos`,
and fail. Without the variable the helper says nothing and `gh` answers,
exactly as if it weren't there -- which is why the same entry in
`claude-dev` changes nothing. `tests/repo-token-test.sh` checks which token
git picks for which URL, with and without the variable: run `sh
tests/repo-token-test.sh`. The Dockerfile's `--add` line is where another
repo would get an entry of its own.

To check, from inside `claude-cetos`:

    cd ~/cetos/emacs.d
    git push --dry-run origin HEAD:refs/heads/x   # authenticates, sends nothing
    printf 'url=https://github.com/andapony/emacs.d\n\n' | git credential fill \
      | grep -q "password=$GH_TOKEN_EMACS_D" && echo emacs.d token
    printf 'url=https://github.com/andapony/setup\n\n' | git credential fill \
      | grep -q "password=$GH_TOKEN" && echo GH_TOKEN
    gh api user --jq .login                       # robcetos, not andapony

And probe the token itself, by handing it to `gh` for these requests
only:

    GH_TOKEN=$GH_TOKEN_EMACS_D probe 'file, emacs.d'    -X PUT /repos/andapony/emacs.d/contents/x.txt -f message=x
    GH_TOKEN=$GH_TOKEN_EMACS_D probe 'workflow, emacs.d' -X PUT /repos/andapony/emacs.d/contents/.github/workflows/x.yml -f message=x
    GH_TOKEN=$GH_TOKEN_EMACS_D probe 'issue, emacs.d'   -X POST /repos/andapony/emacs.d/issues -f body=
    GH_TOKEN=$GH_TOKEN_EMACS_D probe 'file, other repo' -X PUT /repos/andapony/<repo>/contents/x.txt -f message=x
    GH_TOKEN=$GH_TOKEN_EMACS_D probe 'create repo'      -X POST /user/repos -f name=

The first should be 422, the rest 403 (404 for a private repo).

The token can push `emacs.d` from an agent on the company's Claude
account. That is accepted: it is less than `claude-dev`'s token reaches,
and the ruleset on `emacs.d`'s `main` blocks force-pushes and deletion.

### Switching claude-cetos's Claude login

Its login lives in `claude-cetos-config`, apart from `claude-dev`'s. Log in
with `docker exec -it claude-cetos claude`, then `/login`. To switch
account -- on MrMustard it starts on the personal one, until the
company's arrives -- do the same again and `/login` as the other: the new
login replaces the old. Restart any open agent-shell session in `~/cetos`
afterwards, so it starts on the new login.

### Claude Code deny rules

These rules in `~/.claude/settings.json` catch mistakes, but they are not a
security boundary -- they match command text, which is easy to get around:

    "permissions": {
      "deny": [
        "Bash(gh repo delete:*)", "Bash(gh repo create:*)",
        "Bash(gh repo edit:*)", "Bash(gh secret:*)", "Bash(gh api:*)",
        "Bash(git push --force:*)", "Bash(git push -f:*)"
      ]
    }

## Containers: the agent's own engine, never the host's

Agents can build and run images in the container: `docker` in there is
rootless podman, running as `rob`, inside the agent container. The Mac's
engine stays out of reach. Never mount its socket
(`/var/run/docker.sock`, or OrbStack's `~/.orbstack/run/docker.sock`)
into the container, and never add `--privileged` or `--device`. With the
socket, an agent could `docker exec` into the mail container and read its
OAuth tokens and app passwords, or start a container that mounts all of
`$HOME`. A container engine's API has no scopes that would stop it.
`docs/adr/0001-nested-engine-not-host-socket.md` has the full reasoning.

What the run line adds instead (the Dockerfile header covers each):

- `--security-opt seccomp=claude-container/seccomp.json` is Docker's
  default profile, plus the syscalls a user namespace needs: `unshare`,
  `setns`, namespaced `clone`, `mount`, `umount2`, `pivot_root`, `keyctl`,
  `sethostname` and the new mount API. Creating a user namespace needs no
  capability, so the kernel's user-namespace code is what this opens to
  the agent. The mount and hostname calls still require `CAP_SYS_ADMIN` in
  the namespace they act on, and `rob` has that only inside namespaces it
  creates. `make-seccomp` regenerates the profile from a pinned upstream
  commit.
- `-v claude-dev-containers:/home/rob/.local/share/containers` holds
  podman's images, so they survive `docker rm -f claude-dev`
  (`claude-cetos-containers` for `claude-cetos`).
- `--init` makes tini PID 1, so the conmon processes podman leaves behind
  get reaped instead of piling up as zombies under `sleep infinity`.

Nested containers share the agent container's network and PID namespace
(so their entrypoint isn't PID 1), and have no cgroup limits. What a
nested container writes into a mounted `~/projects` directory is owned by
`rob` on the Mac, whatever user the image runs as. OrbStack's file sharing
records every write as the Mac user, and shows the mount as owned by
whichever UID looks at it, so a non-root image can write there too. That
holds only for the macOS mount: under podman on Linux, a non-root image
would write as a subordinate UID.

Images built in here live in the volume, so the Mac's Docker doesn't see
them. On the Mac, rebuild from the same Dockerfile.

To check it, from inside the container:

    grep CapEff /proc/self/status          # 0000000000000000
    ls -l /var/run/docker.sock ~/.orbstack 2>&1   # neither exists
    d=$(mktemp -d ~/projects/nested-check.XXXX)
    printf 'FROM debian:bookworm-slim\nRUN apt-get update && apt-get install -y --no-install-recommends hello\n' > "$d/Dockerfile"
    docker build -t nested-check "$d"
    docker run --rm -v "$d":/out nested-check sh -c 'hello > /out/hi'
    ls -ln "$d/hi"                        # uid 1000
    docker ps -a                           # nested-check at most, never mail

On the Mac, check the ownership with `ls -l ~/projects/nested-check.*/hi`.
Check persistence with `docker rm -f claude-dev`, the run line again, and
`docker exec claude-dev docker images`, which should still list
`nested-check`. Check the run line itself with `docker inspect claude-dev
--format '{{.HostConfig.Privileged}} {{.HostConfig.Devices}}
{{.HostConfig.Binds}}'`. It should show `false []`, and no bind of a
docker.sock. Afterwards, remove the scratch directory and run `docker rmi
nested-check` inside the container.

## The shared mount: don't let the host run what the agent writes

Editing the shared files from the host is safe. What isn't is host tools
*running* something the agent can write. They would run it with the host
user's full credentials -- SSH keys, broad `gh` login, everything the
container was meant to keep out.

What runs where:

| | Where | Why |
|---|---|---|
| Emacs, editing | host | plain reads and writes |
| gopls | host | type-checks without running project code (see below) |
| git, Magit | **container** | `.git/config` and `.git/hooks` are agent-writable |
| `go test` / `go run` / `go generate` | **container** | they run the agent's code |
| pushes | **container** | they use the restricted token |

### git

Magit, `vc-git` and `diff-hl` call `git` all the time, and a repo's own
config decides what that runs:

- `core.fsmonitor` -- runs a program on every `git status`, so merely
  opening a file in a vc-tracked buffer triggers it
- `.git/hooks/*` -- on commit, merge, checkout
- `core.sshCommand`, `core.pager`, `diff.external`, `filter.*` -- run
  commands; `url.*.insteadOf` redirects where a push goes

So run the host's git inside the container. The mount lands at the same
absolute path on both sides, so a wrapper only has to carry the working
directory and Magit's `GIT_*` variables across. That wrapper is
`container-git`, in this repo; it is for the host only, and the image
doesn't copy it. Repos that no container mounts -- which no agent can
see or write -- it hands to the host's git unchanged.

#### Which container: the container map

A host can run more than one agent container, each mounting its own
directory: `claude-dev` with `~/projects`, say, and a work container with
`~/work`. The **container map**, `~/.config/claude-container/containers`,
says which container owns which directory, one entry per line:

    # DIRECTORY  CONTAINER
    ~/projects   claude-dev
    ~/work       claude-work

`~` stands for `$HOME`; blank lines and `#` comments are ignored, and so is
anything after the container's name. Directories are split on whitespace,
so they can't contain spaces. The longest directory containing the repo
wins, so a nested entry can carve a subtree out for another container. A
directory no entry owns runs git on the host -- an entry is therefore also
a promise that the container mounts that directory at the same path.

Without the file, the map is the single entry `~/projects claude-dev`,
which is how `container-git` behaved before there was a map.
`CLAUDE_CONTAINER`, if set, replaces whichever container the map chose,
but never sends a directory the map doesn't list into a container.

Keep the map outside every mounted directory, as `~/.config` is: an agent
that could edit it could send the host's git for its own repos to the
host, where their hooks would run as you. The emacs.d config reads the
same file, so agent-shell starts in, and Magit's commit editor is
signalled in, the container `container-git` would use.

`tests/container-git-test.sh` checks the wrapper's choice, with a fake
`docker` and a temporary `HOME`: run `sh tests/container-git-test.sh`.

The emacs.d repo's `init.el` (its "Version control" section) points
`magit-git-executable` and `vc-git-program` at the wrapper whenever a
checkout of this repo is present and Emacs isn't itself running in a
container. On Linux, set `CONTAINER_RUNTIME=podman` in Emacs's environment.

This avoids TRAMP entirely: Magit's `default-directory` stays the local
path, git reports paths that are valid on the host too, and opening a file
from a diff gives an ordinary local buffer.

Commit messages need more. Magit's with-editor normally points
`GIT_EDITOR` at the host's `emacsclient`, which doesn't exist in the
container, so `init.el` sets `with-editor-emacsclient-executable` to nil.
with-editor then uses its "sleeping editor": a shell snippet that prints
the file to open and sleeps until signalled. Opening works because the
paths match; finishing doesn't on its own, because with-editor signals the
editor's PID with a `kill` on the host, and that PID is the container's.
`init.el` advises `with-editor-return` to send the signal in the container
instead -- the one the map gives for the buffer's directory, the same one
`container-git` ran git in.

Not yet tried in practice: committing that way end to end, and speed --
every git call pays for a `docker exec`, and Magit and vc make many.

The lighter alternative is to keep host git and override the dangerous
settings on its command line, where `-c` beats repo config:

    (setq magit-git-global-arguments
          (append '("-c" "core.fsmonitor=false" "-c" "core.hooksPath=/dev/null"
                    "-c" "core.sshCommand=ssh" "-c" "core.pager=cat")
                  magit-git-global-arguments))

That only covers Magit, can't cover `filter.<name>` or `url.*.insteadOf`
(their names are arbitrary), and disables legitimate hooks too.

Whichever you use, push only from the container.

### Go

gopls stays on the host. It type-checks without running project code, and
Go has no install scripts or build-time code. What's left:

- **cgo** -- gopls runs the C compiler with flags from `#cgo` lines. They
  are checked against an allowlist, but this has been the source of past
  Go security bugs. Keep Go and gopls up to date on the host.
- **`toolchain` in go.mod** -- makes `go` download and switch versions.
  Only official, checksum-verified releases, but turn it off on the host
  anyway so a version change is something you decide:

      go env -w GOTOOLCHAIN=local

Anything that *runs* the code -- `go test`, `go run`, `go generate`, gopls
code lenses that run tests -- goes through the container:

    (setq compile-command "docker exec -w \"$PWD\" claude-dev go test ./...")

### Everything else

- `.dir-locals.el`: Emacs asks before applying unsafe local variables.
  Answer "no" or "this time only", never "always", for agent-written repos.
- `.envrc`: direnv asks for re-approval whenever the file changes.
- Any other host tool pointed at `~/projects` -- editor plugins, scripts
  you run by hand -- is the same risk. Run those in the container too.
