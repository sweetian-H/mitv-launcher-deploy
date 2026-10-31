# 02 — Android 6 / API 23 Compatibility

A modern launcher codebase targets `minSdk 26+`. Installing on API 23 produces two distinct
failure classes, and they need different fixes. Diagnose by the exception type, not by the stack
frame's last line.

## Failure class A — `NoClassDefFoundError` at launch

```
java.lang.NoClassDefFoundError: Failed resolution of:
Lcom/example/launcher/MainActivity$$ExternalSyntheticLambda1;
```

Root cause is **not** a missing dependency. Two independent triggers:

1. **`java.util.function` / streams / `Optional`** are API 24. Lambdas desugar to
   `$$ExternalSyntheticLambda` classes whose target interfaces do not exist on API 23.
2. **R8/minify** removes synthetic lambda classes it believes unreachable.

Fix both at once:

```gradle
android {
    compileOptions {
        coreLibraryDesugaringEnabled true
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    buildTypes {
        release {
            minifyEnabled false
            shrinkResources false
            // If minify must stay on, add:
            // proguardFiles getDefaultProguardFile('proguard-android.txt'), 'proguard-rules.pro'
            // and keep: -keep class **$$ExternalSyntheticLambda* { *; }
        }
    }
}
dependencies {
    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.5'
}
```

Disabling minify costs roughly 5–10 % APK size and is the correct trade for a device-side launcher
that cannot be debugged easily. Verify the desugaring actually ran:

```bash
./gradlew :app:assembleRelease
# APK grows by the desugar runtime; a byte-identical size to the pre-fix build means it did not apply
```

## Failure class B — `NoSuchMethodError` / `NoSuchFieldException` on first call

```
java.lang.NoSuchMethodError: No virtual method forceHasOverlappingRendering(Z)V
in class Landroid/view/View;
```

The class exists (so it compiled), the method does not exist on this runtime. Compilation against
the latest SDK cannot catch this — only `lint` can.

### Enumerate every gate

```bash
./gradlew :app:lintRelease
# report: app/build/reports/lint-results-release.html  (search "NewApi")
```

Do not fix them one by one inline. Route every one through a single `Compat` class so the call
sites stay readable and a future `minSdk` bump is a one-file change.

### Helper pattern

```java
public final class Compat {
    private Compat() {}

    /** API 24: UserManager.isUserUnlocked(). Pre-24 devices never have FBE, so true is correct. */
    public static boolean isUserUnlocked(Context c) {
        if (Build.VERSION.SDK_INT >= 24) {
            UserManager um = (UserManager) c.getSystemService(Context.USER_SERVICE);
            return um == null || um.isUserUnlocked();
        }
        return true;
    }

    /** Method absent on some API 23 vendor builds; a no-op is behaviourally identical. */
    public static void noOverlappingRendering(View v, boolean value) {
        if (Build.VERSION.SDK_INT >= 23) v.forceHasOverlappingRendering(value);
    }

    /** API 29: disableSelf(). On older builds, finish the activity and hide its entry instead. */
    public static void disableSelf(Activity a) {
        if (Build.VERSION.SDK_INT >= 29) {
            a.finish();
        } else {
            a.finishAffinity();
        }
    }

    /** API 24: Configuration.getLocales(). Fall back to the deprecated single locale. */
    @SuppressWarnings("deprecation")
    public static Locale locale(Configuration cfg) {
        if (Build.VERSION.SDK_INT >= 24) return cfg.getLocales().get(0);
        return cfg.locale != null ? cfg.locale : Locale.getDefault();
    }

    /** API 26: Resources.getFont(). Return null so callers fall back to a bundled TTF. */
    public static Typeface font(Resources res, int id) {
        if (Build.VERSION.SDK_INT >= 26) return res.getFont(id);
        return null;
    }

    /** API 26: Files.readAllLines(). */
    public static List<String> readAllLines(File f) throws IOException {
        List<String> out = new ArrayList<>();
        try (BufferedReader r = new BufferedReader(new FileReader(f))) {
            String line;
            while ((line = r.readLine()) != null) out.add(line);
        }
        return out;
    }
}
```

Same treatment for `TvInputInfo` helpers — `isHidden(Context)` and `loadCustomLabel(Context)` are
gated on some vendor builds; degrade to `false` / `null` and let the caller synthesize a label from
`getId()` instead (see `references/04-input-sources.md`).

### Gates actually hit in a real port

| Area | Gated API | Minimum level | Degradation |
|---|---|---|---|
| User | `isUserUnlocked` | 24 | return `true` |
| View | `forceHasOverlappingRendering` | 23 (missing on some vendor builds) | no-op |
| View | `setForceDarkAllowed` | 29 | skip |
| Activity | `disableSelf` | 29 | `finishAffinity` |
| Config | `getLocales` | 24 | `getLocale` |
| Resources | `getFont` | 26 | bundled TTF |
| Files | `Files.readAllLines` | 26 | `BufferedReader` |
| TvInput | `isHidden` / `loadCustomLabel` | 21+ (broken on vendor builds) | `false` / `null` |

A port that looks "mostly working" but crashes when opening settings, changing language, or
rendering a custom font is almost always one of the last four rows.

## Never do this

- Bumping `minSdk` back up to silence lint — the APK then refuses to install.
- Wrapping the whole `onCreate` in `try/catch (Throwable)` — hides the real gate and leaves a blank
  surface, which on a launcher means an unusable TV.
- Relying on `targetSdkVersion` to change runtime behaviour on API 23; it only affects the
  23-and-below compatibility switches, not availability of new APIs.
