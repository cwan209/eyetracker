# Scripts

## `convert_gaze_model.py` — gaze model → CoreML (plan U6, KTD2)

Offline tooling, **not** part of the Swift build. Produces the bundled CoreML
gaze model the capture pipeline (U7) loads. Until you run it, `gaze-spike` uses
the model-free `LandmarkGazeEstimator` proxy.

### Provenance (pin these when you run it)

| Field | Value |
|---|---|
| Model | L2CS-Net (ResNet-50), ~3.9° MAE on MPIIFaceGaze |
| Source | https://github.com/Ahmednull/L2CS-Net |
| Commit | `<fill in the exact commit you cloned>` |
| License | MIT |
| Weights | `L2CSNet_gaze360.pkl` (from the repo's releases) |
| Input | 448×448 RGB face crop, ImageNet-normalized |
| Smaller alt | `yakhyo/gaze-estimation` MobileOne-S0 (~5 MB) if bundle size > accuracy |

### Steps

```bash
python3 -m venv .venv && source .venv/bin/activate
pip install torch torchvision coremltools
git clone https://github.com/Ahmednull/L2CS-Net && export PYTHONPATH="$PWD/L2CS-Net:$PYTHONPATH"
python3 Scripts/convert_gaze_model.py --weights ./L2CSNet_gaze360.pkl --out App/Resources/GazeModel.mlpackage
```

### Build-time hash check (KTD2 / U6 supply-chain)

The script prints the source weights' `sha256`. Record it here and have the app
build verify the bundled `.mlpackage` derives from those exact weights, so a
swapped/poisoned model is caught:

```
source weights sha256: <paste here after first run>
```
