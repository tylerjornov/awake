# Awake

A small menu-bar app for Apple Silicon Macs on macOS 14 and later. It keeps a timed or indefinite coding session alive with the lid closed, pauses the apps you choose, and puts sleep back the way it found it.

Awake is menu-bar only (`LSUIElement`). It has no Dock icon, no account, and no network use except an optional hotspot join that you configure. Logs stay on disk, mode `0600`. The license is MIT.

This is intentionally not a sandbox. App Sandbox cannot `SIGSTOP` other apps, read the clamshell bit, or run `pmset` without broader entitlements. Those workarounds are out of scope. The binary is a normal user-space app you can read.

## Build

```bash
swift test
make app
```

`make app` writes `dist/Awake.app` and `dist/awake` (plus a `dist/asleep` symlink). Open the app, or copy the CLI onto your `PATH`:

```bash
cp dist/awake /usr/local/bin/awake
ln -sfn /usr/local/bin/awake /usr/local/bin/asleep
```

Ad-hoc signing is attempted so the app can talk to Keychain. Gatekeeper will still ask you to approve a local build.

## What a session does

1. Reads `disablesleep` from `pmset -g`. If that read fails, the session does not start.
2. Takes two user-level assertions: `PreventUserIdleSystemSleep` and `PreventSystemSleep`. Apple does not treat those as a reliable lid-close override, so they are not sufficient on their own.
3. Sets `disablesleep` to 1, unless it was already 1. The previous value is what gets restored.
4. If the lid is already closed, pauses the apps selected below with `SIGSTOP` (never a force-quit), turns the display and keyboard backlight off, mutes audio, and — only in admin-prompt mode — sets battery Low Power Mode.
5. Watches the timer, battery, thermal pressure, lid, and (optionally) the network. Closing the lid later does the same pause, lights, mute, and Low Power Mode. Opening the lid undoes those lid actions and leaves the session running.
6. On the way out, thaws paused apps, restores brightness, backlight, mute, and Low Power Mode if Awake changed them, restores `disablesleep`, and releases assertions.

Automatic selection matches Insomnia. Slack, WhatsApp, and Discord pause when the lid closes. “Also pause every other Dock app” also pauses running Dock apps that are not Apple apps, editors, terminals, browsers, AI apps, password managers, Tailscale, local databases, model servers, JetBrains IDEs (`com.jetbrains.*`), or meeting and recording apps. An ID on the freeze list is paused even if it would otherwise be kept. Finder, Dock, SystemUIServer, Control Center, loginwindow, Notification Center, WindowManager, Spotlight, every other `com.apple.*` app, and Awake itself are never paused.

Manual selection ignores that list. Checked apps stay running. Unchecked apps pause when the lid closes. The same system apps stay untouchable.

You can start a session for a number of days, hours, and minutes (14 days maximum) or until you stop it. Extend adds time. Extending an indefinite session turns it into a timed one starting from now.

## Privilege modes

Awake will not start a session with no privilege path. Idle assertions alone do not keep a lid-closed MacBook awake, and pretending otherwise would be worse than refusing.

| Privilege | When | What it can change |
| --- | --- | --- |
| Admin password prompt | Default. Once at start, once at end, and again if Low Power Mode toggles. | `pmset -a disablesleep 0\|1` and, only if you leave Low Power Mode on, `pmset -b lowpowermode 0\|1` |
| Sudoers rule | Optional. You install it from Settings or `Scripts/install-sudoers.sh`. | Only the two `disablesleep` commands below. Nothing else. |
| None | `sudo -n` failed, or you have not chosen a path | Session start is refused |

The prompt path is `osascript` running `do shell script "…" with administrator privileges`. The command string is an allow-list. It is never built from something you typed.

There is no LaunchAgent, no launch daemon, no kext, and no always-on recovery helper.

### The sudoers rule

For a user named `ada`:

