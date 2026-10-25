#!/usr/bin/env python3
"""Download Practical-RIFE checkpoints and export fixed-shape Core ML packages.

Dynamic shapes fail in coremltools for this graph (float output size on
upsample, and enumerated shapes with more than one input). Each package is
traced at one HxW. Both axes are multiples of 64 so every variant's pyramid
(the coarsest scale here is 32) lands on integers. The app pads into the
smallest containing package and crops back.

Weights are MIT, same license as https://github.com/hzwer/Practical-RIFE.
The Hugging Face files are a byte-for-byte mirror used when Google Drive
returns an interstitial page. No GPL weights.

Precision: convolutions are FP16 and every resample (bilinear resize and the
warp) stays FP32. A full-FP32 package is traced only as a probe at 256x384.
It replaces the mixed packages only when that probe is more than 0.002 mean
abs closer to PyTorch on the smooth-shift pair. Palettization is not used.

Official ensemble inside IFNet is a no-op since v4.21. The app's maximum-quality
toggle flip-averages outside the package.
"""

from __future__ import annotations

import argparse
import gc
import hashlib
import json
import platform
import subprocess
import sys
import time
import urllib.request
import zipfile
from pathlib import Path

import numpy as np
import torch

# MKLDNN's conv workspace was ~15 GB at 2176×3840 and the cgroup killed it.
# The same forward without MKLDNN stays near 6 GB, which fits the macOS runner.
torch.backends.mkldnn.enabled = False
torch.set_num_threads(2)

sys.path.insert(0, str(Path(__file__).resolve().parent))
import rife425_net as rife_net  # noqa: E402
from rife425_net import RIFE, VARIANTS  # noqa: E402

# Drive ids are the Practical-RIFE README links. sha256 is the zip we convert.
# 4.25 matches the long-standing Drive pin. The others were fetched from the
# Hugging Face mirror of those same zips (train_log/flownet.pkl + IFNet_HDv3.py)
# and are checked again when Drive answers with the file.
CATALOG = [
    {
        "id": "rife425",
        "drive_id": "1ZKjcbmt1hypiFprJPIKW0Tt0lr_2i7bg",
        "hf": "RIFE_v4.25.zip",
        "sha256": "e63d481b7ae5d4a4e6ad7ac5b410ff78f3bf7be3b51b2e38ca8152747abde5b4",
        "zip_name": "rife425.zip",
    },
    {
        "id": "rife426",
        "drive_id": "1gViYvvQrtETBgU1w8axZSsr7YUuw31uy",
        "hf": "RIFE_v4.26.zip",
        "sha256": "c2452dd2b244947d4be580156bbead60d6b72af5736860f7d6b3f99648c9c4cc",
        "zip_name": "rife426.zip",
    },
    {
        "id": "rife426heavy",
        "drive_id": "1vJy82jub1D9O8BZgjPeMu3HHx4bG-NY1",
        "hf": "RIFE_v4.26.heavy.zip",
        "sha256": "93c0ec3dce359930059c1cc6733cff1d0c075314e30d352864436023bfc13463",
        "zip_name": "rife426heavy.zip",
    },
    {
        "id": "rife425lite",
        "drive_id": "1zlKblGuKNatulJNFf5jdB-emp9AqGK05",
        "hf": "RIFE_v4.25.lite.zip",
        "sha256": "e84366c23e0eb1a637a55aad2e4f3442ec2bf4c388043b4aabbf590be289e6e8",
        "zip_name": "rife425lite.zip",
    },
    {
        "id": "rife422",
        "drive_id": "1qh2DSA9a1eZUTtZG9U9RQKO7N7OaUJ0_",
        "hf": "RIFE_v4.22.zip",
        "sha256": "466dfd5f310c5c32ed12904d0e22bfc2f793f17e41808353d4378bbe2c60cb9c",
        "zip_name": "rife422.zip",
    },
]

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
    (2176, 3840),
    (3840, 2176),
]

# Full FP32 replaces mixed weights only when the smooth-shift error drops by
# more than this. Smaller gaps are not visible and they double 4K activations
# on a 6 GB phone.
FP32_GAIN_REQUIRED = 0.002

