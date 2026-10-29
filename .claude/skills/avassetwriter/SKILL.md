---
name: avassetwriter
description: Rules and pitfalls for writing video/audio with AVAssetWriter — real-time camera capture, chunked/segmented recording, fragment crash-safety, HLS/fMP4 segments, finishing and error handling, and the iOS 26 async input receivers. Use when writing, reviewing or debugging code that touches AVAssetWriter, AVAssetWriterInput, ChunkRecorder, or recorded MP4 files that are missing, unplayable, silent, gappy or out of sync.
---

# AVAssetWriter

Working rules for `AVAssetWriter` in this app (iOS 26.5 target, Swift 6,
default `MainActor` isolation). The app's writer lives in
`Just Capture/Services/ChunkRecorder.swift`; the design history is in
`CONSIDERATIONS.md`. Read both before changing recording behavior.

## Lifecycle (the order is not optional)

1. `AVAssetWriter(outputURL:fileType:)` — **one writer, one file, one use.**
   A new file always needs a new writer.
2. Configure writer properties and `add` inputs (check `canAdd`) — only
   while `status == .unknown`.
3. `startWriting()` (returns `Bool`; read `writer.error` on false) or, on
   iOS 26+, `try start()`. Can be done ahead of time; it's the slow part
   (encoder spin-up), so do it off the sample queue.
4. `startSession(atSourceTime:)` with the **PTS of the first video frame**
   you will append. Samples before it are trimmed; audio straddling it is
   trimmed, not dropped.
5. `append` samples, monotonically increasing PTS per input.
6. `markAsFinished()` on each input → `endSession(atSourceTime:)` (optional;
   trims to an exact end) → `finishWriting` (or `await finishWriting()`).
7. **Check `status == .completed`** in the completion. Anything else means
   the file is not a valid movie: delete it, surface `writer.error`.

Once `status == .failed`, every further append returns false — stop
appending, read `writer.error`, `cancelWriting()`, remove the file.
`append` returning `false` is the usual first sign of disk-full.

## Threading

- Apple DTS: appending audio and video from **different serial queues is
  safe**, but `finishWriting`/`cancelWriting` must never overlap an
  in-flight `append`. The simple, recommended shape is one serial queue for
  everything touching a given writer (what `ChunkRecorder.queue` does).
- Handing a whole writer to another queue to finish is fine *once nothing
  on the old queue can append to it any more* (`ChunkRecorder.finish`).
- AVFoundation types aren't `Sendable`; this codebase confines them to a
  queue and uses `@unchecked Sendable` wrappers / `nonisolated(unsafe)`
  lets. Keep that pattern rather than mixing in actors per writer.

## Real-time capture

- `expectsMediaDataInRealTime = true` on every input fed from a camera/mic.
- Never block or spin waiting for `isReadyForMoreMediaData`. If an input
  isn't ready, **drop the video frame and count it**; queue audio briefly
  (bounded) instead, because audio gaps are audible.
- An audio input reports not-ready until its writer has taken video, so
  audio that arrives before a new writer's first frame must be buffered.
- Don't do heavy work on the sample-buffer queue: writer creation,
  `startWriting`, and `finishWriting` all take long enough to make the
  camera drop frames (see `prepareQueue` / `finishQueue`).
- Start from the outputs' `recommendedVideoSettingsForAssetWriter(writingTo:)`
  / `recommendedAudioSettingsForAssetWriter(writingTo:)`, then override
  width/height with the actual pixel-buffer size — the recommended values
  ignore connection rotation.
- Orientation: rotating on the `AVCaptureConnection` produces upright pixels
  every player respects; `input.transform` is metadata some web players
  ignore.
- Capture PTS are on the host clock. With video stabilization, video
  frames arrive ~1–2 s after capture while audio arrives immediately, so
  any "cut at time T" logic must wait for late video and keep audio history.
- Have a writer ready (`startWriting` done) *before* the first frame you
  need it for, including the very first chunk. Building one on the sample
  queue cold cost ~0.5 s (15 frames) on an iPhone 17; warm, about a frame.
- In the background the app loses the hardware encoder. Don't trust a
  writer that was idle across an interruption: discard it, and check
  `status == .writing` before using a prepared one.

## Frame-drop diagnosis

Log why each frame was lost before guessing. In `didDrop`, read
`CMGetAttachment(sbuf, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, …)`:
`FrameWasLate` = the delegate queue was busy; `OutOfBuffers` = buffers held
downstream (encoder behind); `Discontinuity` = the camera skipped. Count
`!isReadyForMoreMediaData` separately as "writer busy". Log each with its
offset from the chunk start so clustering at cuts is obvious.

