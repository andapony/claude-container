# Claude Code + agent-shell dev container
#
# The runtime differs by platform: Docker on macOS, rootless podman on Linux.
# Both mount ~/projects at the same absolute path inside and out, so no path
# translation is needed anywhere — agent-shell, compile output, diffs, and
# transcripts all reference host-valid paths.
#
# macOS (OrbStack's docker CLI):
#   docker build -t claude-dev --build-arg HOST_HOME="$HOME" claude-container
#   docker run -d --name claude-dev --env-file "$HOME/.config/claude-dev/env" -v "$HOME/projects":"$HOME/projects" -w "$HOME/projects" -v claude-config:/home/rob/.claude claude-dev sleep infinity
#   docker exec -it claude-dev claude     # first run only, to log in
#   docker exec -it claude-dev zsh        # interactive shell
#
# Linux (rootless podman, not Docker -- see the setup playbook's `podman' tag
# for why: no root-equivalent `docker' group, and podman's user-space
# networking keeps container egress subject to OpenSnitch, which Docker's
# kernel-forwarded bridge egress escapes):
#   podman build --format docker -t claude-dev --build-arg HOST_HOME="$HOME" claude-container
#   podman run -d --name claude-dev --userns=keep-id --env-file "$HOME/.config/claude-dev/env" -v "$HOME/projects":"$HOME/projects" -w "$HOME/projects" -v claude-config:/home/rob/.claude:U claude-dev sleep infinity
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
#   --build-arg MU_VERSION=... --build-arg MU_SHA256=...
#                                  # both together, as for Emacs; must match
#                                  # setup's mu_version (see the ARG)
#   --build-arg HOST_HOME=/home/you # where the host's home is, for the
#                                  # ~/projects alias (default /Users/rob)
#   --build-arg GIT_USER_EMAIL=... --build-arg GIT_USER_NAME=...
#                                  # identity for commits made in here
#                                  # (default Rob Duncan andapony@…)
#   --build-arg GITHUB_SSH_ALIAS=github-you
#                                  # host's ~/.ssh/config alias for GitHub,
#                                  # rewritten to HTTPS in here (default
#                                  # github-andapony)
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
#   - --env-file supplies GH_TOKEN, the container's only GitHub credential:
#     a fine-grained token, one `GH_TOKEN=...' line, kept outside ~/projects
#     and mode 600. The file must exist or `run' fails; create it first.
#     Env is fixed at `run', so a new token means recreating the container.
#     gh prefers GH_TOKEN to a stored login, and git reaches it through the
#     credential helper set up below. Don't `gh auth login' in here: that
#     stores a far broader token, in ~/.config/gh, which no volume persists.
#   - AGENT-ACCESS.md covers scoping that token, keeping it the only
#     GitHub credential in here, and what the host should not run from
#     the shared mount.