# Above 1080p the trace peaks near 7 GB and the convert near 4 GB. Doing both
# in one process, or leaving the trace process alive during convert, exceeds
# the 14 GB runner. Those sizes are two sequential processes.
LARGE_PIXELS = 1088 * 1920


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def catalog_by_id(model_id: str) -> dict:
    for item in CATALOG:
        if item["id"] == model_id:
            return item
    raise SystemExit(f"unknown model {model_id}")


def download_zip(item: dict, dest: Path) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and sha256(dest) == item["sha256"]:
        print(f"weights cache ok {dest}")
        return
    urls = [
        f"https://drive.usercontent.google.com/download?id={item['drive_id']}&export=download&confirm=t",
        f"https://huggingface.co/Bash2X/RIFE-Models/resolve/main/{item['hf']}",
    ]
    errors = []
    tmp = dest.with_suffix(".partial")
    for url in urls:
        print(f"downloading {item['id']} {url}")
        try:
            request = urllib.request.Request(url, headers={"User-Agent": "evii-frames/0.1.1"})
            with urllib.request.urlopen(request, timeout=180) as response, tmp.open("wb") as handle:
                while True:
                    chunk = response.read(1 << 20)
                    if not chunk:
                        break
                    handle.write(chunk)
        except Exception as exc:  # noqa: BLE001 — try the mirror
            errors.append(f"{url} {exc}")
            tmp.unlink(missing_ok=True)
            continue
        digest = sha256(tmp)
        if digest != item["sha256"]:
            errors.append(f"{url} sha256 {digest}")
            tmp.unlink(missing_ok=True)
            continue
        tmp.replace(dest)
        print(f"weights ok {dest.name} {digest}")
        return
    raise SystemExit(f"download failed for {item['id']}: {'; '.join(errors)}")


def flownet_path(zip_path: Path, cache_dir: Path) -> Path:
    pkl = cache_dir / f"{zip_path.stem}-flownet.pkl"
    if pkl.exists():
        return pkl
    with zipfile.ZipFile(zip_path) as archive:
        names = [name for name in archive.namelist() if name.endswith("flownet.pkl") and not name.startswith("__MACOSX")]
        if len(names) != 1:
            raise SystemExit(f"{zip_path} flownet.pkl entries: {names}")
        extracted = cache_dir / "extract" / names[0]
        extracted.parent.mkdir(parents=True, exist_ok=True)
        with archive.open(names[0]) as source, extracted.open("wb") as dest:
            dest.write(source.read())
        extracted.replace(pkl)
    return pkl


def load_weights(zip_path: Path, cache_dir: Path) -> dict:
    state = torch.load(flownet_path(zip_path, cache_dir), map_location="cpu", weights_only=False)
    clean = {}
    for key, value in state.items():
        if key.startswith("module."):
            key = key[len("module.") :]
        if key.startswith("teacher.") or key.startswith("caltime."):
            continue
        clean["net." + key] = value
    return clean


def build_net(model_id: str, weights: dict) -> torch.nn.Module:
    variant = VARIANTS[model_id]
    net = RIFE(variant).eval()
    missing, unexpected = net.load_state_dict(weights, strict=False)
    if missing or unexpected:
        raise SystemExit(
            f"{model_id} weight mismatch missing={list(missing)[:8]} unexpected={list(unexpected)[:8]}"
        )
    return net


def smooth_shift(height: int, width: int, shift: int) -> tuple[torch.Tensor, torch.Tensor]:
    """Band-limited frame and a horizontal shift. Neighboring pixels agree, unlike noise."""
    ys = torch.linspace(0, 1, height).view(1, 1, height, 1)
    xs = torch.linspace(0, 1, width).view(1, 1, 1, width)
    image = 0.5 + 0.25 * torch.sin(xs * 40) + 0.25 * torch.sin(ys * 30 + xs * 10)
    image = image.expand(1, 3, height, width).contiguous()
    return image, torch.roll(image, shifts=shift, dims=-1)


