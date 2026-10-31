# 06 — Troubleshooting: Symptom → Cause → Fix

Ordered by how often each one wastes an afternoon.

## Build and install

| Symptom | Cause | Fix |
|---|---|---|
| `INSTALL_FAILED_OLDER_SDK` | `minSdk` above device API | set `minSdk 23`; keep it, do not `--bypass-low-target-sdk-block` |
| Gradle wrapper download at 20–50 KB/s | dl.google.com throttled | use a mirror in `gradle/wrapper/gradle-wrapper.properties`: `distributionUrl=https\://mirrors.cloud.tencent.com/gradle/gradle-8.9-bin.zip` |
| `Could not find com.android.tools.build:gradle` | no `google()` repo / proxy | add `google()` + `mavenCentral()` in `settings.gradle` `dependencyResolutionManagement` |
| `Sdk location not found` | missing `local.properties` | `sdk.dir=D:/Android/sdk` (forward slashes, escaped in properties) |
| `Failed to install ... INSTALL_FAILED_UPDATE_INCOMPATIBLE` | signature or package id changed | `adb uninstall <pkg>` first, then install |
| APK size identical before/after enabling desugaring | desugaring not applied | check `coreLibraryDesugaringEnabled true` is inside `compileOptions`, and the dependency is `coreLibraryDesugaring` not `implementation` |

## Install stalls on the TV

The MIUI installer shows a full-screen confirmation with an **"Apply to all"** checkbox that is
often pre-checked and focused. A blind `CENTER` toggles it off and cancels the install.

```bash
adb shell input keyevent 20    # DOWN off the checkbox
adb shell input keyevent 23    # OK on Install
```

`scripts/install-apk.ps1` does this and verifies with `pm path <pkg>` afterwards.

## Launch-time crashes

| Exception | Cause | Fix |
|---|---|---|
| `NoClassDefFoundError: ...$$ExternalSyntheticLambda` | `java.util.function` is API 24 / R8 stripped the class | enable desugaring **and** `minifyEnabled false` |
| `NoSuchMethodError: forceHasOverlappingRendering` | API gate above device level | route through `Compat` (`references/02-api23-compat.md`) |
| `NoSuchMethodError: getLocales` / `getFont` | API 24 / 26 | `Compat.locale()` / `Compat.font()` |
| `SecurityException: uid 2000 not permitted` | shell permission, not app permission | see permission matrix in `references/01-recon.md` |
| `AndroidRuntimeException: Calling startActivity from outside of an Activity` | missing flag | add `FLAG_ACTIVITY_NEW_TASK` |
| Blank surface, no crash log | exception swallowed by a broad `catch (Throwable)` | remove the catch-all; read `adb logcat -s AndroidRuntime` |

## HOME key

| Symptom | Cause | Fix |
|---|---|---|
| Chooser never appears, PatchWall returns instantly | package id not in vendor whitelist | rebuild with `-PlauncherApplicationId=<whitelisted>` and retry |
| Choice does not survive reboot | "Always" checkbox was toggled off by a blind OK | redo with `DOWN` before `CENTER` |
| Chooser loops every boot | bad preferred-activity entry | `pm clear <pkg>` → `cmd package set-home-activity com.mitv.tvhome` |
| `cmd package set-home-activity` returns success but reverts | vendor re-validation | use the chooser route instead |

## Input switching

| Symptom | Cause | Fix |
|---|---|---|
| HDMI 3 does nothing, HDMI 1/2 work | not registered in `tv_input` (only `HW0`/`HW10`) | map to vendor intent `input=25` |
| No activity found for the intent | wrong action or package | `cmd package resolve-activity --brief -a <action>`; try `com.xiaomi.tvplayer` |
| Black screen after switching | source is unplugged | expected; confirm `mResumedActivity` is the vendor activity |
| Prompt never appears | `TvInputManager` callback not delivered for vendor-owned inputs | add 3 s polling fallback |
| Prompt fires repeatedly | missing debounce/cooldown | 2 s delay, 120 s cooldown, dedupe via `Set.add()` |
| Prompt appears at boot | callback fires CONNECTED for all inputs on registration | seed the known set from current state *before* registering |

## Configuration

| Symptom | Cause | Fix |
|---|---|---|
| `config.json` push fails `EACCES` | adbd does not own `/sdcard/Android/data/<pkg>` | compile defaults into `res/values/config.xml` |
| Config changes have no effect after reinstall | app still reading a stale cached JSON | `adb shell pm clear <pkg>` then relaunch |
| Shortcut tile sorted to the last row | not in `order.txt`, appended at the end | inject into a `leading` list: `leading + saved` |
| Layout still looks like two grids | `dock_row`/`uniform_tiles` default not applied | verify the values in the built APK's `resources.arsc` via `aapt dump resources` |

## Connectivity and automation (Windows host)

| Symptom | Cause | Fix |
|---|---|---|
| Every other `adb` call: `device offline` | adb server reaped between shells | `adb connect <ip>:5555` at the start of **every** invocation |
| `adb` not found from a script | PATH differs from interactive shell | resolve the absolute path to `adb.exe` once, reuse it |
| Chinese output garbled | console code page | `[Console]::OutputEncoding = [System.Text.Encoding]::UTF8` |
| `.ps1` fails to parse with `字符串缺少终止符` | BOM-less non-ASCII script parsed as ANSI | keep scripts **ASCII-only** |
| `chcp`/`cmd /c` refuses to launch | host policy | call the `.bat`/exe directly with `& 'D:\path\x.bat'` |
