#!/bin/bash
# Removes the sudoers rule, Application Support files, and hotspot Keychain items.
# Does not delete Awake.app. Quit Awake first, then delete the app yourself.
# Keychain deletion runs as the invoking user. The sudoers file is removed as root.
set -euo pipefail

SUPPORT="${HOME}/Library/Application Support/Awake"
if [[ -d "$SUPPORT" ]]; then
  rm -rf "$SUPPORT"
  echo "Removed $SUPPORT"
else
  echo "No Application Support directory."
fi

while security delete-generic-password -s "com.awake.menubar.hotspot" >/dev/null 2>&1; do
  echo "Removed a hotspot Keychain item."
done

if [[ -f /etc/sudoers.d/awake ]]; then
  sudo rm -f /etc/sudoers.d/awake
  echo "Removed /etc/sudoers.d/awake"
else
  echo "No sudoers rule installed."
fi

echo "If you copied binaries, also remove /Applications/Awake.app and /usr/local/bin/awake /usr/local/bin/asleep."
