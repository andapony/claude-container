# Limiting what the agent can do outside the container

The container is the boundary, but two things cross it: whatever GitHub
credential is passed in, and the `~/projects` mount, which the host reads
and writes too. This covers how to keep both from widening what the agent
can do.

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
doesn't copy it. Repos outside `~/projects` -- which the container can't
see and the agent can't write -- it hands to the host's git unchanged.

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
instead.

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
