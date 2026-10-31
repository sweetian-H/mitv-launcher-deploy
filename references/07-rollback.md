# 07 — Rollback And Recovery

Keep this file open while changing the home activity. On a TV, a wrong move costs a physical
recovery session with the remote, and ADB is off after every reboot.

## Before touching anything

```bash
# 1. record current home
adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME

# 2. back up the launcher you are replacing (if it is third-party)
adb shell pm path com.ts.launcher
adb pull <path-from-previous-command> ./backup/

# 3. confirm you can reach Settings from the remote
#    设置 -> 应用 -> 默认应用 -> 主屏幕
```

Write these three facts down in the delivery message: the original home package, the current free
space on `/data`, and the key sequence to reach the default-apps screen. If the session dies
midway, that note is the only way back.

## Restore the stock launcher

```bash
# preferred path: clear the intruder, then restore the original home
adb shell pm clear com.ts.launcher
adb shell cmd package set-home-activity com.mitv.tvhome
adb shell am start -a android.intent.action.MAIN -c android.intent.category.HOME
```

If `set-home-activity` is accepted but the vendor reverts it, force the chooser and pick PatchWall
explicitly — the same Resolver mechanism that made the takeover work:

```bash
adb shell input keyevent KEYCODE_HOME
# select com.mitv.tvhome, then "Always"
```

Note the asymmetry: this works for restoring stock because `com.mitv.tvhome` is itself the
whitelisted entry, so the vendor check passes.

## Uninstall the custom launcher

```bash
adb uninstall com.ts.launcher
```

Third-party package, so `uninstall` is permitted (`pm disable-user` is not — see
`references/01-recon.md`). If the launcher is currently the preferred home, **restore the home
activity first**, otherwise the next HOME press finds no candidate and shows an empty screen.

## Recover a device stuck on the Resolver

Symptom: the chooser appears on every boot, input is accepted but nothing is remembered, or the
screen shows only the chooser with no way past it.

With ADB available:

```bash
adb shell pm clear com.ts.launcher
adb shell cmd package set-home-activity com.mitv.tvhome
adb reboot
```

Without ADB (the common case after a reboot):

1. 设置 → 应用 → 全部应用 → find the custom launcher → 卸载 / 清除数据.
2. 设置 → 应用 → 默认应用 → 主屏幕 → select PatchWall.
3. Power-cycle.

If Settings is unreachable because the launcher covers the surface: use the remote's
`设置` (gear) key — it is a system-level key event delivered to the vendor settings app, not to the
home surface, so it still works when a third-party launcher owns HOME.

## Verify the restore

```bash
adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME
adb reboot
# after boot
adb shell dumpsys activity activities | findstr mResumedActivity
```

`mResumedActivity` must name `com.mitv.tvhome`.

## What is *not* recoverable

Be explicit with the user about these before starting:

| Action | Recovery |
|---|---|
| `pm uninstall` of a **system** app | none without a firmware reflash |
| Modifying `/system` | none without a firmware reflash |
| Factory reset | data loss, no undo |
| Losing the ADB-on setting | re-enable in 设置 → 关于 → 开发者选项 each boot |

The procedure in this skill never needs any of the first three. If a step seems to require them,
the step is wrong — stop and re-read `references/01-recon.md`.
