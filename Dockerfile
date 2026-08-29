# Claude Code + agent-shell dev container
#
# Build:
#   docker build -t claude-dev claude-container
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
#
# Run (identity mount: same absolute path inside and out, so no
# path translation is needed anywhere — agent-shell, compile
# output, diffs, and transcripts all reference host-valid paths):
#   docker run -d --name claude-dev -v "$HOME/projects":"$HOME/projects" -w "$HOME/projects" -v claude-config:/home/rob/.claude claude-dev sleep infinity
#
# Notes:
#   - The mount is the entire host-visibility policy: everything
#     under ~/projects is in scope for every session. For untrusted
#     or unattended (--dangerously-skip-permissions) work, prefer a
#     separate narrow container mounting a throwaway clone only.
#   - -w is just the default for interactive `docker exec` shells;
#     agent-shell anchors each session's cwd per-project via ACP.
#   - First run only: `docker exec -it claude-dev claude` to log in
#     (use the paste-code fallback if the browser callback fails).
#   - Emacs is a terminal build (no X/GUI): it is here for in-container
#     `emacs -nw`, batch/ert runs, and as the TRAMP-side remote Emacs.
#   - gh keeps its credentials in ~/.config/gh, which no volume above
#     persists: `gh auth login` has to be repeated whenever the container
#     is recreated. To skip that, pass a token instead -- `docker run -e
#     GH_TOKEN=...` -- which gh prefers over its stored login anyway.

# ---------------------------------------------------------------------------
# Emacs builder — kept in its own stage so ~600MB of -dev packages and the
# source tree never land in the final image. Only the install tree is copied.
# ---------------------------------------------------------------------------
FROM golang:1.27-bookworm AS emacs-builder

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
FROM golang:1.27-bookworm

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
RUN apt-get update && apt-get install -y git gh zsh curl \
      ripgrep file patch less jq xz-utils \
      libgccjit0 libgnutls30 libtree-sitter0 libsqlite3-0 \
      libncursesw6 libxml2 zlib1g libgmp10 \
    && rm -rf /var/lib/apt/lists/*

# C.UTF-8 is built into glibc, so this costs no package and no layer.
# Without it the container runs under LC_CTYPE=POSIX, which drops Emacs
# into the ASCII language environment -- `emacs -nw' then cannot render
# the box-drawing rules and arrows this config is full of. tzdata is
# already in the base image, so TZ alone is enough to get local time.
ENV LANG=C.UTF-8
ENV TZ=America/Los_Angeles

COPY --from=emacs-builder /emacs-root/usr/local/ /usr/local/

RUN useradd -m -s /bin/zsh rob
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
# Safe as a plain `ln -s' here: /home/rob is freshly created, so there is no
# existing directory for the link to be created inside of instead.
ARG HOST_HOME=/Users/rob
RUN ln -s "${HOST_HOME}/projects" /home/rob/projects

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
RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash \
    && . "$NVM_DIR/nvm.sh" \
    && nvm install --lts \
    && npm install -g @agentclientprotocol/claude-agent-acp \
    && ln -s "$(dirname "$(nvm which node)")" "$NVM_DIR/current" \
    && CLAUDE_BIN="$(ls "$(npm root -g)"/@agentclientprotocol/claude-agent-acp/node_modules/@anthropic-ai/claude-agent-sdk-*/claude)" \
    && ln -s "$CLAUDE_BIN" "$NVM_DIR/current/claude" \
    && "$NVM_DIR/current/claude" --version

ENV PATH=/home/rob/.nvm/current:$PATH
ENV CLAUDE_CONFIG_DIR=/home/rob/.claude

# The bundled binary carries its own updater. Letting it self-update
# would desync it from the SDK release that pins it -- the pairing the
# single-binary layout above exists to preserve. Updates come from
# rebuilding this image, which re-resolves the adapter to latest.
# Interactive Claude Code on the host is installed separately by the
# setup playbook's native installer and still updates itself.
ENV DISABLE_AUTOUPDATER=1
