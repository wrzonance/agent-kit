# bench/container/Dockerfile -- Tier-1 trial container (epic #152, issue #327).
#
# One image, one trial, then destroyed (bench/run-trial.sh; see the design
# doc's "Environment" section). Every package below is pinned -- base image
# by digest, apt packages by exact version string, the Codex CLI binary by
# its published sha256 -- so a trial run next month builds the identical
# container a trial run today did, and a token-count delta can never be
# quietly explained by "the image drifted."
#
# How each pin was resolved (recorded so a future re-pin repeats the same
# method, not a different one):
#   base digest    docker pull debian:13 && docker inspect \
#                     --format='{{index .RepoDigests 0}}' debian:13
#   apt versions    docker run --rm <base digest> bash -c \
#                     'apt-get update -qq && apt-cache policy <pkg>'
#                   (gh's version resolved the same way, after adding its
#                   own apt repo below -- see the gh block)
#   codex digest    gh api repos/openai/codex/releases/tags/rust-v0.148.0 \
#                     --jq '.assets[] | select(.name=="codex-x86_64-unknown-linux-musl.zst") | .digest'
#                   (GitHub's release-asset API returns a server-computed
#                   sha256 digest per asset -- not a checksum this Dockerfile
#                   invented, and not trusted from the release NOTES, which
#                   are attacker-editable prose; see security.md's "vet
#                   third-party" and "meta-risk" guidance.)
#
# debian:13 (trixie), pinned by digest -- see above for how this was resolved.
FROM debian@sha256:34cd9e9fd437c0a095ec39cb2e73422c9f30821b0d0848ed74fd0d43bae4d958

# Every apt package pinned to the exact version string trixie served when
# this file was authored (see the resolution commands above). apt refuses
# the install outright if that exact version is no longer offered, which is
# the point: a silent newer git/node/python3 must never sneak into a trial
# container unnoticed. Re-pin deliberately (re-run the apt-cache policy
# commands above against a fresh debian:13 digest) rather than dropping the
# version pins to "whatever's current."
RUN apt-get update -qq && apt-get install -y --no-install-recommends -qq \
        git=1:2.47.3-0+deb13u1 \
        jq=1.7.1-6+deb13u3 \
        python3=3.13.5-1 \
        nodejs=20.19.2+dfsg-1+deb13u2 \
        ca-certificates=20250419 \
        curl=8.14.1-2+deb13u4 \
        zstd=1.5.7+dfsg-1 \
        gnupg2=2.4.7-21+deb13u1 \
    && rm -rf /var/lib/apt/lists/*

# gh (GitHub CLI) is not in Debian's own archive -- installed from GitHub's
# official apt repo, keyed by GitHub's own published keyring (fetched over
# TLS, not piped into a shell -- see security.md's supply-chain guidance),
# then pinned to the exact version trixie's copy of that repo served when
# this file was authored.
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update -qq \
    && apt-get install -y --no-install-recommends -qq gh=2.98.0 \
    && rm -rf /var/lib/apt/lists/*

# Codex CLI: the standalone musl release binary, pinned to rust-v0.148.0 and
# verified against the sha256 GitHub's release-asset API reports for this
# exact asset (see the header comment) before it is ever executed.
RUN set -eu; \
    codex_sha256=94f6ad3c1fa479a35f7826a500da7fde0c4f07e27a3fd9f84eb4e858638576c3; \
    curl -fsSL \
        https://github.com/openai/codex/releases/download/rust-v0.148.0/codex-x86_64-unknown-linux-musl.zst \
        -o /tmp/codex.zst; \
    printf '%s  %s\n' "$codex_sha256" /tmp/codex.zst | sha256sum -c -; \
    zstd -d /tmp/codex.zst -o /usr/local/bin/codex; \
    chmod 0755 /usr/local/bin/codex; \
    rm -f /tmp/codex.zst

# Non-root: the container mounts a baked-empty home (bench/run-trial.sh,
# bench/lib/home-empty.sh) and the plugin worktree read-only at the arm's
# SHA, and never runs as the image's own root user.
RUN useradd --create-home --home-dir /home/bench --shell /bin/bash bench
USER bench
WORKDIR /home/bench

# No secret is ever an ARG or ENV here -- baking a secret into an image
# layer would leak it to anyone who can `docker history`/`docker save` the
# image. Secrets (GH_TOKEN, the Codex auth used for the pinned model) are
# injected at `docker run` time via -e, by bench/run-trial.sh's container
# lifecycle helper (bench/lib/container-lifecycle.sh) -- never written here.
#
# No ENTRYPOINT/CMD: bench/run-trial.sh drives every trial's exact command
# (repo reset, the `/parallel-issues ...` invocation, oracle injection) via
# `docker run ... codex ...` / `docker exec`, so the image itself carries no
# opinion about what a trial runs.
