#!/usr/bin/env python3
"""Converts Open-Unmix (vocals) to Core ML for Chirp's High Quality splitter.

The app does the STFT itself (4096-point FFT, 1024 hop, 44.1 kHz) and feeds
the network a stereo magnitude spectrogram shaped (1, 2, 2049, FRAMES); the
network returns the vocals' magnitude spectrogram in the same shape. That
keeps the model to plain layers (linear, batch norm, LSTM) that Core ML runs
on the Neural Engine / GPU.

Usage (Python 3.10–3.12):
    pip install "torch>=2.2,<2.6" "coremltools>=8.0" openunmix numpy
    python tools/convert_separator.py                 # umxhq, fp16 -> VocalSeparator.mlpackage
    python tools/convert_separator.py --name VocalSeparatorBest --precision float32

Conversion works on macOS and Linux (coremltools has no Windows build: use
WSL, Google Colab, or the "Convert separation model" GitHub workflow).
The check against PyTorch at the end only runs on macOS.

Licence: Open-Unmix code and the umxhq/umx weights are MIT (sigsep). Do not
use "umxl": its weights are CC BY-NC-SA 4.0 (non-commercial).
"""

import argparse
import sys

import numpy as np
import torch

BINS = 2049       # 4096-point FFT -> 2049 bins
CHANNELS = 2
SAMPLE_RATE = 44_100
HOP = 1024


def load_model(name: str) -> torch.nn.Module:
    import openunmix

    loaders = {"umxhq": openunmix.umxhq_spec, "umx": openunmix.umx_spec}
    models = loaders[name](targets=["vocals"], device="cpu", pretrained=True)
    model = models["vocals"]
    model.eval()
    return model


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", choices=["umxhq", "umx"], default="umxhq",
                        help="pretrained Open-Unmix weights (MIT); umxhq is the better one")
    parser.add_argument("--frames", type=int, default=432,
                        help="STFT frames per chunk: 432 = 10 s at 44.1 kHz (the app reads this from the model)")
    parser.add_argument("--precision", choices=["float16", "float32"], default="float16",
                        help="float16 halves the size and runs on the Neural Engine")
    parser.add_argument("--name", default="VocalSeparator",
                        help="VocalSeparator (default engine) or VocalSeparatorBest (used for Best quality)")
    args = parser.parse_args()

    import coremltools as ct

    model = load_model(args.model)
    example = torch.rand(1, CHANNELS, BINS, args.frames) * 2.0
    with torch.no_grad():
        reference = model(example).numpy()
        traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="magnitude", shape=tuple(example.shape), dtype=np.float32)],
        outputs=[ct.TensorType(name="vocals", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16 if args.precision == "float16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL,
    )
    mlmodel.author = "sigsep Open-Unmix (MIT), converted for Chirp"
    mlmodel.license = "MIT"
    mlmodel.short_description = (
        f"Open-Unmix {args.model} vocals: stereo magnitude spectrogram (1, 2, {BINS}, {args.frames}) "
        f"at {SAMPLE_RATE} Hz, FFT 4096, hop {HOP} -> vocals magnitude, same shape."
    )
    mlmodel.input_description["magnitude"] = "Mixture |STFT| (channel, bin, frame), Hann window, centred frames"
    mlmodel.output_description["vocals"] = "Estimated vocals |STFT|, same shape"
    mlmodel.user_defined_metadata.update({
        "sample_rate": str(SAMPLE_RATE), "fft_size": "4096", "hop_size": str(HOP),
        "frames": str(args.frames), "source_model": args.model,
    })
    path = f"{args.name}.mlpackage"
    mlmodel.save(path)
    print(f"Saved {path}")

    if sys.platform == "darwin":
        predicted = mlmodel.predict({"magnitude": example.numpy()})["vocals"]
        error = float(np.max(np.abs(predicted - reference)) / (np.max(np.abs(reference)) + 1e-9))
        print(f"Largest difference from PyTorch: {error:.4f} of the peak (float16 is usually below 0.01)")
        if error > 0.05:
            print("Warning: the converted model differs a lot from PyTorch.", file=sys.stderr)
            return 1
    else:
        print("Skipping the Core ML check (only possible on macOS).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
