# Evii Frames

iPhone app for on-device frame interpolation and smooth slow motion. v0.1, Ukrainian UI, dark screen, one lime accent. The name is a placeholder.

Clips are limited to 30 seconds. Typical clips are 1–2 seconds, so the build spends its size on quality: several MIT RIFE checkpoints, fixed shapes through 4K, and an optional four-pass flip average. Nothing is uploaded. There is no App Store build and no paid Apple Developer account: GitHub Actions archives with `CODE_SIGNING_ALLOWED=NO` and zips `Payload/EviiFrames.app` into an unsigned `.ipa`. A tag `v*` also attaches that ipa to a GitHub Release. This branch is not tagged.

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

- **Apple VTFrameRateConversion** is used only when `VTFrameRateConversionConfiguration.isSupported` is true on that phone. The check is a runtime lookup, so an older SDK still links, and an iPhone 14 Pro on iOS 27 is not assumed to support it. v0.1 does not open a `VTFrameProcessor` session even when the flag is true; start keeps RIFE 4.25.
- **UHD** stores the toggle. In Practical-RIFE that flag is scale 0.5, which estimates motion on a coarser pyramid. It is not bundled. 4K uses its own packages instead.
- **A separate anime checkpoint** is not in the MIT release list. RIFE 4.25 is the one the author describes as improved on anime, and it stays the default.

## iPhone 14 Pro

The phone this build is aimed at is an iPhone 14 Pro: A16 Bionic, 6 GB of RAM, iOS 27. The deployment target stays iOS 17, `MinimumOSVersion` is 17.0, and there is no maximum system version, so iOS 27 can install it. `UIRequiredDeviceCapabilities` is `arm64`.

The default max resolution is 1080p so a 4K activation is not loaded unless the user raises the cap. Packages for every bundled model include 256×384 through 1080p and the 4K canvases 2176×3840 and 3840×2176, so a 4K frame is padded, not scaled down. Convolutions are FP16. The warp and the bilinear resize stay FP32 (`resample`); Core ML's own upsample did not match PyTorch. Rounding the weights to FP16 changes a smooth 6 px shift by about 0.00001 mean abs in PyTorch, under the 0.002 bar for shipping a second FP32 package. The loader tries the Neural Engine first (`cpuAndNeuralEngine`), then the GPU, then `.all`, then the CPU. 4K on 6 GB can still be killed by iOS; the resolution cap is the escape hatch.
- **Максимальна якість** runs the selected model four times (identity, horizontal flip, vertical flip, both) and averages. That is about four times slower. The checkpoint's own `ensemble` flag has been a no-op since RIFE 4.21, so this is test-time flip averaging, not a second network.
- The before/after control compares the poster still with the latest generated frame. It does not play the file at 0.25×. Playback is in Photos.
- Scene detection and dedup run on a 96×96 CPU luma plane (fast grid 8, accurate grid 24), not a Metal kernel.
- The phone can get hot. The pipeline pauses while the thermal state is serious or critical. There is no background GPU session. Leave the app open.

## Model

`tools/convert_rife425.py` downloads five Practical-RIFE checkpoints (MIT), checks each zip's sha256, and writes fixed-shape `mlprogram` packages (FP16 convs, FP32 resample). On a Mac it predicts every model at 256×384 against PyTorch on the smooth-shift pair, and it probes one FP32 package for 4.25. See [tools/README.md](tools/README.md). Packages are not in git. CI caches them, compiles with `coremlcompiler`, and copies the `.mlmodelc` into the app.

| Choice | Checkpoint | Graph |
| --- | --- | --- |
| RIFE 4.25 | Drive `1ZKjcbmt1hypiFprJPIKW0Tt0lr_2i7bg` | 5 blocks, scale 16…1, context 4. Default, anime note. |
| RIFE 4.26 | Drive `1gViYvvQrtETBgU1w8axZSsr7YUuw31uy` | Same graph, weights from 2024-09-21. |
| RIFE heavy | Drive `1vJy82jub1D9O8BZgjPeMu3HHx4bG-NY1` | 4.26 heavy, context 16. |
| RIFE lite | Drive `1zlKblGuKNatulJNFf5jdB-emp9AqGK05` | 4.25 lite, scale 32, 16, 8, 4, 1. |
| RIFE 4.22 | Drive `1qh2DSA9a1eZUTtZG9U9RQKO7N7OaUJ0_` | 4 wider blocks, scale 8…1. |

Simulator and Mac Core ML timings are printed as `EVII_BENCH` (one line per model) and `benchmark-macos.json`. They are not iPhone timings.

## Build

On a Mac, Xcode 16 or newer, iOS 17 simulator:

```bash
python3 -m pip install -r tools/requirements.txt
python3 tools/convert_rife425.py --sizes 256x384,1088x1920,1920x1088,2176x3840,3840x2176 --out build/models
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

The unsigned archive is the `ipa` job in `.github/workflows/ios.yml`. The artifact is `evii-frames-0.1.1` and the ipa inside it is `EviiFrames-0.1.1-unsigned.ipa`. The same job also zips a simulator `.app` (`EviiFrames-0.1.1-simulator.zip`, arm64 and x86_64 when the runner can link both) for Appetize.io. `build/simulator/ARCH.txt` is the `lipo` output.

## What CI actually runs

Hosted tests build short H.264 clips and run the real pipeline: ×2 / ×4 / ×8 / ×16, target fps, a max-fps cap, whole-clip and fragment slow motion, a scene cut, duplicate frames, loop, portrait and landscape, 30 and 60 fps, audio on and off, a trimmed window (audio must start at 0), HEVC, and ProRes when the simulator has the encoder. A 1 s and a 2 s clip finish at ×2. A 30 s clip and a 1080p 30 s ×8 clip are analysed and cancelled after the first interpolated frame. Those two check that full frames stay in a small cache and that `phys_footprint` stays under 5 GiB of the iPhone 14 Pro's 6 GB. They do not interpolate every 1080p frame. XCUITest taps the screens, including cancel, background/foreground, and the unsupported-file alert. Empty, audio-only, HDR (PQ), variable frame timing, and odd or tiny sizes are probed in the unit suite. `xcrun simctl io recordVideo` saves `screens-tour.mp4` and `ui-flows.mp4` next to the screenshots.

Simulator and Mac numbers are not iPhone 14 Pro timings. HDR is decoded as SDR BGRA. A real Dolby Vision bitstream is classified by fourcc, not generated here. If the simulator cannot encode HEVC or ProRes, the export falls back and the log says so.

## Встановлення через AltStore

1. Поставте AltServer на Mac або Windows з сайту AltStore.
2. На iPhone: Параметри → Приватність і безпека → Режим розробника → увімкніть і перезавантажте.
3. Підключіть iPhone кабелем, відкрийте AltServer і встановіть AltStore зі своїм безкоштовним Apple ID.
4. Завантажте `EviiFrames-0.1.1-unsigned.ipa` з артефакту GitHub Actions (або з релізу, коли з’явиться тег `v*`).
5. В AltStore натисніть «+» і виберіть цей ipa.

Безкоштовний Apple ID підписує застосунок на 7 днів і дозволяє до трьох застосунків. Щоб продовжити, відкрийте AltServer у тій самій мережі, що й iPhone, і оновіть застосунок в AltStore. App Store і платний акаунт не потрібні.
