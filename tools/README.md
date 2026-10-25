# Practical-RIFE → Core ML

The app bundles five [Practical-RIFE](https://github.com/hzwer/Practical-RIFE) checkpoints (MIT, hzwer). The script downloads each published zip, checks sha256, and writes one `mlpackage` per input size. Convolutions are FP16. Bilinear resize and the warp are FP32 `resample` ops, because Core ML `upsample_bilinear` does not match PyTorch `interpolate`.

There is no separate permissive anime checkpoint. RIFE 4.25 is the release the author describes as improved on anime, and it is the default. RIFE 4.26 uses that same 5-block graph with newer weights. RIFE 4.26 heavy widens the context head from 4 channels to 16. RIFE 4.25 lite narrows the last block and uses scale `32, 16, 8, 4, 1`. RIFE 4.22 is the four-block network aimed at diffusion video. Nothing here is GPL.

## Why one file per size

`coremltools` 9 cannot convert this graph with a flexible or enumerated shape. The bilinear upsample is traced with a float output size (`recompute_scale_factor = False, align_corners = False with float output size is not supported`). iOS 17 also allows only one enumerated input. Fixed traces avoid both limits.

Each height and width is a multiple of 64, which is also a multiple of 32, so every pyramid above lands on integers. The Swift side pads with edge replication into the smallest package that contains the frame, then crops back. The set is:

- 256×384 and 384×256
- 384×640 and 640×384
- 512×896 and 896×512
- 768×1280 and 1280×768
- 1088×1920 and 1920×1088 (1080p). RIFE lite uses 1152×1920 and 1920×1152 here: its scale-32 pyramid only returns to the frame when both axes are multiples of 128, and 1088 is not. The app still targets the 1080p cap and pads into the larger lite package.
- 2176×3840 and 3840×2176 (4K, 2160 padded to the next multiple of 64)

The default export cap stays 1080p. Choosing 4K or original does not scale a 4K frame down into 1088×1920. A 4K activation can still be too large for an iPhone 14 Pro (A16, 6 GB); the cap is how you stay inside that.

Sizes above 1088×1920 are traced in one process and converted in a second process. MKLDNN is off. A single process that does both, or a parent that keeps the traced net resident while converting, exceeds a 14 GB runner.

The official UHD flag is scale 0.5. v0.1.1 does not ship that coarser pyramid.

## Precision

Inputs and the output stay float32. Unset dtype plus a FLOAT16 compute policy publishes FLOAT16 inputs, and a float32 buffer is then read as half-precision bits.

Conv compute is FP16. `resample` stays FP32. On the smooth 6 px shift, rounding these weights to FP16 moves the PyTorch output by about 0.00001 mean abs. The Mac build also compiles one 256×384 FP32 package for RIFE 4.25 and keeps FP32 for every size only when that probe is more than 0.002 mean abs closer to PyTorch. Weights are not palettized.

`Максимальна якість` does not change the package. It runs four flips of the loaded model and averages them. Official `ensemble=True` has printed "not supported since RIFEv4.21" and is not traced in.

## Reproduce

```bash
python3 -m pip install -r tools/requirements.txt
python3 tools/convert_rife425.py --check-only
python3 tools/convert_rife425.py --out build/models
# one model, a few sizes:
python3 tools/convert_rife425.py --models rife425,rife426heavy --sizes 256x384,2176x3840
```

Pinned zips (Google Drive id, sha256). If Drive returns an HTML interstitial, the same bytes are fetched from the Hugging Face mirror `Bash2X/RIFE-Models`.

| id | drive id | sha256 |
| --- | --- | --- |
| rife425 | `1ZKjcbmt1hypiFprJPIKW0Tt0lr_2i7bg` | `e63d481b7ae5d4a4e6ad7ac5b410ff78f3bf7be3b51b2e38ca8152747abde5b4` |
| rife426 | `1gViYvvQrtETBgU1w8axZSsr7YUuw31uy` | `c2452dd2b244947d4be580156bbead60d6b72af5736860f7d6b3f99648c9c4cc` |
| rife426heavy | `1vJy82jub1D9O8BZgjPeMu3HHx4bG-NY1` | `93c0ec3dce359930059c1cc6733cff1d0c075314e30d352864436023bfc13463` |
| rife425lite | `1zlKblGuKNatulJNFf5jdB-emp9AqGK05` | `e84366c23e0eb1a637a55aad2e4f3442ec2bf4c388043b4aabbf590be289e6e8` |
| rife422 | `1qh2DSA9a1eZUTtZG9U9RQKO7N7OaUJ0_` | `466dfd5f310c5c32ed12904d0e22bfc2f793f17e41808353d4378bbe2c60cb9c` |

- torch `2.7.0` (2.14 is too new for coremltools 9)
- coremltools `9.0`
- deployment target iOS 17
- inputs `frame0`, `frame1` as float32 `1×3×H×W`, `timestep` as float32 `1×1×1×1`
- output `output` as float32

`--check-only` loads every checkpoint, requires timestep 0 to stay within 0.02 mean abs of frame 0, and requires the grid_sample resize to match `F.interpolate` within 0.0001 on the smooth pair. On macOS each 256×384 package is predicted on CPU, CPU+GPU, and all compute units. The pass/fail gate is that smooth pair (mean abs at t=0.5 ≤ 0.02, t=0 ≤ 0.01). A white-noise pair is printed too; its t=0.5 error stays large because uncorrelated pixels exaggerate sub-pixel flow differences, and it does not fail the build. RIFE 4.25 at `1088×1920` gets one CPU+GPU timing. Results go to `build/models/benchmark-macos.json`. Those times are Core ML on the Mac, not on an iPhone. Linux cannot execute the packages (`libcoremlpython` is missing); CI compiles them with `xcrun coremlcompiler` and times the smallest package of each model in the iOS Simulator. Simulator times are also not iPhone times.

Teacher and `caltime` tensors are training-only and are dropped. `module.` is stripped, then the keys are loaded into `RIFE.net`.
