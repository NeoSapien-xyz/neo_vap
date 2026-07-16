---
title: "Texture-plugin cold-start prewarm: warm off-main, and three fire-and-forget hardening rules"
date: 2026-07-12
last_refreshed: 2026-07-16
category: architecture-patterns
module: neo_vap
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "A texture-based Flutter plugin warms its native decode/GPU pipeline at app init to kill first-play cold-start latency"
  - "A best-effort, fire-and-forget native call is invoked from Dart at startup, possibly before every platform implements it"
  - "A caller blocks on a latch/future while a render or GPU thread does native init that can fail or hang"
symptoms:
  - "First animation stalls for hundreds of ms on first play (cold EGL/Metal + shader compile + decoder alloc)"
  - "App crashes at init from an uncaught exception thrown on a background warm thread"
  - "Unhandled MissingPluginException logged every launch on a platform whose native handler is not implemented yet"
  - "Main thread ANRs when a native GPU-init call wedges and the caller blocks on an unbounded latch"
root_cause: thread_violation
resolution_type: code_fix
tags: [flutter, plugin, texture, prewarm, cold-start, background-thread, fire-and-forget, anr]
related_components: [neo_vap_controller, neo_vap_method_channel]
---

# Texture-plugin cold-start prewarm: warm off-main, and three fire-and-forget hardening rules

## Context

`neo_vap` renders transparent VAP video into Flutter `Texture`s via OS decoders +
a GPU alpha-composite shader. The first real play pays a **cold-start tax**: the
first EGL/Metal init, the first shader compile/link, and the first decoder
allocation all happen on the critical path, stalling the first animation for
hundreds of ms. The fix is a **prewarm**: at app init, warm the native pipeline
once so the first animation renders immediately.

The warm itself is easy. The trap is that it is a *best-effort, fire-and-forget,
cross-platform, background-threaded* call — and each of those four adjectives
hides a way to turn a latency optimization into a crash, a log-spam, or an ANR.
A code review of the Android prewarm surfaced three distinct gotchas; all three
generalize to any platform's prewarm — the iOS Metal prewarm has since landed and
carried all three over unchanged — and to any plugin that warms a native pipeline
at startup.

## Guidance

**Warm the expensive native pipeline once, off the main thread, at app init —
and treat the warm as genuinely best-effort by hardening all three failure
surfaces.**

### 0. Warm off-main; the win is the driver/compiler, not per-instance state

Run the warm on a background thread so init never blocks the UI. On Android the
warm just runs the real renderer's GL init (EGL context + `glCompileShader` +
link) against a throwaway 16×16 geometry, then releases it — this warms the GPU
driver and shader compiler at the *process* level, so later per-texture
renderers (each with its own context) hit a warm driver. You do not need to warm
per-instance state; you need to warm the process-global cold paths.

```kotlin
"prewarm" -> { prewarm(); result.success(null) }   // returns immediately

private fun prewarm() {
    if (warmed) return           // @Volatile, set once — MethodChannel calls are
    warmed = true                // serialized on the platform thread, so no race
    Thread {
        // ... build throwaway renderer, awaitInputSurface() (runs initGl), release()
    }.apply { name = "neo_vap_prewarm" }.start()
}
```

### Rule 1 — Construct the warm resource *inside* the best-effort try

A background thread that throws an **uncaught** exception triggers the platform's
default uncaught-exception handler, which **kills the whole process** — at app
init, that is a launch crash. "Best-effort" must therefore wrap *every* line that
can throw, including object construction (which may start its own thread or
allocate native handles), not just the warm call.

```kotlin
// BEFORE — construction is outside the guard; a thread-creation/OOM failure escapes
val r = NeoVapRenderer(dummy) {}          // NeoVapRenderer starts a HandlerThread
try { r.awaitInputSurface() } catch (t: Throwable) { log(t) } finally { r.release() }

// AFTER — construct inside the try; nullable handle released in finally
var r: NeoVapRenderer? = null
try {
    r = NeoVapRenderer(dummy) {}
    r.awaitInputSurface()
} catch (t: Throwable) {
    Log.w("neo_vap", "prewarm skipped (best-effort): ${t.message}")
} finally {
    r?.release()
}
```

### Rule 2 — The Dart facade must swallow the Future

A fire-and-forget `NeoVap.prewarm()` returns a `Future` nobody awaits. On any
platform whose native handler is **not yet implemented** (as iOS was before its
Metal backend landed), the method channel rejects with `MissingPluginException` — an **unhandled async
error logged every single launch**. A call documented "safe to call, best-effort"
must actually be safe: swallow the rejection at the facade so no call site can
surface it. The native side still logs real warm failures, so visibility is not
lost.

