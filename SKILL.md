---
name: mitv-launcher-deploy
description: >-
  Deploy and customize a third-party Android TV launcher (CleanYourTV and similar) on Xiaomi
  Mi TV / Mi Box, including vendor permission lockdown bypass, Android 6 (API 23) compatibility
  shims, taking over the HOME key through Xiaomi's launcher whitelist, mapping vendor HDMI/AV
  input intents, Apple-style desktop layout, and safe rollback. Use when the user asks to replace
  PatchWall, deploy CleanYourTV on a Mi TV, make a custom TV launcher the default home screen,
  fix an APK that crashes on an old TV, add input-source shortcuts, or show an input-switch prompt.
  Triggers: 小米电视, 小米盒子, 电视桌面, 第三方桌面, 默认桌面, HOME 键, CleanYourTV, PatchWall,
  信源切换, HDMI 切换, Android TV launcher, TVBox launcher, API 23 兼容.
agent_created: true
---

# Mi TV Third-Party Launcher Deployment

## Purpose

Replace a Xiaomi TV's stock PatchWall surface with a self-hosted Android TV launcher, without
root, without unlocking the bootloader, and without bricking the device. The procedure covers the
four hard problems that block every attempt on MIUI-TV firmware:

1. **Permission lockdown** — `pm disable-user` / `pm enable` / `pm hide` are refused for `uid=2000`
   (shell) on `ro.build.type=user` builds. A working alternative set must be used instead.
2. **Old runtime** — Android 6 / API 23 crashes modern Java 8+ code paths at class-load or
   first-call time (`NoClassDefFoundError`, `NoSuchMethodError`).
3. **HOME key ownership** — Xiaomi validates the default launcher against a hardcoded package
   whitelist, not a signature, so the package id must be rewritten at build time.
4. **Vendor-private input switching** — HDMI/AV/DTMB do not go through the standard
   `TvInputManager` path on Amlogic-based Mi TVs; the vendor activity must be targeted directly.

Treat the vendor UI (PatchWall) as *preserved by default*. Never disable, uninstall, or hide
`com.mitv.tvhome` unless the user explicitly asks for it — it owns system settings, casting, and
voice assistant entry points.

## When to use

Use when the user wants to run a custom launcher on a Xiaomi TV / Mi Box, or is debugging a
launcher that installs but does not take over HOME, does not appear in the app list, crashes on
launch, or cannot switch to an HDMI source.

Do **not** use for: phones, tablets, Google TV (Chromecast), Sony/LG/Hisense TVs — the whitelist
and vendor intent constants below are Xiaomi-specific. For those, only the API-compat and
build-config sections apply.

## Non-negotiable rules

- **Never factory-reset, never `pm uninstall` a system package, never touch `/system`.**
  A wrong package removal on MIUI-TV leaves the device unable to boot into settings.
- **Never assume `su` exists.** Probe first. If the build is `user`, no escalation path exists and
  every `pm` state-change command will fail with `SecurityException`.
- **Never push a config file into `/sdcard/Android/data/<pkg>/`.** adbd's UID does not own that
  path, so the write fails with `EACCES` even after the app creates the directory. Compile defaults
  into `res/values/config.xml` instead (see `references/05-desktop-ux.md`).
- **Never rewrite `order.txt` while the launcher is in reorder mode** — the in-memory list wins and
  overwrites the file on save.
- **Always confirm before changing the default HOME.** A wrong package id in the whitelist slot
  causes a boot loop of the Resolver dialog with no way to dismiss it.

## Workflow

### Step 1 — Recon before touching anything

Run `scripts/inspect-device.ps1 -TvIp <ip>`. It collects: build fingerprint, `ro.build.type`,
available `su`, platform vendor (Amlogic vs MediaTek), installed third-party packages, current HOME
resolution, all `TvInputInfo` ids, and storage headroom.

Read the output before proceeding. The two facts that decide the whole plan:

- `ro.build.type` — `user` means no `pm` state changes; go straight to the whitelist route.
- Platform vendor — decides which input-intent constants are valid
  (`android.amlogic.ITvService` vs `com.mediatek.wwtv.tvcenter`). Many published guides assume
  MediaTek on Xiaomi hardware; verify instead of copying.

See `references/01-recon.md` for the command matrix and how to interpret each result.

### Step 2 — Adapt the source for API 23

Apply these build settings before the first `assembleRelease`:

```gradle
android {
    defaultConfig { minSdk 23 }
    buildTypes {
        release {
            minifyEnabled false      // R8 strips $$ExternalSyntheticLambda, causing NoClassDefFoundError
            shrinkResources false
        }
    }
    compileOptions {
        coreLibraryDesugaringEnabled true   // java.util.function etc. require API 24
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
}
dependencies { coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.5' }
```

Then run `./gradlew :app:lintRelease` and read `build/reports/lint-results-release.html`. Every
`NewApi` finding is a first-call crash on the device. Downgrade each one through a single
`Compat` helper class rather than scattering `if (Build.VERSION.SDK_INT >= ...)` checks.

