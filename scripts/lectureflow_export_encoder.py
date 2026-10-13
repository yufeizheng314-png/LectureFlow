#!/usr/bin/env python3
"""Export only the official Whisper base encoder for a FLOAT32 diagnostic control.

Run in an isolated macOS Python 3.12 environment with:
  coremltools==9.0 torch==2.7.0 numpy==1.26.4 openai-whisper==20250625
This script installs nothing, uses no credentials, and does not modify App models.
Trace parity uses synthetic tensors; successful export is not an ASR acceptance.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import asdict
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import urllib.request


BASE_SHA256 = "ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e"
WHISPER_VERSION = "20250625"
INPUT_SHAPE = (1, 80, 1, 3000)
OUTPUT_SHAPE = (1, 512, 1, 1500)
PINNED_VERSIONS = {"coremltools": "9.0", "torch": "2.7.0", "numpy": "1.26.4", "openai-whisper": WHISPER_VERSION}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def checked_weights(path: Path, official_url: str) -> None:
    if path.exists():
        if not path.is_file() or sha256(path) != BASE_SHA256:
            raise ValueError("Existing base weights do not match the official SHA-256; left untouched")
        return
    if BASE_SHA256 not in official_url or not official_url.startswith("https://openaipublic.azureedge.net/"):
        raise ValueError("Installed Whisper declares an unexpected official base model URL")
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".download")
    if temporary.exists():
        raise ValueError("Temporary model download already exists; refusing to overwrite it")
    try:
        with urllib.request.urlopen(official_url, timeout=120) as response, temporary.open("xb") as target:
            for block in iter(lambda: response.read(1024 * 1024), b""):
                target.write(block)
        if sha256(temporary) != BASE_SHA256:
            raise ValueError("Downloaded base model SHA-256 differs from the official value")
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def source_commit(repo: Path) -> str | None:
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, check=False)
    return result.stdout.strip() if result.returncode == 0 else None


def tensor_summary(tensor, expected_shape, torch) -> dict:
    if tuple(tensor.shape) != expected_shape or tensor.dtype != torch.float32:
        raise ValueError(f"Unexpected tensor shape/dtype: {tuple(tensor.shape)} / {tensor.dtype}")
    if not bool(torch.isfinite(tensor).all()):
        raise ValueError("Non-finite tensor in encoder trace parity")
    values = tensor.detach().cpu().contiguous()
    return {"shape": list(values.shape), "dtype": "float32", "min": float(values.min()),
            "max": float(values.max()), "rms": float(values.square().mean().sqrt()),
            "logical_float32_sha256": hashlib.sha256(values.numpy().astype("<f4", copy=False).tobytes()).hexdigest()}


def export(args, report: dict) -> None:
    versions = {name: importlib.metadata.version(name) for name in PINNED_VERSIONS}
    report["package_versions"] = versions
    for name, expected in PINNED_VERSIONS.items():
        if versions[name].split("+")[0] != expected:
            raise ValueError(f"Use the isolated pinned environment: {name}=={expected}; installed {versions[name]}")
    import numpy as np
    import torch
    import whisper
    import whisper.model
    import coremltools as ct
    from coremltools.converters.mil.mil import types

    torch.set_num_threads(4)
    torch.set_num_interop_threads(1)
    torch.manual_seed(20261013)
    torch.set_grad_enabled(False)
    whisper.model.MultiHeadAttention.use_sdpa = False
    official_url = whisper._MODELS["base"]
    weights = args.weights_path.resolve() if args.weights_path else args.output_root / "weights" / "base.pt"
    checked_weights(weights, official_url)
    report["weights"] = {"source_url": official_url, "path": str(weights), "bytes": weights.stat().st_size,
                         "sha256": sha256(weights), "expected_sha256": BASE_SHA256}
    model = whisper.load_model(str(weights), device="cpu").float().eval()
    dimensions = asdict(model.dims)
    expected_dimensions = {"n_mels": 80, "n_audio_ctx": 1500, "n_audio_state": 512,
                           "n_audio_head": 8, "n_audio_layer": 6, "n_vocab": 51865,
                           "n_text_ctx": 448, "n_text_state": 512, "n_text_head": 8, "n_text_layer": 6}
    if dimensions != expected_dimensions:
        raise ValueError("Official base model dimensions differ from the diagnostic contract")
    if any(parameter.dtype != torch.float32 for parameter in model.encoder.parameters()):
        raise ValueError("Encoder parameters must all be FLOAT32")
    report["model_dimensions"] = dimensions
    report["installed_source_files"] = {"whisper/model.py": sha256(Path(whisper.model.__file__)),
                                       "whisper/__init__.py": sha256(Path(whisper.__file__))}

    class EncoderControl(torch.nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(self, melspectrogram_features):
            # BC1S -> official BCS encoder -> BSC -> the existing BC1S output ABI.
            encoded = self.encoder(melspectrogram_features.squeeze(2))
            return encoded.permute(0, 2, 1).unsqueeze(2).contiguous()

    control = EncoderControl(model.encoder).float().eval()
    example = torch.randn(INPUT_SHAPE, dtype=torch.float32) * 0.4
    second = torch.linspace(-0.8, 1.2, 3000, dtype=torch.float32).view(1, 1, 1, 3000).expand(INPUT_SHAPE).contiguous()
    inputs = [example, second]
    for tensor in inputs:
        tensor_summary(tensor, INPUT_SHAPE, torch)
    traced = torch.jit.trace(control, example, strict=True, check_trace=False).eval()
    parity = []
    for index, tensor in enumerate(inputs):
        expected = control(tensor)
        actual = traced(tensor)
        expected_stats = tensor_summary(expected, OUTPUT_SHAPE, torch)
        actual_stats = tensor_summary(actual, OUTPUT_SHAPE, torch)
        difference = (actual - expected).abs()
        passed = bool(torch.allclose(actual, expected, rtol=1e-5, atol=1e-5))
        parity.append({"case": index, "synthetic_mel": True, "passed": passed,
                       "max_absolute_error": float(difference.max()), "mean_absolute_error": float(difference.mean()),
                       "rtol": 1e-5, "atol": 1e-5, "input": tensor_summary(tensor, INPUT_SHAPE, torch),
                       "official_encoder": expected_stats, "traced_encoder": actual_stats})
        if not passed:
            raise ValueError("Torch traced encoder failed parity with the same official encoder")
    report["trace_parity"] = parity
    trace_path = args.output_root / "encoder-float32-traced.pt"
    traced.save(str(trace_path))
    converted = ct.convert(traced, source="pytorch", convert_to="mlprogram",
                           inputs=[ct.TensorType(name="melspectrogram_features", shape=INPUT_SHAPE, dtype=np.float32)],
                           outputs=[ct.TensorType(name="encoder_output_embeds", dtype=np.float32)],
                           compute_precision=ct.precision.FLOAT32, compute_units=ct.ComputeUnit.CPU_ONLY,
                           minimum_deployment_target=ct.target.iOS16, skip_model_load=True)
    operation_types = Counter()
    float16_values = []
    for function in converted._mil_program.functions.values():
        for operation in function.operations:
            operation_types[operation.op_type] += 1
            float16_values.extend(value.name for value in operation.outputs if value.dtype == types.fp16)
    if float16_values:
        raise ValueError(f"FLOAT32 diagnostic graph unexpectedly contains {len(float16_values)} fp16 values")
    spec = converted.get_spec()
    input_feature, = spec.description.input
    output_feature, = spec.description.output
    if input_feature.name != "melspectrogram_features" or tuple(input_feature.type.multiArrayType.shape) != INPUT_SHAPE:
        raise ValueError("Converted encoder input ABI differs from the App contract")
    if output_feature.name != "encoder_output_embeds" or tuple(output_feature.type.multiArrayType.shape) != OUTPUT_SHAPE:
        raise ValueError("Converted encoder output ABI differs from the App contract")
    from coremltools.proto import FeatureTypes_pb2
    if any(feature.type.multiArrayType.dataType != FeatureTypes_pb2.ArrayFeatureType.FLOAT32 for feature in (input_feature, output_feature)):
        raise ValueError("Converted encoder ABI must use FLOAT32 arrays")
    graph_path = args.output_root / "encoder-float32.mil.txt"
    graph_path.write_text(str(converted._mil_program), encoding="utf-8")
    package_path = args.output_root / "AudioEncoder.mlpackage"
    if package_path.exists():
        raise ValueError("AudioEncoder.mlpackage already exists; refusing to replace it")
    converted.short_description = "Official Whisper base FLOAT32 encoder diagnostic control; ASR quality not yet verified"
    converted.user_defined_metadata["lectureflow.diagnostic_only"] = "true"
    converted.user_defined_metadata["lectureflow.base_sha256"] = BASE_SHA256
    converted.save(str(package_path))
    report["graph"] = {"compute_precision": "FLOAT32", "compute_units_at_conversion": "CPU_ONLY",
                       "use_sdpa": False, "minimum_deployment_target": "iOS16", "specification_version": spec.specificationVersion,
                       "input_name": input_feature.name, "input_shape": list(INPUT_SHAPE),
                       "output_name": output_feature.name, "output_shape": list(OUTPUT_SHAPE),
                       "abi_dtype": "float32", "fp16_value_count": len(float16_values),
                       "operations_by_type": dict(sorted(operation_types.items())),
                       "mil_file": graph_path.name, "mil_sha256": sha256(graph_path),
                       "trace_file": trace_path.name, "trace_sha256": sha256(trace_path)}
    report["package"] = {"path": str(package_path), "files": [
        {"path": path.relative_to(package_path).as_posix(), "bytes": path.stat().st_size, "sha256": sha256(path)}
        for path in sorted(package_path.rglob("*")) if path.is_file()]}
    report["status"] = "exported"
    report["coreml_inference_verified"] = False


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--weights-path", type=Path, help="Existing official base.pt; verified before loading")
    args = parser.parse_args()
    args.output_root = args.output_root.resolve()
    args.output_root.mkdir(parents=True, exist_ok=True)
    script = Path(__file__).resolve()
    report = {"diagnostic_only": True, "synthetic_trace_inputs": True, "asr_acceptance": False,
              "status": "failed", "source_commit": source_commit(script.parent.parent),
              "script_sha256": sha256(script), "python": sys.version, "platform": platform.platform(),
              "pinned_versions": PINNED_VERSIONS,
              "official_sources": {"whisper": "https://pypi.org/project/openai-whisper/20250625/",
                  "coremltools": "https://pypi.org/project/coremltools/9.0/",
                  "compatibility": "https://github.com/apple/coremltools/releases/tag/9.0"}}
    try:
        export(args, report)
        code = 0
    except Exception as error:
        report["error"] = f"{type(error).__name__}: {error}"
        print(report["error"], file=sys.stderr)
        code = 1
    (args.output_root / "ENCODER-EXPORT.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"Encoder diagnostic export status: {report['status']}; manifest: {args.output_root / 'ENCODER-EXPORT.json'}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