def endpoint_check(net: torch.nn.Module, label: str) -> dict:
    torch.manual_seed(0)
    image = torch.rand(1, 3, 256, 384)
    with torch.no_grad():
        output = net(image, image.clone(), torch.zeros(1, 1, 1, 1))
    error = (output - image).abs().mean().item()
    print(f"pytorch {label} t=0 mean abs {error:.6f} at 256x384")
    if error > 0.02:
        raise SystemExit(f"{label} endpoint check failed: t=0 should stay close to frame0")
    return {"t0_mean_abs": error}


def interpolate_gap(net: torch.nn.Module, label: str) -> float:
    """Our grid_sample resize versus F.interpolate, same weights, smooth pair."""
    left, right = smooth_shift(256, 384, shift=6)
    half = torch.full((1, 1, 1, 1), 0.5)
    original = rife_net.resize_bilinear

    def official(x, scale_factor):
        return torch.nn.functional.interpolate(
            x, scale_factor=scale_factor, mode="bilinear", align_corners=False
        )

    with torch.no_grad():
        ours = net(left, right, half)
        rife_net.resize_bilinear = official
        try:
            reference = net(left, right, half)
        finally:
            rife_net.resize_bilinear = original
    gap = (ours - reference).abs().mean().item()
    print(f"pytorch {label} grid_sample vs interpolate smooth t=0.5 mean abs {gap:.8f}")
    if gap > 1e-4:
        raise SystemExit(f"{label} resize does not match interpolate: {gap}")
    return gap


def precision_gap(net: torch.nn.Module, label: str) -> dict:
    """FP32 forward versus the same net with weights rounded to FP16.

    This is the part of mixed precision that changes the stored numbers.
    The Core ML probe, when it runs, also measures the compiled package.
    """
    left, right = smooth_shift(256, 384, shift=6)
    half = torch.full((1, 1, 1, 1), 0.5)
    shadow = RIFE(VARIANTS[label]).eval()
    shadow.load_state_dict(net.state_dict())
    with torch.no_grad():
        reference = net(left, right, half)
        for parameter in shadow.parameters():
            parameter.copy_(parameter.detach().to(torch.float16).to(torch.float32))
        rounded = shadow(left, right, half)
    gap = (reference - rounded).abs().mean().item()
    print(f"pytorch {label} fp32 vs fp16-rounded weights smooth t=0.5 mean abs {gap:.8f}")
    return {"fp16_weight_round_smooth_mean_abs": gap}


def parse_sizes(text: str | None) -> list[tuple[int, int]]:
    if not text:
        return list(DEFAULT_SIZES)
    sizes = []
    for part in text.split(","):
        part = part.strip().lower()
        if not part:
            continue
        height, width = part.split("x")
        sizes.append((int(height), int(width)))
    return sizes


def parse_models(text: str | None) -> list[str]:
    if not text:
        return [item["id"] for item in CATALOG]
    chosen = []
    for part in text.split(","):
        part = part.strip().lower()
        if not part:
            continue
        if part not in VARIANTS:
            raise SystemExit(f"unknown model {part}")
        chosen.append(part)
    return chosen


def release_memory() -> None:
    gc.collect()
    if platform.system() == "Linux":
        try:
            import ctypes

            ctypes.CDLL("libc.so.6").malloc_trim(0)
        except Exception:
            pass


