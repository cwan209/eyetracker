#!/usr/bin/env python3
"""Convert an open gaze-estimation model to CoreML for GazeFocus (plan U6, KTD2).

Run on a machine with Python + PyTorch + coremltools + the model weights — NOT
part of the Swift build. Produces Sources/.../Resources/GazeModel.mlpackage,
which the CoreML gaze estimator (U7) loads. Until you run this, the spike uses
the model-free LandmarkGazeEstimator proxy.

Model: L2CS-Net (ResNet-50 backbone), MIT license, ~3.9 deg MAE on MPIIFaceGaze.
  source:  https://github.com/Ahmednull/L2CS-Net
  pin the exact commit you use in Scripts/README.md for reproducibility.
Smaller alternative: yakhyo/gaze-estimation (MobileOne-S0, ~5 MB) if bundle size
matters more than accuracy.

Usage:
    python3 Scripts/convert_gaze_model.py \
        --weights /path/to/L2CSNet_gaze360.pkl \
        --out App/Resources/GazeModel.mlpackage

Prefer the torch.jit.trace path (below) over the ONNX path — newer ONNX opsets
hit operator-not-found errors in coremltools (KTD2 pitfall).
"""
from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def convert(weights: Path, out: Path, image_size: int) -> None:
    import torch  # noqa: import here so --help works without the ML toolchain
    import coremltools as ct

    # 1. Build the model graph and load weights. L2CS-Net's class lives in the
    #    cloned repo (add it to PYTHONPATH); this is the one project-specific bit.
    try:
        from l2cs import L2CS  # type: ignore
    except ImportError:
        sys.exit("Clone https://github.com/Ahmednull/L2CS-Net and add it to "
                 "PYTHONPATH so `from l2cs import L2CS` resolves.")

    import torchvision
    model = L2CS(torchvision.models.resnet.Bottleneck, [3, 4, 6, 3], num_bins=90)
    model.load_state_dict(torch.load(weights, map_location="cpu"))
    model.eval()

    # 2. Trace with a representative input (ImageNet-normalized face crop).
    example = torch.rand(1, 3, image_size, image_size)
    traced = torch.jit.trace(model, example)

    # 3. Convert to a CoreML .mlpackage targeting the Neural Engine.
    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape,
                             scale=1 / 255.0, bias=[-0.485, -0.456, -0.406])],
        convert_to="mlprogram",
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS15,
    )
    mlmodel.short_description = "L2CS-Net gaze estimation (yaw/pitch bins). MIT."
    out.parent.mkdir(parents=True, exist_ok=True)
    mlmodel.save(str(out))
    print(f"Wrote {out}")
    print(f"sha256: {sha256(Path(weights))}  (source weights — pin this in the build hash check)")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--weights", type=Path, required=True, help="Path to the .pkl/.pth weights")
    p.add_argument("--out", type=Path, default=Path("App/Resources/GazeModel.mlpackage"))
    p.add_argument("--image-size", type=int, default=448)
    args = p.parse_args()
    convert(args.weights, args.out, args.image_size)


if __name__ == "__main__":
    main()
