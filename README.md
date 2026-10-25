# Evii Frames

iPhone app for on-device frame interpolation and smooth slow motion. v0.1, Ukrainian UI, dark screen, one lime accent. The name is a placeholder.

Clips are limited to 30 seconds. Typical clips are 1–2 seconds, so the default model is RIFE 4.25 rather than a smaller network. Nothing is uploaded. There is no App Store build and no paid Apple Developer account: GitHub Actions archives with `CODE_SIGNING_ALLOWED=NO` and zips `Payload/EviiFrames.app` into an unsigned `.ipa`. A tag `v*` also attaches that ipa to a GitHub Release. This branch is not tagged.

## What v0.1 does

- Pick one or several videos from Photos. The picker copies the file. Anything past 30 seconds is trimmed to the first 30.
- Show resolution, frame rate, duration, frame count, codec, and size.
- Slow motion of the whole clip or a fragment, at ×2 / ×4 / ×8 (0.5× / 0.25× / 0.125×) while the file stays at the source frame rate. Audio on the slowed range is muted by default. "Розтягнути" repeats samples, so the pitch drops. It is not a time-pitch effect.
- Interpolation at ×2 / ×4 / ×8 / ×16 or a target frame rate, with a max frame-rate cap and a max resolution cap (original / 4K / 1080p / 720p).
- Scene-change detection. Across a cut the planner repeats the previous frame instead of blending.
- Duplicate-frame removal for anime: off, fast, or accurate, plus a threshold. The output timeline stays even, so playback speed does not jump.
- Loop interpolation from the last frame back to the first, unless that pair is a scene cut.
- Export HEVC or H.264, MP4 or MOV, quality slider, optional audio and metadata, a minimum duration that repeats the cycle, and a filename pattern.
- ProRes 422 only when `AVAssetWriter` accepts it (Pro iPhones). Otherwise the control explains that it is unavailable.
- Processing screen: Аналіз → Інтерполяція → Кодування, frame counter, rate, ETA. Stepwise mode pauses after analysis.
- A queue runs several clips one after one.
- Done screen: before/after stills, save to Photos, share, edit again.
- The pipeline is `AVAssetReader` → Core ML → `AVAssetWriter`. Analysis keeps a coarse luma grid. Interpolation keeps only the frames the current pair needs.

## What is stubbed

- **RIFE lite** is a visible option and is not selectable as an engine. Start uses RIFE 4.25. TODO: a smaller traced package.
- **Apple VTFrameRateConversion** is used only when `VTFrameRateConversionConfiguration.isSupported` is true on that phone. The check is a runtime lookup, so an older SDK still links, and an iPhone 14 Pro on iOS 27 is not assumed to support it. v0.1 does not open a `VTFrameProcessor` session even when the flag is true; start keeps RIFE 4.25.
- **UHD** stores the toggle. The official scale-0.5 pyramid is not in the app. `tools/convert_rife425.py --uhd` can trace it; v0.1 does not bundle it. 4K is scaled into the 1080p package.

## iPhone 14 Pro

The phone this build is aimed at is an iPhone 14 Pro: A16 Bionic, 6 GB of RAM, iOS 27. The deployment target stays iOS 17, `MinimumOSVersion` is 17.0, and there is no maximum system version, so iOS 27 can install it. `UIRequiredDeviceCapabilities` is `arm64`.

The default max resolution is 1080p. Packages stop at 1088×1920 and 1920×1088. Convolutions are FP16 so a 1080p frame fits in 6 GB. The warp and the bilinear resize stay FP32 (`resample`); Core ML's own upsample did not match PyTorch. The loader tries the Neural Engine first (`cpuAndNeuralEngine`), then the GPU, then `.all`, then the CPU. A 4K activation is not loaded.
- **FP32** stores the toggle. It does not swap in a full-float package.
- The before/after control compares the poster still with the latest generated frame. It does not play the file at 0.25×. Playback is in Photos.
- Scene detection and dedup run on a 96×96 CPU luma plane (fast grid 8, accurate grid 24), not a Metal kernel.
- The phone can get hot. The pipeline pauses while the thermal state is serious or critical. There is no background GPU session. Leave the app open.

