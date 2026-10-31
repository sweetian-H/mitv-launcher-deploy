# 03 — Taking Over The HOME Key Without Root

## The mechanism

MIUI-TV does not verify the signature of a candidate launcher. Its home-selection code calls the
framework setting `MitvSettings.isThirdpartyHomeAllowed(packageName)`, which performs a **plain
string comparison against a hardcoded whitelist** in the system settings provider. Any APK whose
application id matches a whitelisted name is treated as a legitimate home surface.

Consequence: the launcher's manifest `package` attribute must be rewritten at build time. The
application id is a build parameter, so no source fork is needed:

```bash
./gradlew :app:assembleRelease -PlauncherApplicationId=com.ts.launcher
```

In `app/build.gradle`:

```gradle
def launcherId = project.findProperty('launcherApplicationId') ?: 'com.example.launcher'
android {
    defaultConfig { applicationId launcherId }
}
```

The whitelisted name differs per firmware generation. Known values observed in the field include
`com.ts.launcher`. Treat it as a probe target, not a constant:

1. Build with a candidate id, install, press HOME.
2. If a chooser appears listing the new launcher → the id is whitelisted.
3. If HOME jumps straight back to PatchWall with no chooser → the id is rejected; try the next
   candidate.

Batch the probe instead of iterating one-by-one: install several builds with different ids, then
read what the system actually enumerated:

```bash
adb shell cmd package query-activities --brief -a android.intent.action.MAIN -c android.intent.category.HOME
adb logcat -d | findstr /i "thirdpartyhome launcher home"
```

## Why `set-home-activity` is not enough

```bash
adb shell cmd package set-home-activity com.ts.launcher
```

This writes the same Preferred Activities entry, but MIUI-TV re-validates it against the whitelist
on the next resolution pass and reverts. The chooser route works because the user's explicit
"Always" choice is persisted with a higher-priority flag that the framework honours before the
vendor check.

So: **the chooser is the mechanism, not a side effect.**

## Procedure

```bash
# 1. build with the whitelisted id
./gradlew :app:assembleRelease -PlauncherApplicationId=com.ts.launcher

# 2. install (see scripts/install-apk.ps1 — the confirmation dialog needs key events)
adb install -r app/build/outputs/apk/release/app-release.apk

# 3. trigger resolution
adb shell input keyevent KEYCODE_HOME
```

A system dialog appears: *"Use … as HOME?"* with the new launcher and PatchWall.

Navigation without a remote:

```bash
adb shell input keyevent KEYCODE_DPAD_DOWN     # move focus to the desired entry
adb shell input keyevent KEYCODE_DPAD_CENTER   # select
```

Critical: on this dialog the *"Always / 始终"* control may be a checkbox that is **already
checked**. Sending a blind `CENTER` lands on the checkbox and silently toggles it off, after which
the choice is "Just once" and the takeover does not persist. Move down past the checkbox before
confirming:

```bash
adb shell input keyevent 20   # DOWN  (past the Always checkbox)
adb shell input keyevent 23   # CENTER / OK
```

## Verify persistence

Persistence is the only meaningful test. A launcher that works until reboot has not taken over.

```bash
adb shell dumpsys activity activities | findstr mResumedActivity
adb reboot
# after boot, without touching the remote:
adb shell dumpsys activity activities | findstr mResumedActivity
```

`mResumedActivity` must name the custom launcher after the reboot.

Also confirm the entry survives package-manager preference cleanup:

```bash
adb shell dumpsys package preferred-activities | findstr -i "home"
```

## Do not disable PatchWall

`com.mitv.tvhome` (PatchWall) owns system-settings entry points, casting (米联/Miracast), and the
voice assistant surface. Disabling it — where that were even permitted — breaks settings access and
screen mirroring. Leave it installed. The custom launcher wins HOME resolution; PatchWall stays
reachable and remains the fallback if the custom build misbehaves.

If the user explicitly wants a *reduced* PatchWall, restrict changes to
`settings put` keys (boot ads, auto-update) rather than package state.

## Recovery from a Resolver loop

Symptom: after reboot the chooser appears every time and no choice sticks.

```bash
adb shell pm clear com.ts.launcher                              # drop the launcher's prefs
adb shell cmd package set-home-activity com.mitv.tvhome         # restore stock
adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME
```

If ADB is unavailable, the on-device path is: 设置 → 应用 → 默认应用 → 主屏幕 → 选择 PatchWall.
Because ADB resets to off after reboot on this firmware, keep a remote-based recovery route in mind
*before* changing the home activity.
