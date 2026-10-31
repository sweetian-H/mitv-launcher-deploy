# 05 — Desktop Layout, Ordering, And Icons

## Configuration must be compiled in

The launcher reads a `config.json` from `/sdcard/Android/data/<pkg>/files/` at runtime. **Do not
try to populate it with `adb push`.** adbd's UID does not own the app's external directory; the write
fails with `EACCES` even when the app created the directory itself and even with `run-as`.

Two workable options:

1. **Compile defaults** into `res/values/config.xml`, then `adb install -r`. Every release ships
   desired state; no on-device edit is possible, which is acceptable for a fixed living-room
   build.
2. Push through the app itself (an in-app settings screen writing the JSON). Only worth building if
   the user needs runtime edits.

Option 1 is what this skill uses. `scripts/gen-config-xml.ps1` renders the XML from a JSON spec so
the values stay reviewable in version control.

## Layout: Apple-TV-like surface

The problem this fixes: a dock row with different tile geometry than the rows below it reads as two
mismatched grids. Apple TV uses one uniform grid — identical card size, radius, and label position
on every row, no separate dock, no floating pill.

```xml
<bool name="dock_row">false</bool>           <!-- one grid: kills the mismatched top row -->
<bool name="uniform_tiles">true</bool>       <!-- identical card geometry everywhere -->
<bool name="always_show_names">true</bool>   <!-- label under every tile, not on hover -->
<bool name="dock_title">false</bool>         <!-- no section heading -->
<bool name="show_library_pill">false</bool>  <!-- remove the floating bottom capsule -->
<bool name="app_library">true</bool>         <!-- keep the library surface, just not the pill -->
<bool name="app_library_selection">true</bool>
<bool name="library_button">true</bool>
<bool name="reorder_button">true</bool>      <!-- exposes ordering in the library -->
<bool name="tile_menu">true</bool>           <!-- long-press menu per tile -->
```

Result on a 1920×1080 panel: a 4×2 grid of equal rounded cards, labels always visible, consistent
margins. `uniform_tiles` is the single most important flag — without it the first row keeps its
dock metrics and the layout never looks coherent.

## Synthetic tiles (input shortcuts)

Shortcut tiles are not installed apps, so they do not exist in `order.txt`. Represent them as
config entries and inject them into the leading position at reload:

```xml
<string-array name="shortcut_tiles">
    <!-- format: <label>=<payload> -->
    <item>ITV=input:25</item>
    <item>Settings=action:android.settings.SETTINGS</item>
</string-array>
```

Payload forms:

| Form | Behaviour |
|---|---|
| `input:<n>` | start the vendor `EXTSRC_PLAY` intent with `input = n` |
| `action:<action>` | broadcast/start that action on the TV player package |
| `act:<pkg>/<cls>` | start that component outright (`ComponentName.unflattenFromString` format) |
| `app:<package>` | launch an installed package explicitly |

`act:` exists because Xiaomi's media surfaces — the file manager
(`com.xiaomi.mitv.mediaexplorer`), the video player (`com.mitv.videoplayer`), and the gallery
(`com.xiaomi.tv.gallery`) — ship with **no `LAUNCHER` category at all**. Neither the grid nor any
app library built from `queryIntentActivities(MAIN/LAUNCHER)` can ever list them, which is exactly
why users report "the file manager and player are gone" after switching launchers: nothing was
removed, the apps are just unreachable without PatchWall. Verify an entry with
`am start -n <pkg>/<cls>` and check `mResumedActivity`; a tile then fires the same explicit start.

Every verified Mi TV media entry point (exported under the pre-31 rule because they carry intent
filters, despite lacking the category):

| Surface | Package | Entry activity |
|---|---|---|
| File manager | `com.xiaomi.mitv.mediaexplorer` | `.xq.XQMainEntryActivity` |
| Video player | `com.mitv.videoplayer` | `.VideoPlayerActivity` (MIME `video/*` handler; direct start opens its local-video list) |
| Gallery | `com.xiaomi.tv.gallery` | `.view.GalleryMainActivity` |
| TV manager | `com.xiaomi.mitv.tvmanager` | `.MainTvManagerActivity` |

Artwork rule: give each semantic class its own plate colour — blue `#1F6FEB` TV for inputs, amber
`#D29922` folder for the file manager, green `#2EA043` play for the player — so three generated
tiles do not all read as the same app. Pick the drawable in the adapter from the form prefix, not
the label, so a renamed tile keeps its icon.

Injection rule: on reload, any configured shortcut that is not present in the saved order is
appended to a `leading` list, and the final list is `leading + saved`. Saved order wins for tiles
the user has positioned; shortcuts stay on top rather than sinking to the end of the grid (the
default failure: an unsaved tile sorted last and appeared on the final row).

## Icon generation for tiles without a launcher icon

An input source has no icon resource, so the tile renders as text-only — unreadable at sofa distance.
Generate one from the tile's semantic class:

```xml
<!-- res/drawable/ic_shortcut_tv.xml -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#1F6FEB"
          android:pathData="M0,0h108v108h-108z"/>
    <path android:fillColor="#FFFFFF"
          android:pathData="M30,32h48a6,6 0,0 1,6 6v25a6,6 0,0 1,-6 6h-48a6,6 0,0 1,-6 -6v-25a6,6 0,0 1,6 -6z"/>
    <path android:fillColor="#FFFFFF"
          android:pathData="M46,46l16,9l-16,9z"/>
</vector>
```

Rules that make generated icons look native:

- **Full-bleed colour block, no rounded corners** — the tile already applies a corner radius; a
  rounded icon inside a rounded card produces a visible double edge.
- **One accent colour per semantic class** — blue `#1F6FEB` for video/input, grey for settings,
  green for network. Do not tint per-instance.
- **White glyph only.** Adapting to dark mode is unnecessary on a TV surface.
- **Viewport 108×108** with content inset ≈ 6 dp, matching adaptive-icon density buckets.
- Use a vector drawable, not a PNG — one asset covers all densities and adds ~1 KB.

## Ordering

`order.txt` holds the user's sequence. Two constraints:

- **Do not write the file while the launcher is in reorder mode.** The in-memory list is the source
  of truth and overwrites the file on save.
- Shortcuts must be injected at load (see above), not persisted into `order.txt`, or they will
  duplicate after a config change.

The reorder entry point lives in the app library. On a remote, reaching the ⇄ button reliably
requires a precise `dumpsys` position check rather than a fixed key-event count:

```bash
adb shell dumpsys activity activities | findstr mResumedActivity
adb shell input keyevent 20    # DOWN, verify focus moved with a screenshot
adb shell input keyevent 23    # OK
```

## App library

`app_library` enables a second surface listing every installed app, so the main grid stays curated.
Keep both: the main grid holds 6–10 tiles the household actually uses; the library holds everything
else. This is what makes "the menu is incomplete" complaints go away — the grid is intentionally
short, and everything is one press deeper.
