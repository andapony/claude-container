# Claude Code + agent-shell dev container
#
# The runtime differs by platform: Docker on macOS, rootless podman on Linux.
# Both mount ~/projects at the same absolute path inside and out, so no path
# translation is needed anywhere — agent-shell, compile output, diffs, and
# transcripts all reference host-valid paths.
#
# macOS (Docker Desktop):
#   docker build -t claude-dev --build-arg HOST_HOME="$HOME" claude-container
#   docker run -d --name claude-dev -v "$HOME/projects":"$HOME/projects" -w "$HOME/projects" -v claude-config:/home/rob/.claude claude-dev sleep infinity
#   docker exec -it claude-dev claude     # first run only, to log in
#   docker exec -it claude-dev zsh        # interactive shell
#
# Linux (rootless podman, not Docker -- see the setup playbook's `podman' tag
# for why: no root-equivalent `docker' group, and podman's user-space
# networking keeps container egress subject to OpenSnitch, which Docker's
# kernel-forwarded bridge egress escapes):
#   podman build --format docker -t claude-dev --build-arg HOST_HOME="$HOME" claude-container
#   podman run -d --name claude-dev --userns=keep-id -v "$HOME/projects":"$HOME/projects" -w "$HOME/projects" -v claude-config:/home/rob/.claude:U claude-dev sleep infinity
#   podman exec -it claude-dev claude     # first run only, to log in
#   podman exec -it claude-dev zsh        # interactive shell
#
# Why the Linux invocation carries three extra pieces:
#   --format docker   podman defaults to the OCI image format, which has no
#                     SHELL directive, so the `SHELL ["/bin/bash", "-c"]'
#                     below is discarded with a warning and the nvm layer
#                     runs under dash. It survives that today only because
#                     NVM_DIR is set explicitly as well; the directive is
#                     here to be honoured, not to be redundant.
#   --userns=keep-id  maps the host user to the same UID in here, so files
#                     written into the mount stay owned by that user on the
#                     host. Without it rootless podman maps this container's
#                     rob to an unrelated subuid and everything it writes
#                     lands misowned.
#   :U on the volume  chowns the named volume to the mapped user on first
#                     mount -- the keep-id counterpart of the mkdir below.
#
# HOST_HOME is passed on both, but does opposite things: on macOS it is the
# /Users/rob the ~/projects alias points at, and on Linux it is /home/rob,
# which suppresses that alias entirely because the mount already lands there.
#
# Build knobs (all optional):
#   --build-arg NATIVE_COMP=yes    # lazy nativecomp; much faster image build
#   --build-arg EMACS_VERSION=... --build-arg EMACS_SHA256=...
#                                  # both together — the checksum is enforced,
#                                  # so bumping the version alone fails loudly
#   --build-arg HOST_HOME=/home/you # where the host's home is, for the
#                                  # ~/projects alias (default /Users/rob)
#   --build-arg GIT_USER_EMAIL=... --build-arg GIT_USER_NAME=...
#                                  # identity for commits made in here
#                                  # (default Rob Duncan andapony@…)
#   --build-arg ACP_VERSION=0.81.2 # claude-agent-acp release to install
#                                  # (default latest). Pass it to update
#                                  # the adapter -- a plain rebuild
#                                  # reuses the cached one (see the ARG)
#   --build-arg PLAYWRIGHT_VERSION=1.63.0
#                                  # playwright-core release (default
#                                  # latest); same caching rule as above
#
# Notes:
#   - The mount is the entire host-visibility policy: everything
#     under ~/projects is in scope for every session. For untrusted
#     or unattended (--dangerously-skip-permissions) work, prefer a
#     separate narrow container mounting a throwaway clone only.
#   - -w is just the default for the interactive `exec` shells above;
#     agent-shell anchors each session's cwd per-project via ACP.
#   - The login above is needed once per container, not once per session
#     (use the paste-code fallback if the browser callback fails).
#   - Emacs is a terminal build (no X/GUI): it is here for in-container
#     `emacs -nw`, batch/ert runs, and as the TRAMP-side remote Emacs.
#   - gh keeps its credentials in ~/.config/gh, which no volume above
#     persists: `gh auth login` has to be repeated whenever the container
#     is recreated. To skip that, pass a token instead -- `docker run`/
#     `podman run -e GH_TOKEN=...` -- which gh prefers over its stored
#     login anyway.

