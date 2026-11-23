#!/bin/sh
# Lets ONE user run exactly these pmset commands as root without a password:
#   pmset -a disablesleep 0 | 1   (keep awake with lid closed / restore)
#   pmset sleepnow
# Usage: sudo sh setup-sudo.sh <username>     Undo: sudo rm /etc/sudoers.d/lidllm
set -e
USER_NAME="${1:-$SUDO_USER}"
case "$USER_NAME" in ""|*[!A-Za-z0-9._-]*) echo "bad username: $USER_NAME" >&2; exit 1;; esac
TMP=$(mktemp)
cat > "$TMP" <<RULE
$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset sleepnow
RULE
/usr/sbin/visudo -cf "$TMP"
install -m 0440 -o root -g wheel "$TMP" /etc/sudoers.d/lidllm
rm -f "$TMP"
echo "Installed /etc/sudoers.d/lidllm for $USER_NAME"
