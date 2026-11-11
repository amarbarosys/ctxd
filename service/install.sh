#!/usr/bin/env bash
# Install ctxd as a systemd user service: binary + the Mojo runtime libs it links into ~/.local/opt/ctxd.
# Config: ~/.config/ctxd/ctxd.toml, secrets in ~/.config/ctxd/env (CTXD_SUMMARIZER_KEY=...), mode 600.
set -euo pipefail
cd "$(dirname "$0")/.."
opt=$HOME/.local/opt/ctxd
mkdir -p .work "$opt/lib" "$HOME/.config/ctxd" "$HOME/.config/systemd/user"
mojo build -I src -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/src" -I "${MOJO_BENTO:-$HOME/Projects/mojo/mojo-bento}/lib" src/ctxd/main.mojo -o .work/ctxd-svc 2> .work/ctxd-svc.err || { tail .work/ctxd-svc.err; echo "FAIL build: mojo build"; exit 1; }
libs=$(ldd .work/ctxd-svc | awk '/modular\/lib/ {print $3}')
[ -n "$libs" ] || { echo "FAIL libs: ldd found no Mojo runtime libs"; exit 1; }
cp -L $libs "$opt/lib/"
install -m 755 .work/ctxd-svc "$opt/ctxd.new" && mv "$opt/ctxd.new" "$opt/ctxd"
install -m 644 service/ctxd.service "$HOME/.config/systemd/user/ctxd.service"
systemctl --user daemon-reload
systemctl --user enable --now ctxd >/dev/null 2>&1
systemctl --user restart ctxd
echo "installed $(du -sh "$opt" | cut -f1) in $opt"
