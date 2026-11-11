# Findings (MHI2_ER_AUG22_P3241 / MU0678)

All observations come from one car with firmware identical to upstream's test unit; log tag `build audi-mu0678-r23-rxstats`
(hook r60).

## 1. Black cockpit for the whole first session (fixed in v1.1)

**When:** the phone is connected for the first time in a boot *after* the car's navigation is ready (≈ 80 s after boot).
Unplugging and replugging fixed it.

**Why:** the r25 autostart script embedded in the hook takes a fast path when navigation is already ready
(`if [ $i -eq 0 ]`) and skips the UI re-acquire. `vc_render` is cold-started about 2 s after the stream begins, so the
phone's opening IDR is dropped; the hook's three `ForceKeyFrame` requests get no IDR (`no IDR after 3 requests; forwarding anyway`)
and nothing can be decoded for the rest of the session. On a replug `vc_render` is already listening (`IDR seen`).

**Fix (`tools/make_hook_v11.py`):** two strings in the hook's read-only data, 3 bytes:
`if [ $i -eq 0 ]` → `if [ $i -lt 0 ]` (the fast path is never taken, so this case also gets the author's single
re-acquire) and `else sleep 3` → `else sleep 5` (re-acquire after `vc_render` is up). Verified in the car: the same
"forwarding anyway" happens, then `gen2 explicit reacquire requested` 5 s later, an IDR-sized burst arrives and the map shows
about 9 s after plugging in. `tests/test_r25_script.sh` shows the old and new script behaviour side by side.

## 2. Frame rate drops to 16–21 fps while a route is active

29–30 fps without a route, 16–21 fps as soon as CarPlay route guidance starts (same before and after dual navigation).
Upstream's TRACE-012 says the phone caps stream 111 unless the alt display advertises `features=2` with a knob HID.
In the r60 source `alt111_profile.c` sets `features = hid_ready ? 2 : 0` and `hid_ready` is never set, so `/info`
still advertises `features=0` (the log line `GEN2 /info ready: ... features=0`), even though stage 7 (knob HID +
`primaryInputDevice`) is applied. The hook has a test override, `/tmp/mibr-alt111-audi.featv` (an integer), read at
`/info` time — an untested, zero-persistence way to try `features=2`.

## 3. Dual navigation (M.I.B. NavActiveIgnore) on this firmware

- The stock `lsd.sh` already contains `## Find and append jar files`: every `*.jar`/`*.zip` in `lsd/jars/` is put on
  `-Xbootclasspath` **before** `/ifs/lsd.jxe`. So on Audi, M.I.B. only copies the jar (its "Remove" button deletes it);
  `lsd.sh` needs no change. Confirmed on the car with `pidin ar`.
- The jar overrides two classes. Checked member by member against this unit's `lsd.jxe` (`tools/jxe/check_override.py`):
  same fields, methods, signatures, static-ness and access; every reference resolves; interface methods implemented.
  - `org.dsi.ifc.carplay.AppState`: only `getAppStateID()` and `getOwner()` differ — stock returns the field, the patch
    returns 0. The HMI's `IAppState` maps CarPlay app states to `PHONE=1, NAVIGATION=2, SPEECH=3`; with 0 the HMI never
    sees "navigation on device", so it does not switch the cockpit to the compass page (BAP `INFO_STATES = 6`).
    Side effect by design: `DSICarplay.responseUpdateMode(Resource[], AppState[])` echoes zeros. Siri and CarPlay calls
    use other interfaces (`CallState`, `TelephonyState`, `requestSIRIAction`, audio resources) and were tested fine.
  - `AndroidAuto2NavHandler`: only `updateNavFocus` differs (Android Auto only).
- After install: `NavActiveIgnore.jar` on the class path right before `lsd.jxe`; no Java exceptions in `sloginfo`; one
  continuous CarPlay session with 16 route state changes and 0 decode errors.

## 4. J9 ROM image notes (`/ifs/lsd.jxe`)

`lsd.jxe` is a ZIP; `rom.classes` (57.5 MB) is a J9 ROM image (`J99J`, version `0x06090906`, 29065 classes).
`tools/jxe/romimg.py` + `members.py` decode it (self-relative pointers; header `idTag, flagsAndVersion, romSize,
classCount, SRP jxe, SRP TOC, SRP firstClass, SRP aot, id[16]`; TOC = (SRP name, SRP class) pairs). ROM class offsets:
`+00 romSize, +08 className, +0c superclass, +10 modifiers, +14 interfaceCount, +18 interfaces, +1c methodCount,
+20 methods, +24 fieldCount, +28 fields`. Method header is 20 bytes and its **bytecode size is stored in 4-byte words**;
a static constant field is followed by its 4- or 8-byte value. With these rules all 29065 classes decode with exactly the
declared member counts and valid descriptors.

## 5. Steering-wheel zoom (in progress)

The r60 hook already contains the reader: it connects to the HMI DSITracer telnet appender on `127.0.0.1:1798` and turns
`DSIKeyPanelListener#updateEncoder2 |int:4|int:40|±1` into `changeMapZoomLevel`. Enabling the tracer needs
`lsd/dsitracer_activated` (then `lsd.sh` adds `DSITracer.jar` to the boot class path **before** `jars/` and starts the HMI
with `bundles_dsitracer_enabled.properties`) and a `traceConfig.properties` with `use.appender=telnet` and
`org.dsi.ifc.keypanel.DSIKeyPanel=full`. Still to check before building an installer: whether `DSITracer.jar` shadows
any class of `lsd.jxe` or of `NavActiveIgnore.jar`, that its references resolve, and the exact bundle-list difference.
The HMI's built-in `resources/bundles.properties` equals the on-disk `bundles.properties` apart from CRLF line ends.
