# ctxd

Context-folding proxy for online and local LLM APIs. It sits between a client such as Claude Code
and the API, folds old context into summaries, and keeps a local store. It listens on localhost only.

## Run

    docker/build.sh                 # image ctxd:latest from a host build (binary + Mojo runtime libs)
    docker/run.sh                   # 127.0.0.1:8787 on the host network, store in ~/.cache/ctxd, ./ctxd.toml if present
    ANTHROPIC_BASE_URL=http://127.0.0.1:8787 claude

Config keys: see the header of `src/ctxd/main.mojo`. Without `[summarizer] url`, ctxd is a plain
passthrough.

Or as a systemd user service: `service/install.sh` builds ctxd into `~/.local/opt/ctxd` and
enables `ctxd.service`. Config goes in `~/.config/ctxd/ctxd.toml`, the summarizer key in
`~/.config/ctxd/env` (mode 600).

## Build and test

Needs Mojo and a [mojo-bento](https://github.com/amarbaro/mojo-bento) checkout next to this repo,
with its `scripts/deps.sh` run once so that `mojo-bento/lib/` exists. For another location, set
`MOJO_BENTO` to that checkout.

    tests/gate-s0.sh                # passthrough against a local fake upstream
    tests/gate-s1.sh                # store round trip, torn-tail recovery, on-disk format
    tests/gate-s2.sh                # header relay, error frame, fold policy, summarizer failure
    tests/gate-s3.sh                # ctx_expand, ctx_search, compress
    tests/gate-s4.sh                # the Docker image passes the S0 checks (needs docker)

All gates are local, no paid API. Run them one at a time; they share `.work/` builds.

## License

Apache-2.0 (`LICENSE`).