def convert_script_file(script_path: Path, height: int, width: int, out_dir: Path, tag: str, full_fp32: bool) -> None:
    import coremltools as ct

    traced = torch.jit.load(str(script_path))
    float32 = np.float32

    def fp16_selector(op) -> bool:
        return op.op_type != "resample"

    if full_fp32:
        precision = ct.precision.FLOAT32
    else:
        precision = ct.transform.FP16ComputePrecision(op_selector=fp16_selector)
    print(f"convert {tag} {height}x{width} fp32={full_fp32}")
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="frame0", shape=(1, 3, height, width), dtype=float32),
            ct.TensorType(name="frame1", shape=(1, 3, height, width), dtype=float32),
            ct.TensorType(name="timestep", shape=(1, 1, 1, 1), dtype=float32),
        ],
        outputs=[ct.TensorType(name="output", dtype=float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.iOS17,
    )
    path = out_dir / f"{tag}_{height}x{width}.mlpackage"
    model.save(str(path))
    print(f"saved {path}")


def trace_script(model_id: str, height: int, width: int, out_dir: Path, weights_dir: Path) -> Path:
    """Trace one fixed shape and exit. This process must not import coremltools."""
    if height * width <= LARGE_PIXELS:
        raise SystemExit(f"{height}x{width} is traced inside --convert-one")
    item = catalog_by_id(model_id)
    download_zip(item, weights_dir / item["zip_name"])
    net = build_net(model_id, load_weights(weights_dir / item["zip_name"], weights_dir))
    variant = VARIANTS[model_id]
    example0 = torch.rand(1, 3, height, width)
    example1 = torch.rand(1, 3, height, width)
    timestep = torch.tensor([[[[0.5]]]])
    print(f"trace {variant.tag} {height}x{width}", flush=True)
    with torch.no_grad():
        traced = torch.jit.trace(net, (example0, example1, timestep), check_trace=False)
    script_path = out_dir / "_trace" / f"{variant.tag}_{height}x{width}.pt"
    script_path.parent.mkdir(parents=True, exist_ok=True)
    traced.save(str(script_path))
    print(f"traced {script_path} bytes={script_path.stat().st_size}", flush=True)
    return script_path


def convert_package(
    net: torch.nn.Module,
    model_id: str,
    height: int,
    width: int,
    out_dir: Path,
    full_fp32: bool,
) -> dict:
    if height * width > LARGE_PIXELS:
        raise SystemExit(
            f"{height}x{width} is traced with --trace-only and converted with "
            "--from-script in a second process. One process does not do both."
        )
    variant = VARIANTS[model_id]
    example0 = torch.rand(1, 3, height, width)
    example1 = torch.rand(1, 3, height, width)
    timestep = torch.tensor([[[[0.5]]]])
    print(f"trace {variant.tag} {height}x{width} fp32={full_fp32}", flush=True)
    traced = torch.jit.trace(net, (example0, example1, timestep), check_trace=False)
    import coremltools as ct

    print(f"convert {variant.tag} {height}x{width}", flush=True)
    float32 = np.float32

    def fp16_selector(op) -> bool:
        return op.op_type != "resample"

    if full_fp32:
        precision = ct.precision.FLOAT32
    else:
        precision = ct.transform.FP16ComputePrecision(op_selector=fp16_selector)
    started = time.perf_counter()
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="frame0", shape=example0.shape, dtype=float32),
            ct.TensorType(name="frame1", shape=example1.shape, dtype=float32),
            ct.TensorType(name="timestep", shape=(1, 1, 1, 1), dtype=float32),
        ],
        outputs=[ct.TensorType(name="output", dtype=float32)],
        convert_to="mlprogram",
        compute_precision=precision,
        minimum_deployment_target=ct.target.iOS17,
    )
    path = out_dir / f"{variant.tag}_{height}x{width}.mlpackage"
    model.save(str(path))
    del model, traced
    release_memory()
    elapsed = time.perf_counter() - started
    record = {
        "model": variant.title,
        "model_id": model_id,
        "tag": variant.tag,
        "file": path.name,
        "height": height,
        "width": width,
        "bytes": package_bytes(path),
        "seconds_convert": round(elapsed, 3),
        "compute_precision": "fp32" if full_fp32 else "fp16-conv-fp32-resample",
        "deployment_target": "iOS17",
        "license": "MIT",
        "note": variant.note,
    }
    if platform.system() == "Darwin" and height * width <= 256 * 384:
        record["checks"] = [
            predict_check(path, net, height, width, unit)
            for unit in ("cpuOnly", "cpuAndGPU", "all")
        ]
        good = [item for item in record["checks"] if numeric_ok(item)]
        record["acceptable_units"] = [item["compute_unit"] for item in good]
        if not any(unit in ("cpuOnly", "cpuAndGPU") for unit in record["acceptable_units"]):
            raise SystemExit(f"numeric check failed for {path.name}: {json.dumps(record['checks'])}")
        chosen = next(item for item in record["checks"] if item["compute_unit"] == "cpuAndGPU")
        record.update(
            {
                "t0_mean_abs": chosen["t0_mean_abs"],
                "mean_abs": chosen["mean_abs"],
                "max_abs": chosen["max_abs"],
                "smooth_t0_mean_abs": chosen["smooth_t0_mean_abs"],
                "smooth_mean_abs": chosen["smooth_mean_abs"],
                "smooth_max_abs": chosen["smooth_max_abs"],
                "seconds_per_frame": chosen["seconds_per_frame"],
            }
        )
    elif platform.system() == "Darwin" and (height, width) == (1088, 1920) and model_id == "rife425":
        try:
            record["timing"] = predict_check(path, net, height, width, "cpuAndGPU")
        except Exception as exc:  # noqa: BLE001 — timing must not hide a good small-model check
            record["timing_error"] = str(exc)
    elif platform.system() != "Darwin":
        record["predict"] = "skipped"
        record["predict_note"] = "Linux coremltools cannot load libcoremlpython. Verify on macOS."
    print(json.dumps(record))
    return record


