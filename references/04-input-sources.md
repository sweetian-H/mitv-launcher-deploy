# 04 — Input Sources: HDMI / AV / DTMB

## Why the standard API is not enough

`TvInputManager` can only switch to inputs the platform's `tv_input` HAL declared. On the Amlogic
board used here, `dumpsys tv_input` registered exactly two tuners:

| Tuner id | Service |
|---|---|
| `HW0` | `Hdmi1InputService` |
| `HW10` | `Hdmi2InputService` |

The HDMI 3 port existed only as `Hdmi3InputService` on `HW7` and was **not** registered, so
`TvInputManager`-based selection silently no-ops for it. The AV and DTMB paths are likewise outside
the standard surface.

Verify on the target device — never assume these ids:

```bash
adb shell dumpsys tv_input
adb shell dumpsys tv_input | findstr /i "HW "
```

## The vendor entry point

Xiaomi's TV player app has **no** `LAUNCHER` activity. Probe it and expect zero hits:

```bash
adb shell cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.LAUNCHER com.xiaomi.mitv.tvplayer
# -> No activity found
```

Switching therefore requires an explicit intent naming the vendor action:

```java
Intent i = new Intent("com.xiaomi.mitv.tvplayer.EXTSRC_PLAY");
i.setPackage("com.xiaomi.mitv.tvplayer");
i.putExtra("input", sourceNumber);
i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
context.startActivity(i);
```

### Source numbering

| Port | `input` extra |
|---|---|
| HDMI 1 | `23` |
| HDMI 2 | `24` |
| HDMI 3 | `25` |
| AV | `2` |

DTMB / live TV uses a different action and activity:

```java
Intent i = new Intent("com.xiaomi.mitv.tvplayer.DTMB_PLAY");
i.setComponent(new ComponentName("com.xiaomi.mitv.tvplayer",
        "com.xiaomi.mitv.tvplayer.dtmb.DTMBActivity"));
```

Validate each mapping on-device before wiring it into a tile:

```bash
adb shell am start -a com.xiaomi.mitv.tvplayer.EXTSRC_PLAY --ei input 25 -p com.xiaomi.mitv.tvplayer
adb shell dumpsys activity activities | findstr mResumedActivity
```

Expect `ExternalSourceActivity` (or the vendor equivalent) as resumed. A black picture with a
correct resumed activity means the intent worked and the port is simply unplugged — that is normal,
not a bug.

## Mapping tuner ids to vendor numbers

Keep an explicit table; do not derive one from the other. Configure both, because the UI needs the
`TvInputInfo` id for "is it connected" and the vendor number for "switch to it":

```xml
<!-- tuner id = vendor source number ('-' = no vendor port) -->
<string-array name="input_sources">
    <item>HW0=-</item>
    <item>HW10=-</item>
    <item>HW7=25</item>
</string-array>

<!-- menu rows: label = vendor source number -->
<string-array name="input_rows">
    <item>HDMI 1=23</item>
    <item>HDMI 2=24</item>
    <item>HDMI 3=25</item>
    <item>AV=2</item>
</string-array>
```

`input_rows` drives the visible menu, so it can list ports the HAL never registered. Deduplicate
labels when a tuner appears in both tables (HDMI 3 showed up twice in an early build).

## Input-switch prompt

Requirement: when a new source becomes active, offer to switch — once, not repeatedly, and never at
boot.

Implementation contract:

```java
TvInputManager mgr = (TvInputManager) getSystemService(TV_INPUT_SERVICE);
for (TvInputInfo info : mgr.getTvInputList()) mgr.registerCallback(cb, info, handler);
```

```java
@Override public void onInputStateChanged(String inputId, int state) {
    if (state != TvInputManager.INPUT_STATE_CONNECTED) return;
    if (!connectedInputs.add(inputId)) return;   // Set.add returns false => already known
    considerInputPrompt(inputId);
}
```

Four guards, all necessary:

| Guard | Value | Prevents |
|---|---|---|
| Boot snapshot | seed `connectedInputs` from current state before registering | prompt storm at boot (all inputs report CONNECTED) |
| Debounce | 2 s delay before showing | prompting on a 200 ms transient during resolution |
| Cooldown | 120 s per input | repeated prompts from cable jitter |
| Focus check | `hasWindowFocus()` | dialog appearing behind the vendor activity |

```java
private static final long INPUT_PROMPT_DELAY_MS   = 2000;
private static final long INPUT_PROMPT_COOLDOWN_MS = 120000;
```

For firmware that never fires the callback (observed when an STB powers on while the TV stays in the
vendor app), add a polling fallback: every 3 s compare the set of connected input ids against the
snapshot and treat a new id as an arrival. Poll only while the launcher has focus.

### Provider declaration

`TvInputManager` callbacks only deliver for inputs whose provider the app can see. If no callback
ever fires even for an input that is genuinely plugged in, the vendor app owns the provider and the
launcher only receives system-level broadcasts — fall back to polling.

## Pitfalls

- Sending the intent without `FLAG_ACTIVITY_NEW_TASK` from a non-activity context throws
  `AndroidRuntimeException`; the tile silently does nothing.
- Using `input:<n>` as a shortcut payload requires the launcher to parse the numeric suffix and call
  the vendor intent — a raw string in a tile is not a launchable action.
- Hardcoding the vendor package breaks on firmware where the TV player is `com.xiaomi.tvplayer`
  instead of `com.xiaomi.mitv.tvplayer`. Make it a config string (`live_tv_package`).
