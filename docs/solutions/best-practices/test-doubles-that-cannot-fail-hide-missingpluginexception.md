---
title: "A test double that can't throw can't catch a missing guard: closing three MissingPluginException escape hatches in a Flutter plugin"
date: 2026-07-29
category: best-practices
module: neo_vap
problem_type: best_practice
component: testing_framework
severity: medium
applies_when:
  - "Writing or reviewing a Flutter plugin's native MethodChannel handler on either platform"
  - "A Dart API calls a platform method unawaited on a teardown path (dispose, page swipe, route pop)"
  - "A test suite covers error-handling code through a hand-written fake, stub, or mock"
  - "Adding a method to a plugin's Dart backend that both native switches must also handle"
symptoms:
  - "A Dart platform call rejects with MissingPluginException even though the plugin is registered and every other method on the same channel works"
  - "An OutOfMemoryError or UnsatisfiedLinkError raised inside an Android MethodChannel handler reaches Dart as MissingPluginException, never as PlatformException"
  - "An unhandled async error escapes a fire-and-forget platform call on a teardown path, where no caller is left to observe the rejection"
  - "A fully green test suite over error-handling code whose catch blocks no test can actually reach"
root_cause: wrong_api
resolution_type: code_fix
tags:
  - "flutter"
  - "plugin"
  - "method-channel"
  - "missing-plugin-exception"
  - "error-handling"
  - "test-doubles"
  - "mutation-testing"
  - "kotlin"
related_components:
  - "neo_vap_controller"
  - "neo_vap_method_channel"
  - "android_plugin"
  - "ios_plugin"
---

# A test double that can't throw can't catch a missing guard

## Context

`neo_vap` exists because its predecessor, `flutter_vap_plus`, threw
`MissingPluginException` constantly in the consumer app — reliably on teardown,
during page transitions. The mechanism is worth stating precisely, because
"can this recur?" is the first question anyone arriving at this plugin asks.

`flutter_vap_plus` created a **MethodChannel per PlatformView** (`flutter_vap_<viewId>`)
and called `setMethodCallHandler(null)` from inside `PlatformView.dispose`.
Flutter disposes children before parents, so a parent widget's `controller.stop()`
in its own `dispose()` raced the child view's channel teardown. The handler was
already null; the engine had nothing to reply with; Dart raised
`MissingPluginException`. The bug was structural — the channel's lifetime was
tied to a widget's lifetime, and widget lifetimes are not ordered the way
callers assume.

`neo_vap` does not have that shape. `NeoVapPlugin.onAttachedToEngine` creates
**one process-wide channel** named `neo_vap`, and `onDetachedFromEngine` is the
only place that tears it down. There is no per-view handler, so there is no
per-view handler to go missing. That part of the verdict held.

