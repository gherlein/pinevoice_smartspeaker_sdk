# PineVoice — enabling continuous ("always-stream") audio

How to build and flash a PineVoice firmware variant that streams microphone PCM
**continuously** over Wyoming, instead of only after the "hey jarvis" wake word.
This is sub-project #2 in [`../VISION.md`](../VISION.md).

## TL;DR

The Wyoming satellite library the firmware uses (`gamelaster/wyoming_c_satellite`)
picks its streaming mode automatically:

```c
// wyoming_c_satellite/lib/satellite.c
if (inst->wake != NULL) inst->mode = &wsat_mode_wake_stream;   // wake-gated
else                    inst->mode = &wsat_mode_always_stream; // continuous
```

So the entire change is **not registering a wake component**: comment out the one
`wsat_wake_set(&wake);` call in the E907 firmware, rebuild, and flash. No new
capture code is required — the microphone already delivers PCM every frame; the
factory firmware simply gates *sending* it until wake.

## Background: how the audio path works

The PineVoice is a dual-core BL606P. Audio flows like this
(`solutions/pinevoice_fw_e907/app/src/wyoming/wyoming.c`):

- `wyoming_init()` starts the mic subsystem (`aui_mic_start()`), and the
  microphone component's `mic_init()` issues `aui_mic_control(MIC_CTRL_START_PCM)`
  — raw PCM then flows **continuously** as `MIC_EVENT_PCM_DATA` callbacks
  (320-byte frames = 10 ms of 16 kHz / 16-bit / mono).
- Each frame is buffered and pushed to the library via `wsat_mic_write_data()`,
  **regardless of mode**. The library's mode handler decides whether to actually
  put it on the wire:
  - `wake_stream` mode: holds until a wake detection.
  - `always_stream` mode: after the client sends `run-satellite`, forwards
    **every** chunk (`wsat_audio_chunk_send`) until `pause-satellite`/disconnect.
- The on-device wake word ("hey jarvis") is detected on the C906 DSP core and
  surfaces as `MIC_EVENT_SESSION_START`; it is independent of the raw PCM stream.

Consequence for the collector: **each PineVoice emits one processed mono stream**
(16 kHz, 16-bit, 1 channel — see the `mic` struct: `{16000, 2, 1}`), *not* the raw
2-mic + reference signal. The DSP does the AEC/beamforming and hands you one
channel. Cross-*device* zone attribution (3 devices = 3 streams) still works;
per-device raw-mic comparison is not available at this layer.

## Prerequisites

