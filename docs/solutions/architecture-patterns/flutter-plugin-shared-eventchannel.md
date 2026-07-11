---
title: "Flutter plugin: share one EventChannel backend across instances, demux by id"
date: 2026-07-12
category: architecture-patterns
module: neo_vap
problem_type: architecture_pattern
component: tooling
severity: medium
applies_when:
  - "A Flutter plugin exposes many widget/controller instances that each need native to Dart events"
  - "The native side holds a single EventChannel.EventSink but Dart opens one subscription per instance"
symptoms:
  - "Intermittent — an instance's native events (an 'ended'/'firstFrame' callback) silently never arrive"
  - "Breaks on instance churn (screen/tab switch, hot restart) but works on cold start with one instance"
root_cause: async_timing
resolution_type: code_fix
tags: [flutter, plugin, eventchannel, methodchannel, texture, race-condition, multi-instance]
related_components: [neo_vap_controller, neo_vap_method_channel]
---

# Flutter plugin: share one EventChannel backend across instances, demux by id

## Context

`neo_vap` renders transparent VAP video into Flutter `Texture`s. Each screen
holds a `NeoVapController` that talks to the native plugin over a `MethodChannel`
and receives playback events (`firstFrame`, `ended`, `error`) over an
`EventChannel`. The onboarding "Active Mode" pendant animation is an intro clip
that plays once, then a loop clip that plays forever; the loop is what glows.

Symptom: **the pendant intermittently didn't glow.** It played fine on a cold
start but froze on the intro's dark final frame after a screen/tab switch or a
hot restart — sometimes. Classic heisenbug.

## Guidance

**In a Flutter plugin that spins up multiple instances, do NOT open one
`EventChannel` subscription per instance against a single native `EventSink`.**
The native plugin holds one sink; `onListen` sets it and `onCancel` nulls it.
With N instances each calling `receiveBroadcastStream().listen(...)`, the last
`onListen` wins and any `onCancel` nulls the shared sink — so a disposing
instance starves a freshly-created one.

Instead: **share one backend (one `EventChannel` subscription) for the whole
app, and demux events to the right instance by an id** (texture id, view id,
handle) carried in the event payload.

```dart
// BEFORE — each controller makes its own channel/subscription (racy)
NeoVapController({NeoVapBackend? backend})
    : _backend = backend ?? MethodChannelNeoVap(); // new EventChannel each time

// AFTER — one shared backend => one native subscription; demux by texture id
NeoVapController({NeoVapBackend? backend})
    : _backend = backend ?? _sharedBackend;
static final NeoVapBackend _sharedBackend = MethodChannelNeoVap();
```

Each controller still filters the shared broadcast stream by its own id:

```dart
void _onEvent(NeoVapEvent e) {
  if (e.textureId != _textureId || _state == NeoVapState.disposed) return;
  // ...handle
}
```

## Why This Matters

The native sink lifecycle is driven by Dart subscription lifecycle, and the
order is not guaranteed. Instrumented trace of a frozen re-entry (`tex=2` is the
new controller):

```
play active_mode_intro repeat=1 tex=2
onListen  -> sink SET
onCancel  -> sink NULLED        # disposing old controller's cancel lands AFTER
emit firstFrame tex=2 sinkNull=true   # dropped
STATE_ENDED tex=2                     # intro ended natively (fine)
emit ended tex=2 sinkNull=true        # DROPPED -> Dart never chains the loop
>>> FROZEN
```

The dropped `ended` meant the Dart intro->loop chain never fired, so playback
stayed on the intro's dark final frame — no glow. It was intermittent because it
was a race on the shared sink, and invisible on cold start because there was
only ever one subscriber. **Reproduced at ~3/4 tab-switches before the fix, 0/6
after.** The bug lived entirely in the Dart/native event architecture, so it
would have hit iOS identically.

Secondary hardening: **don't make a frame-accurate handoff depend on an event
round-trip at all.** The intro->loop start was `native STATE_ENDED -> emit ->
main-post -> EventChannel -> Dart -> play(loop) -> MethodChannel -> native` — six
hops, any of which can drop or lag. Moving the chain into the native player
(ExoPlayer `setMediaItems([intro, loop])` + `REPEAT_MODE_ONE` on
`onMediaItemTransition` to the loop item) makes the loop start gaplessly and
survive a dropped event.

## When to Apply

- Any Flutter plugin whose widget/controller is instantiated more than once and
  consumes native events (video/texture players, camera previews, map views, BLE
  peripherals, per-connection sockets).
- Especially when instances are created/disposed on navigation, tab switches, or
  survive hot restart — that churn is what surfaces the race.
- Reach for native-side sequencing (not a Dart event round-trip) whenever a
  transition must be frame-accurate or must not be lost.

## Examples

Two robustness levels, both applied here:

1. **Routing (root cause):** one shared `MethodChannelNeoVap` => one native
   `EventChannel` subscription; native emits `{id, event, ...}`; controllers
   filter by `id`. `onListen`/`onCancel` now fire only at app start/teardown, so
   the sink is never nulled mid-life. (commit `770ecc1`)
2. **No round-trip for critical transitions (defense-in-depth):** native playlist
   drives intro->loop; Dart passes the loop as `nextAsset` in one `play` call and
   no longer waits for `ended` to start the loop. (commit `6881ffc`)

Regression guard (Dart): assert the shared-backend invariant, since a fake
broadcast stream can't reproduce the native single-sink race.

```dart
test('controllers share one default backend (single native subscription)', () {
  final a = NeoVapController(videoAsset: 'a.mp4');
  final b = NeoVapController(videoAsset: 'b.mp4');
  expect(identical(a.backend, b.backend), isTrue);
});
```

## Related

- Diagnosed with `/ce-debug`; root cause confirmed by on-device instrumented
  trace (Android 15, Impeller/Vulkan).
- Commits: `770ecc1` (shared backend), `6881ffc` (native gapless intro->loop).
