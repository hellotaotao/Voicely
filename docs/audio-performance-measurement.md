# Audio callback performance baseline

The `AudioTapPerformance` signposts are compiled into DEBUG builds only. They do
not change mixing, conversion, file writes, locking, or stop/drain behavior.
Release builds contain no tap instrumentation.

## Capture

1. Install a Debug build on a real iPhone. Start Instruments with Points of
   Interest (or the os_signpost instrument), Time Profiler, and Allocations as
   appropriate. Attach to the running Voicely process. The default Xcode Profile
   action normally builds Release; use a Debug configuration for this capture.
2. Filter signposts to subsystem `com.hellotaotao.Voicely`, category
   `AudioTapPerformance`, interval `AudioTap`.
3. Capture at least five minutes each of recording only and recording with live
   transcription. Include pause/resume and stop. Repeat with the input routes
   actually supported by the device; record route, sample rate, thermal state,
   device/OS, build, and whether transcription is enabled alongside the trace.
4. For meeting-length behavior, capture a 30-60 minute session and compare early
   and late windows. Use the same device, route, and workload for before/after
   comparisons.
5. Report callback count, p50/p95/p99/max interval duration, events named
   `AudioTapExceededBufferPeriod`, peak memory, allocations attributable to the
   callback stack, and any independently observed audible gaps or audio-engine
   errors. Check the saved file's duration and tail separately.

## Interpretation and overhead

`AudioTap` covers channel mixing, acquiring the write-target lock, sample-rate
conversion, synchronous file writing, RMS calculation, and shared-state update.
Early-return and paused callbacks are included. It excludes input delivery delay,
engine setup/teardown, post-stop M4A export, and downstream transcription.

The event compares measured elapsed callback time with
`inputBuffer.frameLength / inputBuffer.format.sampleRate`, using the actual
buffer length rather than the requested tap size. Its payload contains only
elapsed nanoseconds, frame count, and sample rate: no audio, transcript, note IDs,
or file paths. An event is a useful expensive-callback signal, **not proof of a
hardware deadline miss or lost samples**. The absence of events does not prove
lossless recording either.

The log is created before installing the tap. Each DEBUG callback first checks
`OSLog.signpostsEnabled`; disabled callbacks do not read a clock or create a signpost
ID. Enabled measurement adds signpost and clock overhead on the callback thread.
The budget comparison includes begin-signpost overhead but excludes the end and
optional event emission. Compare an uninstrumented Release session when assessing
user-visible performance. Do not interpret instrumentation results as zero-cost.

Do not change to asynchronous writes or reuse conversion buffers solely from
static inspection. Require captured allocation/callback evidence and regression
coverage for channels, varying buffer lengths, pause/resume, stop drainage, and
saved audio completeness before changing that contract.