# mu's pin, declared before the first FROM so that the stage building mu and
# the final stage checking it read the one value. MU_VERSION is the twin of
# `mu_version' (and MU_SHA256 of `mu_sha256') in the setup repo's
# playbook.yml, which builds mu on the Linux hosts: the two pins move
# together, so bump one and the other in the same change.
ARG MU_VERSION=1.14.3
ARG MU_SHA256=edea1a4e6be390a2bf5260e0156813f9b473c2d91da934b219dbb38229b0930a

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
# mu builder -- mu, and with it mu4e, installed under ~/.local/mu, where the
# Emacs config looks for both. emacs.d's mail code is developed and tested
# against this mu, so it is built at the version the hosts run: MU_VERSION,
# pinned at the top of this file.
#
# mu 1.14 needs GLib >= 2.80, and bookworm ships 2.74. The fix is a private
# GLib, built here into mu's own prefix, with mu's binary carrying an RPATH
# to it. The alternatives were worse:
#   - Rebasing the whole image on trixie (GLib 2.84) would move every
#     package above -- libgccjit, tree-sitter, chromium -- and the Emacs
#     build with it, to land one mail indexer.
#   - Building mu in a trixie stage and copying it over cannot work: a
#     trixie binary wants trixie's glibc and libstdc++, newer than
#     bookworm's, so it would not even start here.
# The private GLib stays out of the system's way: it is in no ld.so path,
# and only mu finds it, through that RPATH. DT_RPATH, deliberately, rather
# than the DT_RUNPATH a modern linker writes by default: RUNPATH covers only
# mu's own dependencies, so bookworm's gmime, loading GLib in turn, could
# pull in the system's 2.74 beside the private 2.80. RPATH covers the whole
# load. The rest of mu's needs bookworm meets as is: gmime 3.2.13 and
# xapian 1.4.22 are mu's minimums exactly, and gcc 12 does C++20.
#
# Built FROM the Emacs builder because mu4e is byte-compiled by the Emacs
# that will load it, and mu only builds mu4e when `-Demacs=' names one --
# without it, it silently skips mu4e and the man pages. Copying the install
# tree to /usr/local gives that Emacs every library it links, since this
# stage still has the -dev packages. A rebuilt Emacs rebuilds mu too, which
# is right: the .elc files should come from the Emacs that runs them.
#
# Meson comes from pip, pinned: bookworm's 1.0.1 is older than either
# project accepts (GLib 2.80 wants 1.2, mu 1.14 1.3.2). 1.3.2 is the version
# the Linux hosts' Mint 22 ships, so this builds with the same Meson they
# do. `packaging' is a GLib build requirement, in the venv Meson runs from.
# texinfo, already here, and install-info build mu4e's Info manual, which
# is otherwise silently skipped. Completions are off because they would
# install outside the prefix; scm (Guile) and cld2 are off so the result
# does not depend on what happens to be installed -- the same set of
# options as setup's build.
# ---------------------------------------------------------------------------
FROM emacs-builder AS mu-builder

ARG MU_VERSION
ARG MU_SHA256
ARG GLIB_VERSION=2.80.5
# sha256 from GNOME's published glib-2.80.5.sha256sum.
ARG GLIB_SHA256=9f23a9de803c695bbfde7e37d6626b18b9a83869689dd79019bf3ae66c3e6771
ARG MESON_VERSION=1.3.2

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3-venv ninja-build install-info \
      libffi-dev libpcre2-dev libgmime-3.0-dev libxapian-dev \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/meson \
    && /opt/meson/bin/pip install --no-cache-dir "meson==${MESON_VERSION}" packaging
ENV PATH=/opt/meson/bin:$PATH

RUN cp -a /emacs-root/usr/local/. /usr/local/

# The prefix is the path mu runs from in the final image, and both install
# straight into it, the final stage copying the whole tree. Not a DESTDIR
# staging install: mu's RPATH and GLib's .pc files record the prefix, and
# mu skips install-info -- leaving the Info manual out of `dir' -- under a
# DESTDIR.
ENV MU_PREFIX=/home/rob/.local/mu
WORKDIR /usr/src
RUN set -eux; \
    curl -fsSL --retry 2 -o glib.tar.xz \
      "https://download.gnome.org/sources/glib/${GLIB_VERSION%.*}/glib-${GLIB_VERSION}.tar.xz"; \
    echo "${GLIB_SHA256}  glib.tar.xz" | sha256sum -c -; \
    curl -fsSL --retry 2 -o mu.tar.xz \
      "https://github.com/djcb/mu/releases/download/v${MU_VERSION}/mu-${MU_VERSION}.tar.xz"; \
    echo "${MU_SHA256}  mu.tar.xz" | sha256sum -c -; \
    tar -xf glib.tar.xz; \
    tar -xf mu.tar.xz

WORKDIR /usr/src/glib-${GLIB_VERSION}
RUN meson setup build --prefix="${MU_PREFIX}" --libdir=lib \
      -Dtests=false -Dintrospection=disabled -Ddocumentation=false \
      -Dman-pages=disabled -Dnls=disabled -Dselinux=disabled \
      -Dlibmount=disabled -Dsysprof=disabled \
    && meson compile -C build \
    && meson install -C build