Full list of the 21 API gates hit in practice, plus the helper implementation:
`references/02-api23-compat.md`.

### Step 3 — Take over the HOME key

Build with the whitelisted package id and install over the top:

```bash
./gradlew :app:assembleRelease -PlauncherApplicationId=com.ts.launcher
adb install -r app/build/outputs/apk/release/app-release.apk
adb shell input keyevent KEYCODE_HOME
```

A Resolver appears. Select the new launcher and confirm **Always**. This writes Preferred
Activities, which survives reboot — unlike a plain `cmd package set-home-activity`, which MIUI-TV
re-validates and rejects.

Mechanism, whitelist inspection, and rollback: `references/03-home-takeover.md`.

### Step 4 — Wire up input sources

`TvInputManager` exposes only the tuners declared in `tv_input`, typically `HW0` and `HW10` on
Amlogic boards; HDMI 3 lives on `HW7` and is unreachable through the standard channel. Send the
vendor intent instead:

```
action  com.xiaomi.mitv.tvplayer.EXTSRC_PLAY
extra   input = 23 (HDMI1) | 24 (HDMI2) | 25 (HDMI3) | 2 (AV)
```

DTMB / live TV uses `com.xiaomi.mitv.tvplayer.DTMB_PLAY`. This activity has **no** `LAUNCHER`
entry point, so it must be started by explicit intent — verify with
`adb shell cmd package resolve-activity --brief -a <action>`.

Constants, the `TvInputInfo` → vendor-number mapping, and the input-switch prompt logic (which
fires only on a real `CONNECTED` transition, debounced, and suppressed at boot):
`references/04-input-sources.md`.

### Step 5 — Layout and identity

Compile the visual configuration into `res/values/config.xml` (never a runtime file). The set that
produces a clean Apple-TV-like surface:

```xml
<bool name="dock_row">false</bool>          <!-- single uniform grid, no separate dock -->
<bool name="uniform_tiles">true</bool>      <!-- identical card geometry on every row -->
<bool name="always_show_names">true</bool>  <!-- labels always visible -->
<bool name="dock_title">false</bool>
<bool name="reorder_button">true</bool>
<bool name="app_library">true</bool>
<bool name="tile_menu">true</bool>
<bool name="show_library_pill">false</bool> <!-- remove the floating bottom pill -->
```

Synthetic tiles (input shortcuts) need an explicit icon; generate one from the tile's semantic
class instead of shipping an empty label — see the drawable recipe in `references/05-desktop-ux.md`.

Regenerate the whole block from JSON with `scripts/gen-config-xml.ps1`.

### Step 6 — Verify, then close the attack surface

Verification checklist — every line must pass on the device, not in the build log:

- `adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME`
- `adb shell dumpsys activity activities | findstr mResumedActivity` after pressing HOME
- Reboot, press HOME, confirm the custom launcher still wins
- Open each input shortcut and confirm the vendor activity is resumed
- Unplug/replug an HDMI source and confirm the prompt appears exactly once

Then reduce exposure, with user consent: disable boot ads, disable auto-update, and turn ADB off.
ADB resets to off after every reboot on MIUI-TV — expect to re-enable it each session.

## Scripts

| Script | Purpose |
|---|---|
| `scripts/inspect-device.ps1` | One-shot recon: build type, root, platform, packages, HOME, inputs, storage |
| `scripts/adb-shell.ps1` | `adb` wrapper: reconnects every call, forces UTF-8, returns clean output |
| `scripts/build-launcher.ps1` | Gradle build with mirror config and whitelisted applicationId |
| `scripts/install-apk.ps1` | Install and auto-drive the MIUI confirmation dialog via key events |
| `scripts/gen-config-xml.ps1` | Render `res/values/config.xml` from a JSON spec |

All scripts are ASCII-only by design (PowerShell 5.1 misparses BOM-less non-ASCII `.ps1` files as
ANSI and fails on multi-byte characters). Keep any new script ASCII too.

## References

| File | Read it when |
|---|---|
| `references/01-recon.md` | Before anything else; deciding whether `pm` is usable |
| `references/02-api23-compat.md` | The APK installs but crashes at launch on API 23 |
| `references/03-home-takeover.md` | HOME does not stick, or a Resolver loop appears |
| `references/04-input-sources.md` | HDMI/AV/DTMB cannot be switched, or the prompt misbehaves |
| `references/05-desktop-ux.md` | Layout, icons, ordering, app-library configuration |
| `references/06-troubleshooting.md` | Any error message — lookup table of symptom → cause → fix |
| `references/07-rollback.md` | Restoring the stock launcher, or recovering a device stuck on Resolver |

## Delivery

Report to the user: what was changed on the device, what was compiled into the APK, which steps
still need physical verification (cable plug/unplug, standby wake), and the exact rollback command.
Do not claim success for anything only observed in a build log.