# ---------------------------------------------------------------------------
# Emacs builder — kept in its own stage so ~600MB of -dev packages and the
# source tree never land in the final image. Only the install tree is copied.
#
# The base image is named in full. Docker would infer docker.io/library/ from
# a bare `golang:...', but podman refuses a short name unless the host has
# configured unqualified-search-registries, which Debian and Ubuntu
# deliberately ship empty. Spelling it out builds under both.
# ---------------------------------------------------------------------------
FROM docker.io/library/golang:1.27-bookworm AS emacs-builder

ARG EMACS_VERSION=31.1
# sha256 of emacs-31.1.tar.xz, taken from a copy whose detached .sig verified
# against the GNU keyring as a good signature from the release manager
# (Sean Whitton, RSA 9B917007AE030E36E4FC248B695B7AE4BF066240).
ARG EMACS_SHA256=1da5790d9580c81932b5bf700633114468da7b3412d69faa767daebf974f4586
# aot = native-compile every bundled Lisp file at image-build time. Slow
#       (upstream's own word for it), but startup is fast and no container
#       ever has to refill its own eln-cache.
# yes = compile only preloaded Lisp; the rest is compiled just-in-time on
#       first load. Much faster build.
ARG NATIVE_COMP=aot

# gcc/g++/make/libc6-dev already come with the golang image.
# No jansson: 31.1 dropped it for a built-in JSON parser.
RUN apt-get update && apt-get install -y --no-install-recommends \
      texinfo xz-utils \
      libgccjit-12-dev \
      libgnutls28-dev libncurses-dev libtree-sitter-dev libsqlite3-dev \
      libxml2-dev zlib1g-dev libgmp-dev \
    && rm -rf /var/lib/apt/lists/*

# ftp.gnu.org first, ftpmirror as fallback; the checksum makes either safe.
WORKDIR /usr/src
RUN set -eux; \
    for url in "https://ftp.gnu.org/gnu/emacs/emacs-${EMACS_VERSION}.tar.xz" \
               "https://ftpmirror.gnu.org/emacs/emacs-${EMACS_VERSION}.tar.xz"; do \
      curl -fsSL --connect-timeout 20 --retry 2 -o emacs.tar.xz "$url" && break; \
    done; \
    echo "${EMACS_SHA256}  emacs.tar.xz" | sha256sum -c -; \
    tar -xf emacs.tar.xz

WORKDIR /usr/src/emacs-${EMACS_VERSION}
RUN ./configure \
      --prefix=/usr/local \
      --with-native-compilation=${NATIVE_COMP} \
      --with-tree-sitter --with-sqlite3 --with-modules \
      --with-gnutls --with-xml2 --with-zlib \
      --without-x --with-x-toolkit=no --without-sound \
      --without-dbus --without-gsettings --without-selinux --without-gpm \
    && make -j"$(nproc)" \
    && make install DESTDIR=/emacs-root

# ---------------------------------------------------------------------------
# Final image
# ---------------------------------------------------------------------------
FROM docker.io/library/golang:1.27-bookworm

# GitHub CLI's apt repo, added before the install below so one `apt-get
# update' covers it. gh is in no Debian suite, and the standalone .deb would
# have to be version-pinned and arch-matched by hand; the repo gets both from
# dpkg, and rebuilds pick up new releases the same way every other package
# here does. The keyring is fetched in its binary form, as GitHub documents,
# so `signed-by' can consume it directly and no gnupg is needed to dearmor.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
         -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
         > /etc/apt/sources.list.d/github-cli.list

# Shared libs the Emacs binary links against, plus the CLI tools sessions
# reach for. libgccjit0 is needed even for an AOT build, and upstream requires
# GCC + Binutils alongside it for the JIT path — the golang image already ships
# the gcc driver and binutils they need.
#
# ripgrep is not optional: init.el's `ripgrep' package shells out to `rg', and
# the `rg' visible in an agent session is a shell function pointing at Claude
# Code's vendored copy, absent from `docker exec' shells and Emacs subprocesses.
# xz-utils likewise — tar shells out to the `xz' binary rather than linking
# liblzma, so without it `tar -xf *.tar.xz' fails in the runtime image.
#
# chromium is the headless browser sessions use to render and screenshot
# HTML output -- slide decks, diagrams -- so the agent can look at what it
# built rather than reason about markup. It comes from Debian rather than
# from Playwright's own download, because Playwright's `install-deps' needs
# root and node in the same layer, and this image only has node later, as
# rob. Debian's package brings every shared library it needs with it, and
# rebuilds keep it current like everything else here. The fonts give a
# headless page real metrics: without them text falls back to whatever
# fontconfig finds, and a layout measured that way does not match a desktop.
RUN apt-get update && apt-get install -y git gh zsh curl \
      ripgrep file patch less jq xz-utils \
      libgccjit0 libgnutls30 libtree-sitter0 libsqlite3-0 \
      libncursesw6 libxml2 zlib1g libgmp10 \
      chromium fonts-liberation fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# C.UTF-8 is built into glibc, so this costs no package and no layer.
# Without it the container runs under LC_CTYPE=POSIX, which drops Emacs
# into the ASCII language environment -- `emacs -nw' then cannot render
# the box-drawing rules and arrows this config is full of. tzdata is
# already in the base image, so TZ alone is enough to get local time.
ENV LANG=C.UTF-8
ENV TZ=America/Los_Angeles

COPY --from=emacs-builder /emacs-root/usr/local/ /usr/local/

# The UID is pinned rather than left to Debian's numbering, because the Linux
# side now depends on its value: --userns=keep-id maps the host user (1000) to
# the same UID in here, and a mismatch would quietly misown the whole mount.
ARG USER_UID=1000
RUN useradd -m -s /bin/zsh -u "${USER_UID}" rob
USER rob
WORKDIR /home/rob

# Pre-create the config mountpoint as rob so the named volume
# inherits correct ownership on first mount (EACCES fix).
RUN mkdir -p /home/rob/.claude

# ~/projects as a convenience alias for the identity mount, which lands at
# the host's absolute path (/Users/rob on macOS), not under this container's
# /home/rob. Typing aid only: /Users/rob/projects stays the canonical
# spelling, because it is the one valid on both sides of the mount. Paths
# that leave the container -- diffs, compile output, transcripts -- should
# resolve to it, or the host cannot open what they name.
#
# Skipped when the host's home is this container's own /home/rob, as it is on
# a Linux host: there the identity mount already lands exactly on ~/projects,
# so there is nothing to alias -- and making one anyway would be fatal. `ln
# -s' does not object to a self-referential link, so the image would build
# clean and only fail at run time, the mount's destination resolving into an
# ELOOP.
#
# Safe as a plain `ln -s' otherwise: /home/rob is freshly created, so there is
# no existing directory for the link to be created inside of instead.
ARG HOST_HOME=/Users/rob
RUN if [ "${HOST_HOME}/projects" != "/home/rob/projects" ]; then \
        ln -s "${HOST_HOME}/projects" /home/rob/projects; \
    fi

# Git identity. Without it `git commit' in here fails outright ("Author
# identity unknown"): no repo under the mount carries a repo-local identity,
# so every one of them depends on this global.
#
# Set as --global, deliberately: that is the lowest-precedence layer, so a
# repo that later wants its own address can still override it. The
# GIT_AUTHOR_* environment variables would have been the wrong tool --
# environment beats repo config, so they would silently defeat such an
# override rather than defaulting beneath it.
#
# The address is deliberately distinct from the host's global rob@: this
# container is the boundary that marks Claude-assisted work, so commits made
# from it stay attributable without anyone setting it per repo.
ARG GIT_USER_NAME="Rob Duncan"
ARG GIT_USER_EMAIL=andapony@robduncan.info
RUN git config --global user.name "${GIT_USER_NAME}" \
    && git config --global user.email "${GIT_USER_EMAIL}"

# nvm needs bash semantics when sourced; dash misderives NVM_DIR
# from $0 as /bin. Set both explicitly (belt and suspenders).
ENV NVM_DIR=/home/rob/.nvm
SHELL ["/bin/bash", "-c"]

# Node via nvm, then the ACP adapter for agent-shell. The `current`
# symlink gives non-login shells (docker exec, TRAMP, acp.el's process
# spawn) a stable PATH entry without shell init.
#
# @anthropic-ai/claude-code is deliberately absent. The adapter never
# ran it: claude-agent-acp pins @anthropic-ai/claude-agent-sdk to an
# exact version and spawns the Claude Code binary bundled inside that
# dependency, so installing the standalone CLI only added a second,
# differently-versioned Claude Code (213MB) that nothing here used.
# Pointing `claude' at the bundled binary keeps an interactive CLI --
# it is a full Claude Code, `doctor'/`mcp'/`setup-token' included -- and
# leaves one binary, always matched to the SDK release driving it.
#
# The glob is resolved with `ls' rather than passed straight to `ln'.
# `ln -s' does not require its target to exist, so an unmatched glob --
# upstream renaming the platform package, say -- would otherwise create
# a dangling `claude' and still exit 0, shipping a broken image. `ls'
# fails on no match, and the trailing `claude --version' proves the link
# resolves before the layer is committed.
#
# ACP_VERSION is what makes an update possible. Docker caches this layer
# by its instruction text, not by what the registry would now resolve, so
# with a fixed `latest' a rebuild reuses the old adapter indefinitely --
# and --no-cache would recompile Emacs to get past it. A changed ARG
# value invalidates only the layers from here down, so naming the new
# release re-runs just this step. The version the Emacs header's update
# indicator reports is the one to pass.
ARG ACP_VERSION=latest
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install --lts \
    && npm install -g "@agentclientprotocol/claude-agent-acp@${ACP_VERSION}" \
    && ln -s "$(dirname "$(nvm which node)")" "$NVM_DIR/current" \
    && CLAUDE_BIN="$(ls "$(npm root -g)"/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-*/claude)" \
    && ln -s "$CLAUDE_BIN" "$NVM_DIR/current/claude" \
    && "$NVM_DIR/current/claude" --version