WORKDIR /usr/src/mu-${MU_VERSION}
RUN PKG_CONFIG_PATH="${MU_PREFIX}/lib/pkgconfig" \
    LDFLAGS="-Wl,-rpath,${MU_PREFIX}/lib -Wl,--disable-new-dtags" \
    meson setup build --prefix="${MU_PREFIX}" --libdir=lib \
      -Demacs=/usr/local/bin/emacs \
      -Dscm=disabled -Dcld2=disabled -Dtests=disabled \
      -Dbash-completion=disabled -Dzsh-completion=disabled \
    && meson compile -C build \
    && meson install -C build \
    && test -f "${MU_PREFIX}/share/emacs/site-lisp/mu4e/mu4e.elc"

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
#
# The spelling packages serve the Emacs config's two checkers. aspell and
# aspell-en are what ispell and flyspell run: init.el names aspell and the
# en_US dictionary outright. jinx instead calls libenchant through a C module
# it compiles on first load with `cc' and `pkg-config --cflags --libs
# enchant-2' -- hence the -dev package and pkg-config, here in the runtime
# image rather than the builder, because the compile happens in a running
# container. Debian's libenchant-2-2 carries its own aspell backend, so both
# checkers read the one dictionary. enchant-2 adds the `enchant-lsmod-2' CLI,
# for seeing which backend and dictionaries enchant actually found.
#
# libgmime-3.0-0 and libxapian30 are what the mu built above links from the
# system; its GLib it carries in its own prefix.
RUN apt-get update && apt-get install -y git gh zsh curl \
      ripgrep file patch less jq xz-utils \
      libgccjit0 libgnutls30 libtree-sitter0 libsqlite3-0 \
      libncursesw6 libxml2 zlib1g libgmp10 \
      chromium fonts-liberation fonts-noto-color-emoji \
      aspell aspell-en libenchant-2-dev enchant-2 pkg-config \
      libgmime-3.0-0 libxapian30 \
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
# inherits correct ownership on first mount (EACCES fix). ~/.local
# likewise, so the COPY of mu below does not create it as root.
RUN mkdir -p /home/rob/.claude /home/rob/.local

# mu from the builder stage, owned by rob so it can be rebuilt by hand in a
# running container. The check proves, before the layer is committed, that
# mu starts here -- every library it needs resolving in this image, not the
# builder's -- and is the pinned version, with its mu4e beside it.
#
# INFOPATH puts mu4e's manual in `C-h i': Emacs searches no Info directory
# under ~/.local/mu. The trailing colon keeps Emacs's own directories after
# it, rather than replacing them.
ARG MU_VERSION
COPY --from=mu-builder --chown=rob:rob /home/rob/.local/mu/ /home/rob/.local/mu/
RUN test "$(/home/rob/.local/mu/bin/mu --version)" = "version ${MU_VERSION}" \
    && test -f /home/rob/.local/mu/share/emacs/site-lisp/mu4e/mu4e.elc
ENV INFOPATH=/home/rob/.local/mu/share/info:

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

# git reaches GitHub over HTTPS only, with the GH_TOKEN passed at `run'.
# The credential helper is what `gh auth setup-git' writes -- the empty
# entry first clears any helper an earlier config layer set, so nothing but
# gh answers for github.com -- spelled out because setup-git refuses to run
# without a login, and there is none at build time. gh reads GH_TOKEN each
# time git asks, so the token is never in the image.
#
# The host's repos have SSH remotes, most through an ~/.ssh/config alias
# that exists only on the host. Rewriting them here, rather than changing
# the remotes, leaves the host pushing over SSH as before, while in here
# the same remotes go over HTTPS -- there is no SSH key in here to use.
ARG GITHUB_SSH_ALIAS=github-andapony
RUN git config --global credential.https://github.com.helper '' \
    && git config --global --add credential.https://github.com.helper '!gh auth git-credential' \
    && git config --global url.https://github.com/.insteadOf "git@${GITHUB_SSH_ALIAS}:" \
    && git config --global --add url.https://github.com/.insteadOf git@github.com:

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
