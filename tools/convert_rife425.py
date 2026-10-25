#!/usr/bin/env python3
"""Download Practical-RIFE 4.25 and export fixed-shape Core ML packages.

The official graph uses bilinear upsample whose output size is a Python float
when the input shape is dynamic. coremltools rejects that
("recompute_scale_factor = False ... with float output size"). Enumerated
shapes also fail below iOS 18 when more than one input is enumerated, and a
single RangeDim still hits the same upsample op.

Each package is therefore traced at one HxW. Both axes are multiples of 64
(scale list 16, and the block's own stride-2 twice). The app pads a frame
into the smallest containing package and crops the result back.

Weights: Practical-RIFE train_log (MIT, https://github.com/hzwer/Practical-RIFE),
Google Drive id 1ZKjcbmt1hypiFprJPIKW0Tt0lr_2i7bg.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import platform
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from rife425_net import RIFE425  # noqa: E402

DRIVE_ID = "1ZKjcbmt1hypiFprJPIKW0Tt0lr_2i7bg"
ZIP_SHA256 = "e63d481b7ae5d4a4e6ad7ac5b410ff78f3bf7be3b51b2e38ca8152747abde5b4"
DEFAULT_SIZES = [
    (256, 384),
    (384, 256),
    (384, 640),
    (640, 384),
    (512, 896),
    (896, 512),
    (768, 1280),
    (1280, 768),
    (1088, 1920),
    (1920, 1088),
]


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_zip(dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and sha256(dest) == ZIP_SHA256:
        print(f"weights cache ok {dest}")
        return
    url = f"https://drive.google.com/uc?export=download&id={DRIVE_ID}"
    print(f"downloading {url}")
    tmp = dest.with_suffix(".partial")
    urllib.request.urlretrieve(url, tmp)
    digest = sha256(tmp)
    if digest != ZIP_SHA256:
        tmp.unlink(missing_ok=True)
        raise SystemExit(f"sha256 mismatch: {digest} != {ZIP_SHA256}")
    tmp.replace(dest)


def load_weights(zip_path: Path, cache_dir: Path) -> dict:
    pkl = cache_dir / "flownet.pkl"
    if not pkl.exists():
        with zipfile.ZipFile(zip_path) as archive:
            archive.extract("train_log/flownet.pkl", cache_dir)
        extracted = cache_dir / "train_log" / "flownet.pkl"
        extracted.replace(pkl)
    state = torch.load(pkl, map_location="cpu", weights_only=False)
    clean = {}
    for key, value in state.items():
        if key.startswith("module."):
            key = key[len("module.") :]
        if key.startswith("teacher.") or key.startswith("caltime."):
            continue
        clean["net." + key] = value
    return clean


def build_net(weights: dict, uhd: bool) -> torch.nn.Module:
    net = RIFE425(uhd=uhd).eval()
    missing, unexpected = net.load_state_dict(weights, strict=False)
    if missing or unexpected:
        raise SystemExit(f"weight mismatch missing={missing[:8]} unexpected={unexpected[:8]}")
    return net


def endpoint_check(net: torch.nn.Module) -> float:
    torch.manual_seed(0)
    image = torch.rand(1, 3, 256, 384)
    with torch.no_grad():
        output = net(image, image.clone(), torch.zeros(1, 1, 1, 1))
    error = (output - image).abs().mean().item()
    print(f"pytorch t=0 mean abs {error:.6f} at 256x384")
    if error > 0.02:
        raise SystemExit("endpoint check failed: t=0 should stay close to frame0")
    return error


def parse_sizes(text: str | None) -> list[tuple[int, int]]:
    if not text:
        return list(DEFAULT_SIZES)
    sizes = []
    for part in text.split(","):
        part = part.strip().lower()
        if not part:
            continue
        h, w = part.split("x")
        sizes.append((int(h), int(w)))
    return sizes


def convert_one(net: torch.nn.Module, height: int, width: int, out_dir: Path, uhd: bool) -> dict:
    import coremltools as ct

    example0 = torch.rand(1, 3, height, width)
    example1 = torch.rand(1, 3, height, width)
    timestep = torch.tensor([[[[0.5]]]])
    print(f"trace {height}x{width}")
    traced = torch.jit.trace(net, (example0, example1, timestep))
    print(f"convert {height}x{width}")
    started = time.perf_counter()
    # Float32 interface. Convs are FP16 so a 1080p frame fits an iPhone 14 Pro
    # (6 GB). Every resample stays FP32: bilinear resize and the warp both go
    # through grid_sample. Core ML upsample_bilinear did not match PyTorch
    # (t=0.5 mean abs 0.197 on CPU, GPU, and the Neural Engine).
    float32 = np.float32

    def fp16_selector(op) -> bool:
        return op.op_type != "resample"

    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="frame0", shape=example0.shape, dtype=float32),
            ct.TensorType(name="frame1", shape=example1.shape, dtype=float32),
            ct.TensorType(name="timestep", shape=(1, 1, 1, 1), dtype=float32),
        ],
        outputs=[ct.TensorType(name="output", dtype=float32)],
        convert_to="mlprogram",
        compute_precision=ct.transform.FP16ComputePrecision(op_selector=fp16_selector),
        minimum_deployment_target=ct.target.iOS17,
    )
    tag = "UHD" if uhd else "RIFE425"
    path = out_dir / f"{tag}_{height}x{width}.mlpackage"
    model.save(str(path))
    elapsed = time.perf_counter() - started
    record = {
        "file": path.name,
        "height": height,
        "width": width,
        "seconds_convert": round(elapsed, 3),
        "compute_precision": "fp16-conv-fp32-resample",
        "deployment_target": "iOS17",
    }
    if platform.system() == "Darwin" and height * width <= 256 * 384:
        record["checks"] = [
            predict_check(path, net, height, width, unit)
            for unit in ("cpuOnly", "cpuAndGPU", "all")
        ]
        good = [item for item in record["checks"] if numeric_ok(item)]
        record["acceptable_units"] = [item["compute_unit"] for item in good]
        # The default Core ML device (ALL) can run resample on the Neural Engine,
        # which previously disagreed with PyTorch at t=0.5 while t=0 still looked fine.
        # CPU or CPU+GPU must match. ALL is recorded and is not the gate.
        if not any(unit in ("cpuOnly", "cpuAndGPU") for unit in record["acceptable_units"]):
            raise SystemExit(f"numeric check failed for {height}x{width}: {json.dumps(record['checks'])}")
        chosen = next(item for item in record["checks"] if item["compute_unit"] == "cpuAndGPU")
        record.update({k: chosen[k] for k in ("t0_mean_abs", "mean_abs", "max_abs", "seconds_per_frame")})
    elif platform.system() == "Darwin" and (height, width) == (1088, 1920):
        try:
            timed = predict_check(path, net, height, width, "cpuAndGPU")
            record["timing"] = timed
        except Exception as exc:  # noqa: BLE001 — timing must not hide a good small-model check
            record["timing_error"] = str(exc)
    elif platform.system() != "Darwin":
        record["predict"] = "skipped"
        record["predict_note"] = "Linux coremltools cannot load libcoremlpython. Verify on macOS."
    print(json.dumps(record))
    return record


def numeric_ok(item: dict) -> bool:
    # The gate is the smooth 6 px shift, which is what a video frame looks like.
    # On that pair the Mac run matched PyTorch to ~0.0005 at t=0.5.
    # White-noise t=0.5 stays near 0.19: a sub-pixel flow difference makes
    # uncorrelated neighbors disagree, and that number is recorded only.
    return (
        item.get("t0_mean_abs", 1) <= 0.03
        and item.get("smooth_t0_mean_abs", 1) <= 0.01
        and item.get("smooth_mean_abs", 1) <= 0.02
    )


def predict_check(path: Path, net: torch.nn.Module, height: int, width: int, compute_unit: str) -> dict:
    import coremltools as ct

    unit = {
        "cpuOnly": ct.ComputeUnit.CPU_ONLY,
        "cpuAndGPU": ct.ComputeUnit.CPU_AND_GPU,
        "all": ct.ComputeUnit.ALL,
    }[compute_unit]
    model = ct.models.MLModel(str(path), compute_units=unit)
    torch.manual_seed(1)
    frame0 = torch.rand(1, 3, height, width)
    frame1 = torch.rand(1, 3, height, width)
    smooth0, smooth1 = smooth_shift(height, width, shift=6)
    half = torch.full((1, 1, 1, 1), 0.5)
    zero = torch.zeros(1, 1, 1, 1)
    spec = model.get_spec()
    io_dtype = int(spec.description.input[0].type.multiArrayType.dataType)

    def run(left: torch.Tensor, right: torch.Tensor, timestep: torch.Tensor):
        started = time.perf_counter()
        predicted = model.predict(
            {
                "frame0": np.ascontiguousarray(left.numpy(), dtype=np.float32),
                "frame1": np.ascontiguousarray(right.numpy(), dtype=np.float32),
                "timestep": np.ascontiguousarray(timestep.numpy(), dtype=np.float32),
            }
        )["output"]
        seconds = time.perf_counter() - started
        return np.asarray(predicted, dtype=np.float32), seconds

    def measure(left: torch.Tensor, right: torch.Tensor, label: str):
        with torch.no_grad():
            reference = net(left, right, half).numpy()
            endpoint = net(left, right, zero).numpy()
        at_half, seconds = run(left, right, half)
        at_zero, _ = run(left, right, zero)
        delta = np.abs(at_half - reference)
        endpoint_delta = np.abs(at_zero - left.numpy())
        torch_endpoint = float(np.abs(endpoint - left.numpy()).mean())
        print(
            f"numeric {height}x{width} {compute_unit} {label} io_dtype={io_dtype} "
            f"pred_shape={tuple(at_half.shape)} ref_shape={tuple(reference.shape)} "
            f"t0_mean={float(endpoint_delta.mean()):.5f} t05_mean={float(delta.mean()):.5f}"
        )
        return {
            "t0_mean_abs": float(endpoint_delta.mean()),
            "t0_max_abs": float(endpoint_delta.max()),
            "mean_abs": float(delta.mean()),
            "max_abs": float(delta.max()),
            "torch_endpoint_mean_abs": torch_endpoint,
            "seconds_per_frame": round(seconds, 4),
        }

    random_pair = measure(frame0, frame1, "random")
    smooth_pair = measure(smooth0, smooth1, "smooth")
    return {
        "predict": "ok",
        "io_dtype": io_dtype,
        "pred_shape": [1, 3, height, width],
        "t0_mean_abs": random_pair["t0_mean_abs"],
        "t0_max_abs": random_pair["t0_max_abs"],
        "mean_abs": random_pair["mean_abs"],
        "max_abs": random_pair["max_abs"],
        "torch_endpoint_mean_abs": random_pair["torch_endpoint_mean_abs"],
        "smooth_t0_mean_abs": smooth_pair["t0_mean_abs"],
        "smooth_mean_abs": smooth_pair["mean_abs"],
        "smooth_max_abs": smooth_pair["max_abs"],
        "seconds_per_frame": random_pair["seconds_per_frame"],
        "compute_unit": compute_unit,
        "device": "macos-coreml",
        "note": "Mac Core ML time, not an iPhone 14 Pro time",
    }


def smooth_shift(height: int, width: int, shift: int) -> tuple[torch.Tensor, torch.Tensor]:
    """Band-limited frame and a horizontal shift. Neighboring pixels agree, unlike noise."""
    ys = torch.linspace(0, 1, height).view(1, 1, height, 1)
    xs = torch.linspace(0, 1, width).view(1, 1, 1, width)
    image = 0.5 + 0.25 * torch.sin(xs * 40) + 0.25 * torch.sin(ys * 30 + xs * 10)
    image = image.expand(1, 3, height, width).contiguous()
    return image, torch.roll(image, shifts=shift, dims=-1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", type=Path, default=Path("tools/weights/rife425.zip"))
    parser.add_argument("--out", type=Path, default=Path("build/models"))
    parser.add_argument("--sizes", default=None, help="Comma list HxW. Default is every bucket.")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--uhd", action="store_true", help="Trace the scale-0.5 pyramid. Not used by the v0.1 app.")
    args = parser.parse_args()

    download_zip(args.weights)
    weights = load_weights(args.weights, args.weights.parent)
    net = build_net(weights, uhd=args.uhd)
    error = endpoint_check(net)
    if args.check_only:
        print("check-only ok")
        return

    args.out.mkdir(parents=True, exist_ok=True)
    records = []
    for height, width in parse_sizes(args.sizes):
        records.append(convert_one(net, height, width, args.out, args.uhd))

    manifest = {
        "model": "RIFE 4.25",
        "source": "https://github.com/hzwer/Practical-RIFE",
        "license": "MIT",
        "weights_sha256": ZIP_SHA256,
        "weights_drive_id": DRIVE_ID,
        "uhd": args.uhd,
        "endpoint_mean_abs_t0": error,
        "packages": records,
        "shape_note": "Fixed HxW packages. Dynamic shapes are unsupported for this graph in coremltools.",
    }
    manifest_path = args.out / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2))
    bench = args.out / "benchmark-macos.json"
    bench.write_text(json.dumps(manifest, indent=2))
    print(f"wrote {manifest_path}")


if __name__ == "__main__":
    main()