Measured on iPhone 17 (`CONSIDERATIONS.md` → Frame drops): a camera flip
stalls the encoder ~0.6 s (`writerBusy`) because of the capture session
reconfiguration, not encoder setup. Only `AVCaptureMultiCamSession` avoids it.

## Segmented / chunked recording

Two very different approaches — pick deliberately:

| | New writer per chunk (this app) | fMP4 / HLS segments |
|---|---|---|
| Output | Standalone MP4 per chunk, plays anywhere | Init segment + media segments; a segment alone won't play |
| API | `AVAssetWriter(outputURL:fileType: .mp4)` | `AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue)!)`, `outputFileTypeProfile = .mpeg4AppleHLS` or `.mpeg4CMAFCompliant`, `preferredOutputSegmentInterval`, `initialSegmentStartTime`, `delegate` |
| Cuts | Your code: end old writer, start new on the same frame | Writer cuts at keyframes; `flushSegment()` for manual cuts (requires `preferredOutputSegmentInterval = .indefinite`) |
| Playlist | n/a | You write it from `AVAssetSegmentReport` |

For per-chunk writers: pre-build the next writer before the cut, start
its session on the exact frame that ended the previous one, and send audio
buffers that straddle the cut to both writers (each trims to its range).

For segment output: the delegate's `didOutputSegmentData` was reported to
leak when implemented in Swift (reported fixed in macOS 13.3; iOS was
never tested, so watch memory on device if you adopt it). HLS target durations must be whole seconds.

## Crash safety and playability

- `movieFragmentInterval` (e.g. 2 s) makes an interrupted file recoverable
  up to the last fragment. `finishWriting` still produces a normal,
  defragmented `ftyp → moov → mdat` movie.
- `shouldOptimizeForNetworkUse = true` puts `moov` first (progressive
  playback in Drive/browsers).
- Write to a temporary name (`.partial`) and rename only after
  `.completed`, so a half-written file is never picked up for upload.
- HEVC from AVFoundation is tagged `hvc1`, which browsers need.

## iOS 26 async API

Available at this deployment target:

- `writer.inputReceiver(for:)` → `AVAssetWriterInput.SampleBufferReceiver`
  with `append(_:) async throws` (suspends until ready),
  `appendImmediately(_:) throws -> Bool` (non-blocking), `finish()`.
  Also `inputPixelBufferReceiver(for:pixelBufferAttributes:)` and
  metadata/caption receivers. Takes `CMReadySampleBuffer`, not
  `CMSampleBuffer`.
- `writer.start() throws` replaces `startWriting() -> Bool`.

Guidance: for **live capture**, suspending `append` is the wrong
semantics (backpressure should drop frames, not delay them) — use
`appendImmediately` or keep the classic `isReadyForMoreMediaData` +
`append` path. There is an open, unanswered forum report (thread 813867)
of `PixelBufferReceiver.append` suspending forever on iOS 26; if you use
the awaiting form in offline pipelines, add a timeout/cancellation path.
Don't migrate `ChunkRecorder` to these APIs without a concrete benefit and
on-device verification.

## Verifying changes

- The Mac harness doesn't reproduce iPhone capture timing. Test on device
  and pull the recorded chunks (`xcrun devicectl device copy from …`)
  before claiming a fix.
- Inspect a file: `AVURLAsset(url:)` → `load(.duration)`,
  `loadTracks(withMediaType:)`, and per-track `load(.timeRange)`; check
  audio and video ranges start and end together. `afinfo`/`mdls` give quick
  CLI checks; `ffprobe` isn't installed by default.
- Edge cases to exercise: phone call mid-recording, camera flip (frame size
  change → new writer), screen lock/background, nearly full disk, stop
  within a second of a cut.

## Sources

- AVAssetWriter docs: https://developer.apple.com/documentation/avfoundation/avassetwriter
- SampleBufferReceiver (iOS 26): https://developer.apple.com/documentation/avfoundation/avassetwriterinput/samplebufferreceiver
- WWDC20 10011, Author fragmented MPEG-4 content with AVAssetWriter: https://developer.apple.com/videos/play/wwdc2020/10011/
- DTS on concurrent appends: https://developer.apple.com/forums/thread/771616
- iOS 26 receiver hang report: https://developer.apple.com/forums/thread/813867
- Segment-data leak in Swift delegates: https://nonstrict.eu/blog/2023/avassetwriter-leaks-segment-data