def package_bytes(path: Path) -> int:
    total = 0
    if path.is_file():
        return path.stat().st_size
    for child in path.rglob("*"):
        if child.is_file():
            total += child.stat().st_size
    return total


def numeric_ok(item: dict) -> bool:
    # The gate is the smooth 6 px shift, which is what a video frame looks like.
    # White-noise t=0.5 stays large: a sub-pixel flow difference makes
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
            f"numeric {path.name} {compute_unit} {label} io_dtype={io_dtype} "
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


def fp32_probe(net: torch.nn.Module, model_id: str, out_dir: Path) -> dict:
    """Compile one small FP32 package and compare it with the mixed package."""
    if platform.system() != "Darwin":
        return {"fp32_probe": "skipped", "reason": "needs macOS Core ML"}
    probe_dir = out_dir / "fp32-probe"
    probe_dir.mkdir(parents=True, exist_ok=True)
    mixed = convert_package(net, model_id, 256, 384, probe_dir, full_fp32=False)
    full = convert_package(net, model_id, 256, 384, probe_dir, full_fp32=True)
    mixed_err = float(mixed["smooth_mean_abs"])
    full_err = float(full["smooth_mean_abs"])
    ship = full_err + FP32_GAIN_REQUIRED < mixed_err
    result = {
        "fp32_probe": "ran",
        "mixed_smooth_mean_abs": mixed_err,
        "fp32_smooth_mean_abs": full_err,
        "ship_fp32": ship,
        "threshold": FP32_GAIN_REQUIRED,
        "mixed_seconds_per_frame": mixed.get("seconds_per_frame"),
        "fp32_seconds_per_frame": full.get("seconds_per_frame"),
    }
    print(json.dumps(result))
    # The probe packages are not shipped. The real convert writes the chosen precision.
    for child in probe_dir.glob("*.mlpackage"):
        if child.is_dir():
            import shutil
            shutil.rmtree(child)
    return result


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2))


def run_check(item: dict, weights_dir: Path) -> dict:
    download_zip(item, weights_dir / item["zip_name"])
    weights = load_weights(weights_dir / item["zip_name"], weights_dir)
    net = build_net(item["id"], weights)
    record = {
        "model_id": item["id"],
        "title": VARIANTS[item["id"]].title,
        "tag": VARIANTS[item["id"]].tag,
        "license": "MIT",
        "weights_sha256": item["sha256"],
        "weights_drive_id": item["drive_id"],
        "note": VARIANTS[item["id"]].note,
    }
    record.update(endpoint_check(net, item["id"]))
    record["interpolate_gap"] = interpolate_gap(net, item["id"])
    record.update(precision_gap(net, item["id"]))
    return record


def run_convert_one(item: dict, height: int, width: int, out_dir: Path, weights_dir: Path, full_fp32: bool) -> dict:
    download_zip(item, weights_dir / item["zip_name"])
    weights = load_weights(weights_dir / item["zip_name"], weights_dir)
    net = build_net(item["id"], weights)
    record = convert_package(net, item["id"], height, width, out_dir, full_fp32=full_fp32)
    if full_fp32:
        record["ship_fp32"] = True
    if (
        platform.system() == "Darwin"
        and item["id"] == "rife425"
        and (height, width) == (256, 384)
        and not full_fp32
    ):
        record["fp32_probe"] = fp32_probe(net, item["id"], out_dir)
        record["ship_fp32"] = bool(record["fp32_probe"].get("ship_fp32"))
    return record