## Model

`tools/convert_rife425.py` downloads Practical-RIFE 4.25, checks sha256 `e63d481b7ae5d4a4e6ad7ac5b410ff78f3bf7be3b51b2e38ca8152747abde5b4`, and writes fixed-shape `mlprogram` packages (FP16 convs, FP32 resample). See [tools/README.md](tools/README.md). Packages are not in git. CI caches them, compiles with `coremlcompiler`, and copies the `.mlmodelc` into the app.

Simulator and Mac Core ML timings are printed as `EVII_BENCH` and `benchmark-macos.json`. They are not iPhone timings.

## Build

On a Mac, Xcode 16 or newer, iOS 17 simulator:

```bash
python3 -m pip install -r tools/requirements.txt
python3 tools/convert_rife425.py --sizes 256x384,1088x1920,1920x1088 --out build/models
mkdir -p EviiFrames/Resources/Models
for package in build/models/*.mlpackage; do
  xcrun coremlcompiler compile "$package" EviiFrames/Resources/Models
done
brew install xcodegen
xcodegen generate
xcodebuild test -project EviiFrames.xcodeproj -scheme EviiFrames \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```

The unsigned archive is the `ipa` job in `.github/workflows/ios.yml`. The same job also zips a simulator `.app` (`EviiFrames-0.1.0-simulator.zip`, arm64 and x86_64 when the runner can link both) for Appetize.io. `build/simulator/ARCH.txt` is the `lipo` output.

## What CI actually runs

Hosted tests build short H.264 clips and run the real pipeline: ×2 / ×4 / ×8 / ×16, target fps, a max-fps cap, whole-clip and fragment slow motion, a scene cut, duplicate frames, loop, portrait and landscape, 30 and 60 fps, audio on and off, a trimmed window (audio must start at 0), HEVC, and ProRes when the simulator has the encoder. A 1 s and a 2 s clip finish at ×2. A 30 s clip and a 1080p 30 s ×8 clip are analysed and cancelled after the first interpolated frame. Those two check that full frames stay in a small cache and that `phys_footprint` stays under 5 GiB of the iPhone 14 Pro's 6 GB. They do not interpolate every 1080p frame. XCUITest taps the screens, including cancel, background/foreground, and the unsupported-file alert. Empty, audio-only, HDR (PQ), variable frame timing, and odd or tiny sizes are probed in the unit suite. `xcrun simctl io recordVideo` saves `screens-tour.mp4` and `ui-flows.mp4` next to the screenshots.

Simulator and Mac numbers are not iPhone 14 Pro timings. HDR is decoded as SDR BGRA. A real Dolby Vision bitstream is classified by fourcc, not generated here. If the simulator cannot encode HEVC or ProRes, the export falls back and the log says so.

## Встановлення через AltStore

1. Поставте AltServer на Mac або Windows з сайту AltStore.
2. На iPhone: Параметри → Приватність і безпека → Режим розробника → увімкніть і перезавантажте.
3. Підключіть iPhone кабелем, відкрийте AltServer і встановіть AltStore зі своїм безкоштовним Apple ID.
4. Завантажте `EviiFrames-0.1.0-unsigned.ipa` з артефакту GitHub Actions (або з релізу, коли з’явиться тег `v*`).
5. В AltStore натисніть «+» і виберіть цей ipa.

Безкоштовний Apple ID підписує застосунок на 7 днів і дозволяє до трьох застосунків. Щоб продовжити, відкрийте AltServer у тій самій мережі, що й iPhone, і оновіть застосунок в AltStore. App Store і платний акаунт не потрібні.
