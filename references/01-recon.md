# 01 — Recon: What To Measure Before Touching The Device

Every failed deployment in the field failed here: assumptions copied from a guide written for a
different board, or a `pm` command silently refused. Measure first. It takes two minutes.

## Connect

```bash
adb connect 192.168.2.28:5555      # wireless debugging must be enabled on the TV, once
adb devices                        # expect "<ip>:5555   device"
```

MIUI-TV drops the ADB daemon on reboot and sometimes on standby. Every command in this skill
reconnects first — do not assume a persistent session.

## The seven facts that decide the plan

| # | Fact | Command | Why it matters |
|---|---|---|---|
| 1 | Build type | `adb shell getprop ro.build.type` | `user` ⇒ no `pm disable/enable/hide`, no `su`. Whole plan changes. |
| 2 | API level | `adb shell getprop ro.build.version.sdk` | `23` ⇒ desugaring + `Compat` layer mandatory |
| 3 | Root | `adb shell which su; adb shell ls /system/xbin/su /system/bin/su` | Empty output ⇒ ignore every guide that says `su -c` |
| 4 | Platform | `adb shell getprop \| findstr /i "amlogic mediatek mtk droidlogic"` | Decides which input-intent constants exist |
| 5 | HOME owner | `adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME` | Current default launcher package |
| 6 | TV inputs | `adb shell dumpsys tv_input` | Which `TvInputInfo` ids really exist (and which are missing) |
| 7 | Headroom | `adb shell df /data` | A launcher swap needs ~50 MB free |

`scripts/inspect-device.ps1` runs all seven and prints a single block.

## Interpreting fact 4 — platform identification

Do not trust the model name. Xiaomi shipped both Amlogic and MediaTek boards under similar model
numbers, and public guides overwhelmingly assume MediaTek.

```bash
adb shell dumpsys | findstr /i "amlogic"          # expect android.amlogic.ITvService
adb shell pm list packages | findstr /i "droidlogic\|mediatek\|wwtv"
```

- `com.droidlogic.tvinput` present ⇒ **Amlogic**. Use `android.amlogic.ITvService`.
- `com.mediatek.wwtv.tvcenter` present ⇒ **MediaTek**. Different constants entirely.
- Neither present ⇒ the vendor TV app is fully private; only `dumpsys tv_input` ids are usable.

A `hidden_apps` entry naming `com.mediatek.wwtv.tvcenter` on an Amlogic board does nothing —
it is dead configuration. Remove it rather than leaving a misleading line.

## Interpreting fact 1 — the permission matrix

Measured on a Mi TV 4A, Android 6, `ro.build.type=user`, shell `uid=2000`:

| Command | Result | Usable for cleanup? |
|---|---|---|
| `pm disable-user --user 0 <pkg>` | `SecurityException: Shell does not have permission` | No |
| `pm enable <pkg>` | same | No |
| `pm hide <pkg>` | same (requires `MANAGE_USERS`) | No |
| `pm uninstall --user 0 <pkg>` | works **only** for third-party packages | Yes, third-party only |
| `pm clear <pkg>` | works | Yes, clears data |
| `am force-stop <pkg>` | works | Yes, temporary |
| `appops set <pkg> <op> ignore` | works | Partial (per-op) |
| `settings put <ns> <key> <val>` | works for most keys | Yes, but no effect on disabled state |

So "disable a system app" is not available. Reaching the same outcome requires either
`am force-stop` + removing its launcher entry, or replacement of the surface itself (this skill's
approach).

## Facts 5 and 6 — the two that surprise people

`dumpsys tv_input` lists only the tuners declared in the platform's `tv_input` HAL config. On the
Amlogic board used here it registered just `HW0` and `HW10`, while the HDMI 3 port was served by
`Hdmi3InputService` on `HW7`. Consequence: `TvInputManager`-based switching works for HDMI 1/2 but
silently does nothing for HDMI 3. Do not conclude "HDMI 3 is broken" — map it to the vendor
intent instead (`references/04-input-sources.md`).

`cmd package resolve-activity` reports only the currently preferred home. To see every candidate:

```bash
adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME
```

## Third-party inventory

```bash
adb shell pm list packages -3
adb shell dumpsys package <pkg> | findstr /i "versionName firstInstallTime lastUpdateTime"
```

Record the list before removing anything. On MIUI-TV the apps that break the experience are usually
pre-installed streaming clients (`com.ktcp.video` 云视听极光, `com.sohu.tv` 云视听悦厅, etc.);
removing them frees the top row of PatchWall and several hundred MB. Removal of a *third-party*
package is reversible only by reinstalling the APK — capture the APK first if the user may want it
back:

```bash
adb shell pm path <pkg>          # -> /data/app/.../base.apk
adb pull /data/app/.../base.apk  ./backup/<pkg>.apk
```

## Storage baseline

```bash
adb shell df /data
adb shell du -s /data/data/* 2>nul   # unavailable without root; use Settings > Storage instead
```

Log the before/after numbers. Users judge a launcher swap by free space and boot time, so both
need a measured baseline.