ENV PATH=/home/rob/.nvm/current:$PATH
ENV CLAUDE_CONFIG_DIR=/home/rob/.claude

# playwright-core drives the Debian chromium above. It is the library
# without the browser download -- `playwright' proper would fetch a second
# Chromium of its own on install -- so a script launches it with
# `executablePath: process.env.CHROMIUM_PATH'.
#
# A layer of its own, so bumping either version re-runs only its own step.
# PLAYWRIGHT_VERSION follows ACP_VERSION's pattern for the same reason.
#
# NODE_PATH lets a script anywhere `require("playwright-core")' without a
# package.json beside it. It goes through a symlink, like `current' above,
# because node resolves NODE_PATH lexically: `current/../lib/node_modules'
# would collapse to ~/.nvm/lib/node_modules, which does not exist. NODE_PATH
# serves `require' only; an ES module script has to use createRequire.
ARG PLAYWRIGHT_VERSION=latest
RUN . "$NVM_DIR/nvm.sh" \
    && npm install -g "playwright-core@${PLAYWRIGHT_VERSION}" \
    && ln -s "$(npm root -g)" "$NVM_DIR/global_modules"
ENV NODE_PATH=/home/rob/.nvm/global_modules
ENV CHROMIUM_PATH=/usr/bin/chromium

# page-shot: a generic screenshot command on these two, so an agent in any
# container -- including a narrow one mounting a single clone -- can look at
# an HTML page it produced. Page-specific checks stay in the page's own repo.
# The file's mode is committed executable; COPY keeps it.
COPY page-shot /usr/local/bin/page-shot

# The bundled binary carries its own updater. Letting it self-update
# would desync it from the SDK release that pins it -- the pairing the
# single-binary layout above exists to preserve. Updates come from the
# adapter instead: rebuilding with a new ACP_VERSION, or installing it
# into a running container with Emacs's
# `rjd/agent-shell-version-install-update'.
# Interactive Claude Code on the host is installed separately by the
# setup playbook's native installer and still updates itself.
ENV DISABLE_AUTOUPDATER=1
