# One image for all neodiff CI: shellcheck (shell lint), vim-vint (Vimscript
# lint), vim 8.2 with +terminal (functional tests + the term_dumpwrite golden
# harness), neovim 0.12.4 (functional + golden tests), git, and a pinned
# vim-fugitive (needed only by the golden-dump diffs). Versions are pinned so the
# committed golden screen dumps stay reproducible.
#
# Built on first use by ci/run.sh; force a rebuild with: docker build -t neodiff-ci ci
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# vim-nox is the terminal-capable ("huge") build that ships +terminal, which the
# golden harness needs for term_dumpwrite(). Ubuntu 22.04 ships vim 8.2.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        python3 \
        python3-pip \
        shellcheck \
        universal-ctags \
        vim-nox \
        zsh \
    && rm -rf /var/lib/apt/lists/*

# Vimscript linter (pinned).
RUN pip3 install --no-cache-dir vim-vint==0.3.21

# Neovim 0.12.4, unpacked rather than run (containers have no FUSE). The binary
# finds its runtime relative to itself, so a symlink onto PATH is enough.
RUN curl -fsSL -o /tmp/nvim.appimage \
        https://github.com/neovim/neovim/releases/download/v0.12.4/nvim-linux-x86_64.appimage \
    && chmod +x /tmp/nvim.appimage \
    && cd /opt && /tmp/nvim.appimage --appimage-extract >/dev/null \
    && mv /opt/squashfs-root /opt/nvim \
    && ln -s /opt/nvim/usr/bin/nvim /usr/local/bin/nvim \
    && rm /tmp/nvim.appimage

# vim-fugitive (pinned) on a known path; ci/vimrc adds it via $NEODIFF_RTP_EXTRA.
RUN git clone --filter=blob:none https://github.com/tpope/vim-fugitive /opt/vim-fugitive \
    && git -C /opt/vim-fugitive checkout -q 3b753cf8c6a4dcde6edee8827d464ba9b8c4a6f0

ENV NEODIFF_RTP_EXTRA=/opt/vim-fugitive

WORKDIR /work
