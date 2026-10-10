#!/bin/bash
# Installs a strictly scoped sudoers rule for the current user.
# Allows only:
#   /usr/bin/pmset -a disablesleep 0
#   /usr/bin/pmset -a disablesleep 1
# It does not allow Low Power Mode or any other pmset command.
# Uninstall: sudo rm /etc/sudoers.d/awake
set -euo pipefail

USER_NAME="${1:-$(id -un)}"
if ! [[ "$USER_NAME" =~ ^[A-Za-z_][A-Za-z0-9._-]{0,31}$ ]]; then
  echo "Refusing unsafe username." >&2
  exit 1
fi

if [[ "$(id -u)" -ne 0 ]]; then
  exec sudo "$0" "$@"
fi

RULE="$USER_NAME ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<EOF
# Awake — strictly scoped. Allows only disablesleep 0 and 1.
# Uninstall: sudo rm /etc/sudoers.d/awake
$RULE
EOF

visudo -cf "$TMP"
install -o root -g wheel -m 0440 "$TMP" /etc/sudoers.d/awake
echo "Installed /etc/sudoers.d/awake"
echo "$RULE"
