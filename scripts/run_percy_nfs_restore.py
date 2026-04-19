#!/usr/bin/env python3
"""Run percy NFS restore (steps 3–6) over SSH.

Reads SSH_PASS from repo .env. Optional SUDO_PASS for `sudo -S` (defaults to SSH_PASS).
Do not commit .env.
"""
from __future__ import annotations

import os
import shlex
import sys
import threading
from pathlib import Path

import paramiko

REPO = Path(__file__).resolve().parents[1]
ENV = REPO / ".env"
HOST = os.environ.get("PERCY_HOST", "10.10.10.54")
USER = os.environ.get("PERCY_USER", "luke")


def load_env_kv() -> dict[str, str]:
    if not ENV.is_file():
        sys.stderr.write(f"Missing {ENV}\n")
        sys.exit(1)
    out: dict[str, str] = {}
    for line in ENV.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        out[k.strip()] = v.strip().strip('"').strip("'")
    return out


def build_remote_script(sudo_pass: str) -> str:
    """Shell-quoted sudo password; all sudo uses `sudo -S`."""
    sp = shlex.quote(sudo_pass)
    return rf"""
set -euo pipefail
SP={sp}
sut() {{ echo "$SP" | sudo -S -p '' "$@"; }}
TS=$(date +%Y%m%d-%H%M%S)
echo "=== percy restore TS=${{TS}} ==="

echo "=== mount NFS ==="
sut mkdir -p /mnt/home-ops
if ! mountpoint -q /mnt/home-ops; then
  sut mount -t nfs -o vers=3,nolock,soft,timeo=600 10.10.10.215:/mnt/user/home-ops /mnt/home-ops
fi
mount | grep /mnt/home-ops || true
ls /mnt/home-ops/default/home-assistant /mnt/home-ops/default/vaultwarden

echo "=== safety rename ==="
cd /mnt/home-ops/default/home-assistant
sut mkdir -p "_pre_percy_restore_${{TS}}"
sut find . -maxdepth 1 -mindepth 1 ! -name "_pre_percy_restore_*" ! -name "_preupgrade_*" -exec mv -t "_pre_percy_restore_${{TS}}/" {{}} +
cd /mnt/home-ops/default/vaultwarden
sut mkdir -p "_pre_percy_restore_${{TS}}"
sut find . -maxdepth 1 -mindepth 1 ! -name "_pre_percy_restore_*" -exec mv -t "_pre_percy_restore_${{TS}}/" {{}} +

echo "=== stop percy HA + VW ==="
docker service scale home-assistant_home-assistant=0
docker stop networking-vaultwarden-6ild22-vaultwarden-1 2>/dev/null || true
sleep 4
docker service ls | grep home-assistant || true
docker ps -a --filter name=vaultwarden --format '{{{{.Names}}}} {{{{.Status}}}}' || true

echo "=== rsync HA ==="
sut rsync -aHAX --numeric-ids --info=stats2 \
  --exclude 'home-assistant.log*' --exclude '.ha_run.lock' --exclude 'tts/' \
  /opt/homeassistant/ /mnt/home-ops/default/home-assistant/

echo "=== rsync Vaultwarden ==="
sut rsync -aHAX --info=stats2 \
  /var/lib/docker/volumes/networking-vaultwarden-6ild22_vaultwarden/_data/ \
  /mnt/home-ops/default/vaultwarden/
sut chown -R 1000:1000 /mnt/home-ops/default/vaultwarden/

echo "=== verify ==="
echo -n "HA_VERSION="
cat /mnt/home-ops/default/home-assistant/.HA_VERSION || true
echo
ls -la /mnt/home-ops/default/home-assistant | head -35
ls -la /mnt/home-ops/default/vaultwarden
echo "=== done ==="
"""


def main() -> None:
    kv = load_env_kv()
    ssh_pass = kv.get("SSH_PASS")
    if not ssh_pass:
        sys.stderr.write("SSH_PASS missing in .env\n")
        sys.exit(1)
    sudo_pass = kv.get("SUDO_PASS") or ssh_pass

    client = paramiko.SSHClient()
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    client.connect(
        HOST,
        username=USER,
        password=ssh_pass,
        timeout=45,
        allow_agent=False,
        look_for_keys=False,
    )
    script = build_remote_script(sudo_pass)
    try:
        # No PTY: with get_pty=True, bash can linger after the script exits and Paramiko
        # buffers all output until the channel closes (looks "hung" for large rsyncs).
        stdin, stdout, stderr = client.exec_command("bash -s", get_pty=False)
        stdin.write(script)
        stdin.channel.shutdown_write()
        def _pump(stream, out_stream) -> None:
            for line in iter(stream.readline, b""):
                out_stream.write(line.decode(errors="replace"))
                out_stream.flush()

        t1 = threading.Thread(target=_pump, args=(stdout, sys.stdout))
        t2 = threading.Thread(target=_pump, args=(stderr, sys.stderr))
        t1.start()
        t2.start()
        exit_status = stdout.channel.recv_exit_status()
        t1.join()
        t2.join()
        if exit_status != 0:
            sys.exit(exit_status)
    finally:
        client.close()


if __name__ == "__main__":
    main()