A two-agent adversarial review (one agent prosecuting the claim "this can still
throw `MissingPluginException`", one defending) then went looking for what the
topology argument does *not* cover. It found three real defects — all now fixed
in `lib/src/neo_vap_controller.dart` and
`android/src/main/kotlin/xyz/neosapien/neo_vap/NeoVapPlugin.kt` — and one
meta-finding about the test suite that is the most transferable part of the
exercise. The suite was **39 tests, all green, through every one of the three
defects**, because the test double could not produce the failure.

## Guidance

### 1. Catch `Throwable`, not `Exception`, in every Android platform handler — and know why

Kotlin's `Exception` and `Error` are **sibling** subclasses of `Throwable`. A
`catch (e: Exception)` around a MethodChannel handler does not catch
`OutOfMemoryError`, `UnsatisfiedLinkError`, or `ExceptionInInitializerError`.

The consequence is not "the error propagates as a `PlatformException` instead."
It is much worse and much less obvious:

> **An uncaught throwable in an Android MethodChannel handler makes the engine
> send an EMPTY REPLY, and Dart renders an empty reply as `MissingPluginException`
> — not `PlatformException`.**

So a handler's own error handling was a live path to the exact exception the
plugin's architecture was designed to make impossible. In `neo_vap` this was not
theoretical: the heavy allocations sit directly under the two hottest cases.
`allocateTexture` constructs a `NeoVapPlayer`, which starts a `HandlerThread`;
`play` builds an ExoPlayer. Both can OOM on a device under memory pressure —
and both would have surfaced in Dart as `MissingPluginException`, sending the
next reader straight back to the `flutter_vap_plus` diagnosis, which would have
been wrong.

The fix is one word:

```kotlin
} catch (e: Throwable) {
    // Throwable, not Exception: Kotlin's Exception and Error are siblings,
    // so OutOfMemoryError (NeoVapPlayer starts a HandlerThread and builds
    // an ExoPlayer under allocateTexture/play), UnsatisfiedLinkError, and
    // ExceptionInInitializerError all escape a `catch (e: Exception)`.
    // An uncaught throwable here makes DartMessenger send an EMPTY reply,
    // which Dart surfaces as MissingPluginException — not PlatformException
    // — i.e. the one failure this plugin's architecture is meant to rule
    // out would come back through the error handler itself.
    result.error("neo_vap", e.message, null)
}
```

The same rule applies to any background thread the plugin starts: `prewarm()`'s
worker uses `catch (t: Throwable)` around `NeoVapRenderer` construction because
an uncaught throw on a bare `Thread` kills the process, not just the call.

### 2. Every fire-and-forget channel call needs a terminal error handler

`unawaited(future)` with no `.catchError` is an unhandled async error waiting for
a bad day. In a `Zone`-guarded test it fails the test; in production it logs, and
in some harnesses it escalates.

Teardown paths are the highest-risk instance of this, because teardown is
exactly where there is **no caller left to observe the rejection**. Both
`NeoVapController.dispose()` and `stop()` are called this way in the consumer
app — a page swipe stops the off-screen controller and never awaits it.

### 3. Do not justify an omitted guard with channel topology

The most instructive part of Finding 2 was not the missing `.catchError` but the
comment that stood in its place, which read: *"there is no per-view MethodChannel
to raise `MissingPluginException`."* That reasoning is wrong, and wrong in a way
that would have propagated.

`MissingPluginException` is raised from a **null platform reply**. A null reply
occurs on at least three paths:

1. no registered handler for the channel,
2. an **uncaught native throwable** in the handler (Finding 1),
3. an explicit `result.notImplemented()` / `FlutterMethodNotImplemented`.

Channel topology rules out **none** of them. What actually protects `neo_vap` is
a different pair of invariants: **method-name parity** between the Dart backend
and both native switches, and **single-engine, process-wide channel topology**.
Neither was named in that comment, and both can be broken silently by a future
change. The replacement comment names the real invariants:

```dart
// Fire-and-forget: releasing the texture must not block widget teardown.
//
// The catchError is load-bearing. MissingPluginException comes from a null
// platform reply, which happens on no registered handler, an uncaught
// native throwable, or notImplemented() — channel topology rules out none
// of them. What actually protects this plugin is method-name parity with
// both native switches plus a single process-wide channel, and neither is
// an invariant this line can rely on. Teardown is also the one path with
// no caller left to observe a rejection, so swallow it here.
unawaited(_backend.dispose(id).catchError((Object _) {}));
```

A comment that explains why a guard is unnecessary is a load-bearing claim. If
it is wrong, it survives review by *looking* like it was already considered.

### 4. A test double that cannot throw cannot verify error handling

This is the rule with the widest blast radius. The suite had 39 green tests
covering the controller thoroughly. Its double looked like this:

```dart
@override
Future<void> stop(int textureId) async => calls.add('stop');

@override
Future<void> dispose(int textureId) async => calls.add('dispose');
```

Those methods have no failure mode. No arrangement of assertions over that
double can distinguish `await _backend.stop(id)` from
`try { await _backend.stop(id); } catch (e) { ... }`. Green tests over a double
that cannot produce the failure are **not evidence that the failure is handled**
— they are evidence that the happy path works, and nothing more.

The fix is a double that fails in the shape the real platform fails in:

```dart
/// A backend whose teardown calls reject the way a real platform does when no
/// handler answers: the engine sends a null reply and Dart raises
/// [MissingPluginException]. [FakeBackend]'s methods can never throw, so on its
/// own it cannot catch an unguarded call — which is exactly how the missing
/// guards on `stop()`/`dispose()` survived a green suite.
class RejectingBackend extends FakeBackend {
  @override
  Future<void> stop(int textureId) async {
    calls.add('stop');
    throw MissingPluginException('No implementation found for method stop');
  }
  ...
}
```

Note the choice of exception type: `MissingPluginException`, not
`Exception('boom')`. The double reproduces the *actual* platform failure mode,
so the test doubles as documentation of what the real system does.

### 5. Assert method-name parity between Dart and every native switch, mechanically

With Findings 1–3 fixed, exactly one route to `MissingPluginException` remains
in normal use: **add a method to the Dart backend, forget one native switch.**
That platform falls through to `notImplemented()` /
`FlutterMethodNotImplemented`, the engine replies null, Dart throws — and it
ships, because the developer tested on the platform they remembered.

No conventional test can catch this: every test in
`test/neo_vap_method_channel_test.dart` installs a mock handler via
`setMockMethodCallHandler`, and a mock handler answers *every* method name.
The mock is precisely what makes the bug invisible. The guard therefore has to
read the sources:

```dart
final sent = RegExp(r"""invokeMethod<[^>]*>\(\s*['"](\w+)['"]""")
    .allMatches(read('lib/src/neo_vap_method_channel.dart'))
    .map((m) => m.group(1)!)
    .toSet();

// Guards the regex itself — a refactor that stops matching would otherwise
// make this test pass vacuously against an empty set.
expect(
  sent,
  containsAll(['allocateTexture', 'play', 'stop', 'dispose']),
  reason: 'regex no longer matches the Dart invokeMethod call sites',
);

for (final method in sent) {
  expect(kotlin, contains('"$method"'),
      reason: 'Android has no handler for "$method" '
          '-> notImplemented() -> MissingPluginException');
  expect(swift, contains('"$method"'),
      reason: 'iOS has no handler for "$method" '
          '-> FlutterMethodNotImplemented -> MissingPluginException');
}
```

Two details make this test trustworthy rather than decorative:

- **The self-guard.** Any test that derives its inputs from a regex over source
  can silently degrade to iterating an empty set — passing forever while
  checking nothing. The `containsAll([...])` assertion makes a broken regex fail
  loudly. Every source-scraping test needs one.
- **The stated ceiling.** The check greps for the literal quoted name rather
  than parsing Kotlin/Swift, so a method name appearing only inside a comment
  would false-pass. That is written down in the test as a known limit with an
  upgrade path, not left for a reader to discover.

### 6. Mutation-check every new guard

A guard you have not seen fail is a guard you have not tested. For each of the
three fixes: revert that fix alone, run the suite, **confirm it fails**, restore
the fix, confirm green. All three were checked this way; the suite went 39 → 42
tests, green.

## Why This Matters

**Rule 1 (`Throwable`)** converts a whole class of device-dependent failures
from misdiagnosable to diagnosable. Skipping it costs more than a swallowed
error: it costs an on-call engineer a day, because the symptom
(`MissingPluginException` on a texture plugin) points at the one root cause that
was already fixed and cannot recur. The correct diagnosis — "the device OOM'd
building an ExoPlayer" — is nowhere in the symptom. Compiling the fix is cheap:
`flutter build apk --debug` succeeded on the one-word change.

**Rules 2 and 3 (fire-and-forget guards)** buy the property the doc comments
already claim. This repo had already written the rule down: the prior learning
`docs/solutions/architecture-patterns/texture-plugin-prewarm-hardening.md`,
"Rule 2 — The Dart facade must swallow the Future," and `NeoVap.prewarm()`
obeys it:

```dart
static Future<void> prewarm({String? warmupAsset}) =>
    NeoVapController._sharedBackend
        .prewarm(warmupAsset: warmupAsset)
        .catchError((Object _) {});
```

`dispose()` did not, and `stop()` had no error handling at all — despite
`play()`, which is structurally identical, having a `try`/`catch`. **A rule
written in a doc and applied in one place is not applied.** The recurrence is
the evidence: the same team, the same file, the same quarter, the same rule.
Guards need mechanical enforcement (a test) or they decay to one instance.

**Rule 4 (the double that cannot throw)** is the reason the other three survived
review. This is the concrete cost of skipping it: **39 tests, 100% green, zero
signal on error handling.** The suite tested that `stop()` sends `'stop'`, that
`dispose()` never routes through `stop()` (a real regression guard for the
`flutter_vap_plus` bug), that events demux by texture id — genuinely good tests,
every one of them blind by construction to whether a rejection is caught. Test
count and pass rate measured nothing about the property under review. Adding
`RejectingBackend` cost 12 lines and immediately turned two of the three fixes
into verifiable assertions.

**Rule 5 (parity)** buys the one remaining `MissingPluginException` route.
Its value is asymmetric: the failure it prevents is a *ship-blocking, one-platform*
bug found by users, and the test is ~25 lines that run in milliseconds with no
device, no emulator, no native toolchain.

**Rule 6 (mutation check)** is what separates "I added a test" from "I added a
test that would have caught this." Without it, Rules 4 and 5 are claims. A guard
whose failure you have never observed may be asserting on a path that no longer
executes.

## When to Apply

These generalize to **any** Flutter plugin with a platform channel, and most of
them to any FFI-style boundary:

- **Rule 1** applies to every `MethodCallHandler.onMethodCall` on Android, and
  to any JNI/native-thread boundary where an escaping `Error` is not the same
  type as an escaping `Exception`. Highest urgency when the handler allocates
  large buffers, textures, decoders, threads, or loads native libraries — i.e.
  every media, camera, ML, or graphics plugin. The Swift analogue is different
  in mechanism but identical in outcome: any path that returns without calling
  `result(...)` produces the same empty reply.
- **Rules 2 and 3** apply to every `unawaited(...)` over a channel call, and
  especially to anything invoked from `dispose()`, `deactivate()`, route pops,
  app-lifecycle handlers, or `WidgetsBindingObserver` callbacks — every place
  where the caller is already gone. If you write a comment explaining why a
  guard is unnecessary, verify the mechanism you are citing actually excludes
  the failure; "our channel topology" almost never does.
- **Rule 4** applies to any test double standing in for a fallible boundary:
  platform channels, HTTP clients, file systems, databases, IPC. If the double's
  methods cannot fail, the suite over it cannot verify failure handling,
  regardless of size. Ask of any suite: *what is the smallest change to
  production code that this suite would not notice?*
- **Rule 5** applies to any project with **one caller and two or more
  implementations that are not compile-time linked** — Flutter plugins
  (Dart/Kotlin/Swift/C++/JS), gRPC or REST clients versus servers in different
  languages, message-queue producers versus consumers, native FFI bindings. The
  compiler cannot see across that seam; a cheap source-level parity test can.
  Give every such test a self-guard against vacuous passing.
- **Rule 6** applies to every guard, always. It costs one revert and one test
  run.

## Examples

### Finding 3 — `stop()` had no error handling at all

Before, `stop()` awaited the backend bare while the structurally identical
`play()` right above it was wrapped in `try`/`catch`. After
(`lib/src/neo_vap_controller.dart`):

```dart
/// Stop playback and re-show the placeholder.
Future<void> stop() async {
  if (_textureId == null) return;
  try {
    await _backend.stop(_textureId!);
  } catch (e) {
    // Callers stop unawaited on teardown paths (a page swipe stops the
    // off-screen controller), so an escaping rejection lands as an unhandled
    // async error. Report it, but do not latch NeoVapState.error: a failed
    // stop is not a render failure, and the local intent — placeholder up,
    // controller still usable — holds whether or not native acknowledged.
    onError?.call('stop failed: $e');
  }
  _showPlaceholder = true;
  _setState(NeoVapState.ready);
}
```

The deliberate asymmetry is worth copying: `play()` routes its failure through
`_fail()`, which latches `NeoVapState.error` and re-shows the placeholder.
`stop()` reports through `onError` but **does not** latch `error`. A stop that
native did not acknowledge is not a render failure, and the local intent —
placeholder up, controller reusable — is satisfied either way. Not every failure
deserves the same state transition; decide per call what the failure means to
the caller.

And the test that proves it, which passes only while the guard exists:

```dart
test('stop() reports the failure and still applies its local intent', () async {
  final errors = <String>[];
  final c = NeoVapController(
    videoAsset: 'loop.mp4', backend: rejecting, onError: errors.add);
  await c.initialize();
  await c.play();

  await c.stop(); // must not throw

  expect(errors.single, contains('stop failed'));
  expect(c.showPlaceholder, isTrue);
  // A failed stop is not a render failure — the controller stays usable.
  expect(c.state, NeoVapState.ready);
});
```

### The mutation check, worked

The technique, run for each of the three guards:

1. Revert exactly one fix in the working tree — e.g. change
   `unawaited(_backend.dispose(id).catchError((Object _) {}))` back to
   `unawaited(_backend.dispose(id))`.
2. Run `flutter test`. **The relevant test must fail.** For the `dispose()`
   guard it does, because `RejectingBackend.dispose` throws into a `Future`
   nobody awaits, and `flutter_test` runs each test in a `Zone` whose
   uncaught-async-error handler fails the test. If it had *passed*, the new test
   would have been asserting on the wrong thing.
3. Restore the fix. Re-run. Green.

Repeat for `stop()`'s `try`/`catch` (the `RejectingBackend` stop test), and for
the parity test (delete a `case` from the Swift switch and confirm the parity
test names the missing method). Only after all three failed-then-passed is the
suite's 42-green a claim about behavior rather than a count.

### Known and open: the residual risk is the opposite shape

Deliberately **not** fixed, and documented here so the next reader inherits it
rather than rediscovers it. Both native backends silently no-op a `play` on a
texture id that has no player:

```kotlin
"play" -> {
    player(call)?.play(...)   // null-safe: no player -> nothing happens
    result.success(null)      // ...and Dart is told it succeeded
}
```

```swift
case "stop":
  players[textureId(args)]?.stop()
  result(nil)
```

Dart's `play()` **resolves successfully**, the controller settles in
`NeoVapState.playingLoop`, and no error event ever fires. The result is a
permanently blank video with no exception anywhere — the mirror image of the
`MissingPluginException` class of bug, and arguably harder to diagnose because
there is nothing to grep for. This repo has already shipped a blank-render bug
once: `docs/solutions/ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md`.

It is left open because the fix is a **design decision, not a repair**: should a
missing texture be an error event to `onError`, a latched `NeoVapState.error`,
or a tolerated no-op during a teardown race where the texture legitimately went
away first? Each answer changes the controller's contract. Decide it
deliberately, with the consumer app's teardown ordering in hand — do not patch
it reflexively.

## Related

- [`architecture-patterns/texture-plugin-prewarm-hardening.md`](../architecture-patterns/texture-plugin-prewarm-hardening.md) — **closest neighbour, and this doc widens and corrects it rather than merely citing it.** Its "Rule 2 — The Dart facade must swallow the Future" is the same guard Finding 2 restores on `dispose()`, but Rule 2 scopes the need to *platforms that have not implemented the handler yet*. That scoping is too narrow: a fully-implemented handler that lets a `Throwable` escape produces the identical rejection, so shipping every platform does not retire the risk. Note also that its Rule 1 already prescribed `catch (t: Throwable)` for the prewarm worker — in the same Kotlin file whose `onMethodCall` still used `catch (e: Exception)`. The correct instinct existed feet away and did not propagate.
- [`architecture-patterns/flutter-plugin-shared-eventchannel.md`](../architecture-patterns/flutter-plugin-shared-eventchannel.md) — establishes the single process-wide shared backend that the new `dispose()` comment leans on, so it is a premise of Finding 3's reasoning rather than just adjacent. It also contains the first, narrower instance of this doc's meta-finding: a fake broadcast stream could not reproduce the native single-sink race, so that learning asserted the invariant in a test instead. Same blindness, same workaround, one failure family earlier.
- [`ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md`](../ui-bugs/fittedbox-unit-aspect-box-blanks-texture.md) — where the still-open finding above belongs: a `play` against a missing texture that reports success is a third member of this plugin's silent-drop family (that doc drops frames, the EventChannel one drops events, this one drops the call itself). Methodological sibling too — both learnings end in a mutation-checked regression test, and both punchlines are that the verification actually performed could not have detected the bug.
- `docs/plans/2026-07-11-001-feat-neo-vap-plugin-plan.md` — **the provenance of the wrong comment.** Its architecture diagram states `dispose ─► release texture + player (no per-view MethodChannel → no MissingPluginException)`, which is verbatim the false justification Finding 2 removed from the code, and it makes "no MissingPluginException on navigate-away" an acceptance criterion the pre-fix code could have failed with no test noticing. The belief was inherited from the plan, not invented at the keyboard — worth knowing, because plans propagate into comments and comments survive review by looking considered.
- No GitHub issues to link — the repository has issues enabled but none filed (an unfiltered control query also returned zero). Issue tracking for this work lives in Linear (NEO-2559).
