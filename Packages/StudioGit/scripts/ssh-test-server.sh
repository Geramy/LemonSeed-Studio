#!/usr/bin/env bash
#
# Start a throwaway OpenSSH server on 127.0.0.1 for GitKit's SSH transport
# tests, then run them:
#
#   scripts/ssh-test-server.sh            start server, run SSH tests, stop
#   scripts/ssh-test-server.sh serve      start server and wait (Ctrl-C stops)
#
# The server runs as the current user on port $PORT (default 2222) with a
# fresh host key, no passwords, and an authorized_keys file the tests write
# their freshly generated public keys into. It serves a bare repository at
# $DIR/server.git. The tests run on the Mac (`swift test`); with
# `scripts/test.sh --ios` the simulator reaches the same loopback and files.
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
: "${PORT:=2222}"
DIR="$(mktemp -d /tmp/studiogit-ssh.XXXXXX)"
trap 'kill "$(cat "$DIR/sshd.pid" 2>/dev/null)" 2>/dev/null || true; rm -rf "$DIR"' EXIT

ssh-keygen -q -t ed25519 -N '' -f "$DIR/host_ed25519"
: >"$DIR/authorized_keys"
chmod 600 "$DIR/authorized_keys"
git init -q --bare -b main "$DIR/server.git"

cat >"$DIR/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $DIR/host_ed25519
AuthorizedKeysFile $DIR/authorized_keys
PidFile $DIR/sshd.pid
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM no
StrictModes no
PubkeyAcceptedAlgorithms ssh-ed25519,ecdsa-sha2-nistp256
LogLevel VERBOSE
EOF

/usr/sbin/sshd -f "$DIR/sshd_config" -E "$DIR/sshd.log"
for _ in $(seq 50); do [[ -f "$DIR/sshd.pid" ]] && break; sleep 0.1; done
echo "sshd on 127.0.0.1:$PORT, repository $DIR/server.git, user $(whoami)"

export STUDIOGIT_SSH_TEST_DIR="$DIR"
export STUDIOGIT_SSH_TEST_PORT="$PORT"
export STUDIOGIT_SSH_TEST_USER="$(whoami)"
if [[ "${1:-test}" == serve ]]; then
  echo "export STUDIOGIT_SSH_TEST_DIR=$DIR STUDIOGIT_SSH_TEST_PORT=$PORT STUDIOGIT_SSH_TEST_USER=$(whoami)"
  while kill -0 "$(cat "$DIR/sshd.pid")" 2>/dev/null; do sleep 1; done
else
  "$HERE/scripts/test.sh" SSHTransportTests || { tail -30 "$DIR/sshd.log"; exit 1; }
  # Cross-check GitKit's sshsig commit signatures with Git and OpenSSH.
  for repo in "$DIR"/signed-*; do
    git -C "$repo" -c gpg.format=ssh -c gpg.ssh.allowedSignersFile="$repo/allowed_signers" verify-commit HEAD
    echo "verified: $(basename "$repo")"
  done
fi