Follow the SDK's own build environment first
([`pinevoice_smartspeaker_sdk` README](https://github.com/pine64/pinevoice_smartspeaker_sdk)):

1. Clone **recursively** (the satellite lib and firmware are submodules):
   ```bash
   git clone --recursive https://github.com/pine64/pinevoice_smartspeaker_sdk
   ```
2. Download the Bouffalo Dev Cube flashtool and place it in `tools/flashtool/`:
   <http://files.pine64.org/tools/bouffalo/bflb_flashtool_bl606p_v190.tar.gz>
3. Use the provided dev container (VS Code Dev Container, or build/run
   `.devcontainer/Dockerfile`). Expose the PineVoice `/dev/tty*` into the
   container (edit `.devcontainer/devcontainer.json`).

All commands below run **inside** that container.

## The change

Edit `solutions/pinevoice_fw_e907/app/src/wyoming/wyoming.c`, function
`wyoming_server()` (around line 292).

**Before:**
```c
static void wyoming_server(void *arg)
{
  wsat_init();
  wsat_settings_set(WSAT_SETTING_TYPE_SATELLITE_NAME, "PineVoice");
  wsat_settings_set(WSAT_SETTING_TYPE_SATELLITE_VERSION, DEFAULT_SOFTWARE_VER);
  wsat_mic_set(&mic);
  wsat_snd_set(&snd);
  wsat_wake_set(&wake);          // <-- registering wake selects wake_stream mode
  wsat_fback_set(&fback);
  wsat_run();
}
```

**After** — omit the wake registration so the library falls into `always_stream`:
```c
static void wyoming_server(void *arg)
{
  wsat_init();
  wsat_settings_set(WSAT_SETTING_TYPE_SATELLITE_NAME, "PineVoice");
  wsat_settings_set(WSAT_SETTING_TYPE_SATELLITE_VERSION, DEFAULT_SOFTWARE_VER);
  wsat_mic_set(&mic);
  wsat_snd_set(&snd);
  // wsat_wake_set(&wake);       // omit: no wake component -> always_stream mode
  wsat_fback_set(&fback);
  wsat_run();
}
```

That is the whole functional change.

### Two small cleanups

- **Unused `wake` struct.** With the call removed, the static `wake` definition
  (the `struct wsat_wake wake = {...}` near line 57) is no longer referenced. If
  the build runs with `-Werror`/`-Wunused-variable`, also comment out that struct.
- **The `wsat_wake_detection()` call stays and is safe.** `mic_evt_cb()` still
  calls it when the DSP fires the on-device "hey jarvis"; in `always_stream` mode
  the mode handler ignores `WSAT_SYS_EVENT_WAKE_DETECTION` (it only acts on mic
  data and disconnect), so the sole effect is a brief light-show flash. No action
  needed unless you want to suppress that (see Optional, below).

## Build

The E907 firmware depends on a compiled C906 core image, so build C906 first.
From the SDK root, inside the container:

```bash
# 1. C906 DSP core
cd solutions/pinevoice_fw_c906
./go

# 2. E907 main firmware
cd ../pinevoice_fw_e907
./go            # full build
# or, for a faster iteration build during development:
./build.sh
```

`./build.sh full` also rebuilds C906 first, so after the initial `./go` you can
iterate on `wyoming.c` with just `./build.sh`. Output lands in the solution's
build tree as `yoc_rfpa.bin` (used by the flash step).

## Flash

1. **Enter flash mode:** turn the PineVoice **off**, hold the **center ring
   button**, then turn it **on** while still holding. There is a short timeout, so
   be ready to run the next command immediately.
2. From `solutions/pinevoice_fw_e907`:
   ```bash
   ./flash.sh              # flash firmware only
   ./flash.sh cli          # flash, then open the serial console
   ./flash.sh - full       # also flash media/mfg data (first-time / full image)
   ```
   `flash.sh` auto-detects the PineVoice `/dev/tty*`. Add `cli` as the first
   argument to drop into the device console at 2000000 baud after flashing.

## Verify

1. **Describe it** with gowyoming — confirms the satellite is up and reports mic
   format `16000 / 2 / 1`:
   ```bash
   go run ./cmd/wyoming-info --uri tcp://<pinevoice-ip>:10700
   ```
2. **Confirm continuous streaming.** In `always_stream` mode the device streams
   only after the client sends `run-satellite`. Connect, send `run-satellite`, and
   you should receive `audio-chunk` events **immediately and continuously**,
   without speaking a wake word. The gowyoming collector (sub-project #1) is the
   real test harness; `examples/satellite-record` can be adapted to send
   `run-satellite` and capture the continuous stream.
3. If nothing streams, check that a client actually sent `run-satellite`
   (streaming stays paused until then) and that the device shows a connected
   client.

## Optional: fully silence the on-device wake engine

Leaving the C906 wake engine (`microwakeword`) running wastes power and still
flashes the ring on "hey jarvis," even though it no longer gates the stream. To
remove it entirely you must change the **C906** solution
(`solutions/pinevoice_fw_c906`) so the wake algorithm is not started, and drop the
`microwakeword` dependency in its `package.yaml`. This is a larger, DSP-side
change and is **not required** for continuous streaming — treat it as a later
power/cleanliness optimization, not part of the minimal always-stream build.

## What is still unverified (hardware)

- Sustained continuous PCM over a full-length meeting without thermal/power or
  buffer-overrun issues (`mic_evt_cb` logs `"Data not processed"` if the streamer
  task falls behind — watch for it).
- Behavior of `run-satellite`/`pause-satellite` and reconnect over long sessions.
- Whether Wi-Fi throughput on the BL606P comfortably sustains 3 devices' worth of
  16 kHz mono PCM to the collector on the same network.

## Source references

- Mode selection: `wyoming_c_satellite/lib/satellite.c` (`wsat_run`)
- Continuous forwarding: `wyoming_c_satellite/lib/satellite_mode_always_stream.c`
- Firmware wiring: `solutions/pinevoice_fw_e907/app/src/wyoming/wyoming.c`
- Build/flash: `pinevoice_smartspeaker_sdk` README, `solutions/pinevoice_fw_e907/{go,build.sh,flash.sh,Makefile}`
