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
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="frame0", shape=example0.shape),
            ct.TensorType(name="frame1", shape=example1.shape),
            ct.TensorType(name="timestep", shape=(1, 1, 1, 1)),
        ],
        outputs=[ct.TensorType(name="output")],
        convert_to="mlprogram",
        compute_precision=ct.precision.FLOAT16,
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
        "compute_precision": "fp16",
        "deployment_target": "iOS17",
    }
    if platform.system() == "Darwin":
        record.update(predict_check(model, net, height, width))
    else:
        record["predict"] = "skipped"
        record["predict_note"] = "Linux coremltools cannot load libcoremlpython. Verify on macOS."
    print(json.dumps(record))
    return record


def predict_check(model, net: torch.nn.Module, height: int, width: int) -> dict:
    torch.manual_seed(1)
    frame0 = torch.rand(1, 3, height, width)
    frame1 = torch.rand(1, 3, height, width)
    timestep = torch.full((1, 1, 1, 1), 0.5)
    with torch.no_grad():
        reference = net(frame0, frame1, timestep).numpy()
    started = time.perf_counter()
    predicted = model.predict(
        {
            "frame0": frame0.numpy().astype(np.float32),
            "frame1": frame1.numpy().astype(np.float32),
            "timestep": timestep.numpy().astype(np.float32),
        }
    )["output"]
    seconds = time.perf_counter() - started
    delta = np.abs(predicted.astype(np.float32) - reference)
    return {
        "predict": "ok",
        "mean_abs": float(delta.mean()),
        "max_abs": float(delta.max()),
        "seconds_per_frame": round(seconds, 4),
        "device": "macos-coreml",
        "note": "not representative of iPhone",
    }


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
        if platform.system() == "Darwin":
            last = records[-1]
            if last.get("mean_abs", 0) > 0.02 or last.get("max_abs", 0) > 0.08:
                raise SystemExit(f"numeric check failed for {height}x{width}: {last}")

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