def spawn(args: list[str]) -> None:
    print(" ".join(args), flush=True)
    subprocess.check_call(args)


def spawn_package(
    model_id: str,
    height: int,
    width: int,
    out_dir: Path,
    weights_dir: Path,
    full_fp32: bool,
) -> None:
    """Convert one package. 4K trace and convert are separate processes."""
    script = str(Path(__file__).resolve())
    if height * width <= LARGE_PIXELS:
        command = [
            sys.executable,
            script,
            "--convert-one",
            model_id,
            "--height",
            str(height),
            "--width",
            str(width),
            "--out",
            str(out_dir),
            "--weights-dir",
            str(weights_dir),
        ]
        if full_fp32:
            command.append("--fp32")
        spawn(command)
        return

    tag = VARIANTS[model_id].tag
    script_path = out_dir / "_trace" / f"{tag}_{height}x{width}.pt"
    trace_started = time.perf_counter()
    spawn(
        [
            sys.executable,
            script,
            "--trace-only",
            model_id,
            "--height",
            str(height),
            "--width",
            str(width),
            "--out",
            str(out_dir),
            "--weights-dir",
            str(weights_dir),
        ]
    )
    trace_seconds = time.perf_counter() - trace_started
    convert_command = [
        sys.executable,
        script,
        "--from-script",
        str(script_path),
        "--tag",
        tag,
        "--height",
        str(height),
        "--width",
        str(width),
        "--out",
        str(out_dir),
    ]
    if full_fp32:
        convert_command.append("--fp32")
    convert_started = time.perf_counter()
    spawn(convert_command)
    convert_seconds = time.perf_counter() - convert_started
    script_path.unlink(missing_ok=True)
    path = out_dir / f"{tag}_{height}x{width}.mlpackage"
    record = {
        "model": VARIANTS[model_id].title,
        "model_id": model_id,
        "tag": tag,
        "file": path.name,
        "height": height,
        "width": width,
        "bytes": package_bytes(path),
        "seconds_trace": round(trace_seconds, 3),
        "seconds_convert": round(convert_seconds, 3),
        "compute_precision": "fp32" if full_fp32 else "fp16-conv-fp32-resample",
        "deployment_target": "iOS17",
        "license": "MIT",
        "note": VARIANTS[model_id].note,
        "split": "trace-process-then-convert-process",
    }
    if full_fp32:
        record["ship_fp32"] = True
    if platform.system() != "Darwin":
        record["predict"] = "skipped"
        record["predict_note"] = "Linux coremltools cannot load libcoremlpython. Verify on macOS."
    write_json(out_dir / "records" / f"{tag}_{height}x{width}.json", record)
    print(json.dumps(record), flush=True)


def merge_manifest(out_dir: Path, models: list[str], sizes: list[tuple[int, int]]) -> None:
    records_dir = out_dir / "records"
    checks = []
    packages = []
    for model_id in models:
        check_path = records_dir / f"{model_id}-check.json"
        if check_path.exists():
            checks.append(json.loads(check_path.read_text()))
        for height, width in sizes:
            tag = VARIANTS[model_id].tag
            package_record = records_dir / f"{tag}_{height}x{width}.json"
            if package_record.exists():
                packages.append(json.loads(package_record.read_text()))
    ship_fp32 = any(item.get("ship_fp32") for item in packages)
    manifest = {
        "license": "MIT",
        "source": "https://github.com/hzwer/Practical-RIFE",
        "precision": "fp32" if ship_fp32 else "fp16-conv-fp32-resample",
        "precision_note": (
            "Full FP32 replaced mixed precision because the 256x384 smooth-shift "
            "probe beat FP16-conv/FP32-warp by more than 0.002 mean abs."
            if ship_fp32
            else "Shipped FP16 convolutions and FP32 resample. Full FP32 is kept only when the smooth-shift probe improves mean abs by more than 0.002. Weights are not palettized."
        ),
        "anime_note": "RIFE 4.25 is the checkpoint Practical-RIFE describes as improved on anime. No separate permissive anime model is published.",
        "ensemble_note": "Official IFNet ensemble is unsupported since v4.21. The app flip-averages outside the package when maximum quality is on.",
        "shape_note": "Fixed HxW packages, both axes multiples of 64, including 2176x3840 and 3840x2176 for 4K. Dynamic shapes are unsupported for this graph.",
        "checks": checks,
        "packages": packages,
    }
    write_json(out_dir / "manifest.json", manifest)
    write_json(out_dir / "benchmark-macos.json", manifest)
    print(f"wrote {out_dir / 'manifest.json'} packages={len(packages)}")


