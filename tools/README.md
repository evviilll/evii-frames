# RIFE 4.25 → Core ML

The app runs [Practical-RIFE](https://github.com/hzwer/Practical-RIFE) 4.25 (MIT, hzwer). This script downloads the published `train_log` zip, checks the weights, and writes one FP16 `mlprogram` per input size.

## Why one file per size

`coremltools` 9 cannot convert this graph with a flexible or enumerated shape. The bilinear upsample is traced with a float output size (`recompute_scale_factor = False, align_corners = False with float output size is not supported`). iOS 17 also allows only one enumerated input. Fixed traces avoid both limits.

Each height and width is a multiple of 64. That matches scale list `16, 8, 4, 2, 1` plus the block's own stride-2. The Swift side pads with edge replication into the smallest package that contains the frame, then crops back. 4K is scaled into `1088×1920` or `1920×1088`.

`--uhd` traces the official half-resolution pyramid (`32, 16, 8, 4, 2`). v0.1 does not ship that graph. The UHD switch in the app only records the choice.

## Reproduce

```bash
python3 -m pip install -r tools/requirements.txt
python3 tools/convert_rife425.py --check-only
python3 tools/convert_rife425.py --out build/models
# optional subset:
python3 tools/convert_rife425.py --sizes 256x384,1088x1920,1920x1088
```

Pinned inputs:

- Drive file `1ZKjcbmt1hypiFprJPIKW0Tt0lr_2i7bg`
- sha256 `e63d481b7ae5d4a4e6ad7ac5b410ff78f3bf7be3b51b2e38ca8152747abde5b4`
- torch `2.7.0` (2.14 is too new for coremltools 9)
- coremltools `9.0`
- compute precision FP16, deployment target iOS 17
- inputs `frame0`, `frame1` as float32 `1×3×H×W`, `timestep` as float32 `1×1×1×1`
- output `output`

`--check-only` runs PyTorch at 256×384 with timestep 0 and requires mean absolute error under 0.02 against the first frame. On macOS the script also predicts each package and writes `build/models/benchmark-macos.json`. Those times are Core ML on the Mac, not on an iPhone. Linux cannot execute the packages (`libcoremlpython` is missing); CI compiles them with `xcrun coremlcompiler` and times the smallest one in the iOS Simulator. Simulator times are also not iPhone times.

Teacher and `caltime` tensors in the checkpoint are training-only and are dropped. `module.` is stripped, then the keys are loaded into `RIFE425.net` with `strict=True`.