```dart
static Future<void> prewarm({String? warmupAsset}) =>
    _sharedBackend
        .prewarm(warmupAsset: warmupAsset)
        // A platform with no native prewarm handler rejects with
        // MissingPluginException; swallow so this fire-and-forget call never
        // surfaces an unhandled async error. Native logs real warm failures.
        .catchError((Object _) {});
```

### Rule 3 — Bound any init latch, or the caller ANRs

If a caller blocks on a latch/semaphore while a render/GPU thread does native
init, an unbounded wait means a **wedged native call blocks the caller forever**.
When that caller is the main thread (as it is on a real play), that is an ANR.
Bound the wait below the ANR threshold and throw on timeout so the caller's
existing error path runs — a recoverable failure beats a frozen app.

```kotlin
// BEFORE
latch.await()                                   // hangs forever if initGl() wedges

// AFTER — 3s ceiling (< Android's 5s ANR), throw so the caller's catch runs
if (!latch.await(3, TimeUnit.SECONDS)) throw RuntimeException("GL init timed out")
```

Caveat: a caller-side timeout bounds the *blast radius* (one failed animation),
not the underlying leak — a truly wedged render thread cannot be force-killed
from Kotlin and stays leaked. That is still far better than a dead app.

## Why This Matters

Each rule turns a specific silent failure into a survivable one:

- **Rule 1** is the difference between "first play is slightly slow" and "the app
  crashes on launch on some device." The warm exists to *improve* startup; an
  unguarded warm that can crash startup is strictly worse than no warm.
- **Rule 2** is invisible in single-platform testing and on the platform that
  *does* implement the handler — it only bites an as-yet-unimplemented platform,
  every launch, as log noise that masks real errors. Because it is a cross-platform
  facade over a partially-implemented native contract, the safe default (swallow)
  must be baked in before the second platform exists, not after someone notices
  the spam.
- **Rule 3** is a pre-existing hazard the prewarm merely *spotlighted*: the same
  `awaitInputSurface()` latch is on the real-play path on the main thread. Cold-
  start work that can hang must never be awaited unbounded from the UI thread.

The meta-lesson: **"best-effort" and "fire-and-forget" are claims you have to
*enforce*, not adjectives you get for free.** A warm that can crash, spam, or
hang has none of those properties. Audit every throw/reject/block on the path and
make the degraded outcome explicit.

## When to Apply

- Any Flutter plugin that warms a native decode/GPU/codec pipeline at app init
  (video/texture players, camera, ML/GPU inference, map tile renderers).
- Any fire-and-forget Dart→native call made at startup, **before all target
  platforms implement it** — the facade needs the `.catchError` from day one.
- Any place a Dart or native caller blocks on a latch/future waiting for
  render-thread or GPU init that can fail or hang — bound the wait.
- Confirmed platform-general by this plugin's **iOS Metal prewarm**: the same
  three rules carried straight over rather than needing rediscovery per platform.

## Examples

The three fixes landed on `neo_vap`'s Android prewarm:

1. **Off-main warm + Rules 1 & 2** — commit `f0a00b1`: real GL-pipeline warm on a
   named background thread (idempotent via a process-wide `@Volatile` flag),
   construction moved inside the best-effort try, and the `NeoVap.prewarm()`
   facade `.catchError`s the rejected backend Future.
2. **Rule 3** — commit `4337a04`: `awaitInputSurface()`'s `CountDownLatch.await()`
   bounded to 3s, throwing on timeout so the real-play path fails recoverably
   instead of ANR-ing.

Device-verified on Android 15 (device A015): warm logged `GL pipeline warmed in
276ms` at init, both clips still render, no crash, no regression.

The same three rules carried over to the **iOS Metal prewarm** (`NeoVapPlugin.swift`):
the warm dispatches off-main via `DispatchQueue.global(qos: .utility)`, all
construction lives inside `MetalCompositor.init?` (which returns nil instead of
throwing, satisfying Rule 1), and because the iOS warm dispatches async with no
main-thread latch, Rule 3 is satisfied by construction — there is nothing to bound.
Device-verified on a physical iPhone (iOS 26.5).

## Related

- [[flutter-plugin-shared-eventchannel]] — the companion `neo_vap` plugin-
  architecture learning (share one EventChannel backend across controller
  instances, demux by texture id). Same "the bug lives in the plugin's
  Dart/native seam, so it hits every platform identically" theme.
- The prewarm decision itself is KTD-6 in the plan
  (`docs/plans/2026-07-11-001-feat-neo-vap-plugin-plan.md`).