def orchestrate(models: list[str], sizes: list[tuple[int, int]], out_dir: Path, weights_dir: Path, check_only: bool) -> None:
    script = str(Path(__file__).resolve())
    out_dir.mkdir(parents=True, exist_ok=True)
    records = out_dir / "records"
    records.mkdir(parents=True, exist_ok=True)
    for model_id in models:
        spawn(
            [
                sys.executable,
                script,
                "--worker-check",
                model_id,
                "--out",
                str(out_dir),
                "--weights-dir",
                str(weights_dir),
            ]
        )
        if check_only:
            continue
        for height, width in sizes:
            tag = VARIANTS[model_id].tag
            package = out_dir / f"{tag}_{height}x{width}.mlpackage"
            record = records / f"{tag}_{height}x{width}.json"
            if package.exists() and record.exists():
                print(f"skip existing {package.name}")
                continue
            spawn_package(model_id, height, width, out_dir, weights_dir, full_fp32=False)
    if not check_only:
        probe = records / "RIFE425_256x384.json"
        ship_fp32 = False
        if probe.exists():
            ship_fp32 = bool(json.loads(probe.read_text()).get("ship_fp32"))
        if ship_fp32:
            print("FP32 probe beat mixed precision; reconverting every package as FP32")
            for model_id in models:
                for height, width in sizes:
                    tag = VARIANTS[model_id].tag
                    package = out_dir / f"{tag}_{height}x{width}.mlpackage"
                    if package.exists():
                        import shutil
                        shutil.rmtree(package)
                    spawn_package(model_id, height, width, out_dir, weights_dir, full_fp32=True)
    merge_manifest(out_dir, models, sizes)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights-dir", type=Path, default=Path("tools/weights"))
    parser.add_argument("--out", type=Path, default=Path("build/models"))
    parser.add_argument("--sizes", default=None, help="Comma list HxW.")
    parser.add_argument("--models", default=None, help="Comma list of variant ids.")
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--worker-check", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--convert-one", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--trace-only", default=None, help=argparse.SUPPRESS)
    parser.add_argument("--height", type=int, default=0)
    parser.add_argument("--width", type=int, default=0)
    parser.add_argument("--fp32", action="store_true")
    parser.add_argument("--from-script", type=Path, default=None, help=argparse.SUPPRESS)
    parser.add_argument("--tag", default="")
    args = parser.parse_args()

    if args.from_script:
        convert_script_file(args.from_script, args.height, args.width, args.out, args.tag, args.fp32)
        return

    if args.worker_check:
        item = catalog_by_id(args.worker_check)
        record = run_check(item, args.weights_dir)
        write_json(args.out / "records" / f"{item['id']}-check.json", record)
        return

    if args.trace_only:
        trace_script(args.trace_only, args.height, args.width, args.out, args.weights_dir)
        return

    if args.convert_one:
        item = catalog_by_id(args.convert_one)
        record = run_convert_one(
            item,
            args.height,
            args.width,
            args.out,
            args.weights_dir,
            full_fp32=args.fp32,
        )
        tag = VARIANTS[item["id"]].tag
        write_json(args.out / "records" / f"{tag}_{args.height}x{args.width}.json", record)
        return

    models = parse_models(args.models)
    sizes = parse_sizes(args.sizes)
    orchestrate(models, sizes, args.out, args.weights_dir, args.check_only)


if __name__ == "__main__":
    main()