```
ada ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

The installed file is `/etc/sudoers.d/awake`, mode `0440`, root:wheel. A comment above the rule points at the uninstall command. The username is checked against `^[A-Za-z_][A-Za-z0-9._-]{0,31}$` before it is written, and `visudo -cf` must accept the file.

Low Power Mode is **not** in that rule. Adding it would widen the privilege. If the passwordless rule is the selected mode, Awake skips Low Power Mode and logs `lowpower.skip`. Leave the admin-prompt mode on if you want Low Power Mode when the lid closes. That still asks for your password. It does not change the sudoers file.

Remove the rule from Settings, or:

```bash
sudo rm /etc/sudoers.d/awake
```

## Low Power Mode

On lid close during a session, and only in admin-prompt mode, Awake runs `pmset -b lowpowermode 1` if it was off, and restores the previous value when the lid opens or the session ends. The live value is parsed from `pmset -g` (`lowpowermode` / `SleepDisabled`).

## Hotspot

Optional. The name is stored in `config.json`. The password is stored in the login Keychain under the service `com.awake.menubar.hotspot`, account = SSID. It is not written to config or the log.

When the default network path becomes unsatisfied during a session, Awake tries once to join that SSID with CoreWLAN. A failure retries after 30 seconds. A missing Keychain item is not retried until the network returns. macOS may ask for Location Services before it allows a Wi-Fi scan. That prompt is local. Awake does not transmit location.

No other network calls are made.

## Battery and heat

- Battery floor defaults to 18% (allowed range 5–50). At or below the floor the session ends and sleep is restored. A Mac with no internal battery skips this check. Being on AC power does not bypass the floor.
- `ProcessInfo.thermalState` of serious or critical ends the session. Fair and nominal do not.
- If the timer and the battery floor trip on the same check, the timer reason wins.
- An auto-end posts a notification (“Timer finished”, “Battery at N%”, or thermal) and the menu-bar title drops back to idle. You must allow notifications the first time.

## If the process is killed

`SIGTERM`, `SIGINT`, and `SIGHUP` restore state before exit. Quitting the app does too.

`SIGKILL` cannot run cleanup. `disablesleep` would stay on, and `SIGSTOP`’d apps would stay paused. Assertions die with the process, so those are safe. Awake writes `~/Library/Application Support/Awake/session-state.json` (mode `0600`) while a session is active. The next launch of the app or `awake` / `asleep` takes an exclusive `flock` on `controller.lock`. If the recorded pid is dead, it thaws apps and restores `pmset` before it does anything else. That is a one-shot repair on the next launch, not a background agent.

There is a gap between the kill and the next launch. Don’t `kill -9` a live session if you can quit it instead.

If restoring `disablesleep` fails, the session stays `restorePending`, paused apps are still thawed, and the state file is kept. The next launch tries again.

## Files

| Path | Mode | Contents |
| --- | --- | --- |
| `~/Library/Application Support/Awake/config.json` | 0600 | Floor, bundle IDs, privilege mode, hotspot name. No password. |
| `~/Library/Application Support/Awake/session-state.json` | 0600 | Only while a session or a failed restore is in progress. |
| `~/Library/Application Support/Awake/awake.log` | 0600 | Local events. `password=` is redacted if it ever appears. |
| `~/Library/Application Support/Awake/control.sock` | 0600 | One JSON line in, one JSON line out. The CLI uses this. |
| Login Keychain `com.awake.menubar.hotspot` | — | Hotspot password, if you set one. |

Only one process holds `controller.lock`. The menu-bar app is the controller when it is open. The CLI sends it commands. If the app is not running, `awake start` becomes the controller and blocks until the session ends.

```bash
awake start --hours 2 --minutes 30
awake start --until-stop
awake extend --minutes 45
awake status
awake stop
asleep
```

## Uninstall

Quit Awake first.

```bash
./Scripts/uninstall.sh
rm -rf /Applications/Awake.app
rm -f /usr/local/bin/awake /usr/local/bin/asleep
```

The script deletes Application Support, repeats `security delete-generic-password` for the hotspot service, and `sudo rm`s `/etc/sudoers.d/awake` if it exists. Settings → Delete Local Data does the user-level half and tells you to remove the app.

## Tests

`swift test` covers timer expiry, indefinite sessions, extend, restore of a pre-existing `disablesleep 1`, rollback when `pmset` fails, restore-pending retry, battery floor, no-battery machines, thermal pressure, timer-over-battery priority, refusal without a privilege path, Low Power Mode only on the prompt path, automatic and manual freeze selection, lid-close pause plus display, keyboard, and mute restore, the exact sudoers line, `pmset` parsing, log redaction, kill-style reconcile, and hotspot logging without the secret.

The session rules live in `Sources/AwakeCore` and do not import AppKit. `Sources/AwakeMac` is the only place that talks to `pmset`, IOKit, CoreWLAN, and the Keychain.

## Not included

Agent process isolation beyond pausing apps. Discovering a hotspot password. Accounts, telemetry, or a helper that runs when you are not using Awake.
