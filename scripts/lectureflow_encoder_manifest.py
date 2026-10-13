#!/usr/bin/env python3
"""Bind the bundled FLOAT32 encoder to its exported source and compiled files."""
import argparse
import hashlib
import json
from pathlib import Path

BASE_SHA256 = "ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e"
NAME = "lectureflow-encoder-manifest.json"


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model-folder", required=True, type=Path)
    parser.add_argument("--export-manifest", required=True, type=Path)
    args = parser.parse_args()
    root = args.model_folder.resolve(strict=True)
    assert root.is_dir() and root.suffix == ".mlmodelc"
    assert (root / "coremldata.bin").is_file()
    manifest = root / NAME
    assert not manifest.exists(), "Refusing to replace a bundled encoder manifest"
    source = json.loads(args.export_manifest.read_text(encoding="utf-8"))
    assert source["status"] == "exported"
    assert source["weights"]["sha256"] == BASE_SHA256
    assert source["graph"]["compute_precision"] == "FLOAT32"
    assert source["graph"]["fp16_value_count"] == 0
    assert source["graph"]["input_shape"] == [1, 80, 1, 3000]
    assert source["graph"]["output_shape"] == [1, 512, 1, 1500]
    assert len(source["trace_parity"]) == 2 and all(case["passed"] for case in source["trace_parity"])
    files = []
    for path in sorted(root.rglob("*")):
        assert not path.is_symlink(), "Bundled encoder cannot contain symlinks"
        if path.is_file():
            files.append({"path": path.relative_to(root).as_posix(), "bytes": path.stat().st_size, "sha256": sha256(path)})
    assert files and any(file["bytes"] > 1_000_000 for file in files), "Missing compiled model weights"
    result = {"schema_version": 1, "model": "openai/whisper-base", "compute_precision": "FLOAT32",
              "base_sha256": BASE_SHA256, "input_shape": [1, 80, 1, 3000], "output_shape": [1, 512, 1, 1500],
              "source_commit": source["source_commit"], "export_script_sha256": source["script_sha256"],
              "package_files": source["package"]["files"], "files": files}
    manifest.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Bundled encoder manifest: {manifest}; {len(files)} compiled files, {sum(file['bytes'] for file in files)} bytes")


if __name__ == "__main__":
    main()
