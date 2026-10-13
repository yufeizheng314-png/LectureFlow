#!/usr/bin/env python3
"""Synthetic, off-device EN/ZH smoke test using the repository's real CLI.

macOS only. No personal API Key, voice installation, microphone, cloud notes,
or iPad acceptance is involved. Public Core ML/tokenizer downloads may occur.
Run: python3 scripts/lectureflow_asr_smoke.py --output build/asr-smoke
"""
import argparse
import array
import datetime
import hashlib
import json
import math
from pathlib import Path
import platform
import re
import subprocess
import sys
import time
import wave


CASES = {
    "en": {
        "text": "The Sun provides energy for the water cycle. Evaporation turns liquid water into water vapor, and cooling causes condensation that forms clouds. Precipitation returns water to rivers and oceans, so the water cycle repeats.",
        "keywords": {"water": ["water"], "evaporation": ["evaporation"], "condensation": ["condensation"], "precipitation": ["precipitation"]},
    },
    "zh": {
        "text": "太阳为水循环提供能量。蒸发使液态水成为水蒸气，水蒸气冷却后凝结成小水滴，形成云。降水使水返回河流和海洋，水循环不断重复。",
        "keywords": {"水循环": ["水循环", "水循環"], "蒸发": ["蒸发", "蒸發"], "凝结": ["凝结", "凝結"], "降水": ["降水"]},
    },
}


def sha256(path):
    with path.open("rb") as file:
        return hashlib.file_digest(file, "sha256").hexdigest() if hasattr(hashlib, "file_digest") else hashlib.sha256(file.read()).hexdigest()


def command(args, log, timeout, cwd):
    start = time.monotonic()
    with log.open("w", encoding="utf-8") as file:
        file.write("$ " + json.dumps([str(item) for item in args], ensure_ascii=False) + "\n")
        file.flush()
        try:
            result = subprocess.run([str(item) for item in args], cwd=cwd, stdout=file, stderr=subprocess.STDOUT, timeout=timeout, check=False)
        except subprocess.TimeoutExpired as error:
            raise RuntimeError(f"Timed out after {timeout}s; see {log.name}") from error
    if result.returncode:
        raise RuntimeError(f"Command exited {result.returncode}; see {log.name}")
    return round(time.monotonic() - start, 3)


def pcm(path):
    with wave.open(str(path), "rb") as file:
        if (file.getnchannels(), file.getsampwidth(), file.getframerate(), file.getcomptype()) != (1, 2, 16000, "NONE"):
            raise RuntimeError("Expected PCM16 mono 16000 Hz WAV")
        data = file.readframes(file.getnframes())
    samples = array.array("h")
    samples.frombytes(data)
    if sys.byteorder != "little":
        samples.byteswap()
    if not samples:
        raise RuntimeError("Empty audio")
    return samples


def write_pcm(path, samples):
    copy = array.array("h", samples)
    if sys.byteorder != "little":
        copy.byteswap()
    with wave.open(str(path), "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(16000)
        file.writeframes(copy.tobytes())


def stats(path):
    samples = pcm(path)
    rms = math.sqrt(sum((sample / 32768.0) ** 2 for sample in samples) / len(samples))
    peak = max(abs(sample) / 32768.0 for sample in samples)
    return {"frames": len(samples), "duration_seconds": round(len(samples) / 16000.0, 3), "sample_rate": 16000,
            "channels": 1, "sample_width_bits": 16, "rms": rms, "peak": peak, "sha256": sha256(path)}


def installed_voices():
    result = subprocess.run(["/usr/bin/say", "-v", "?"], capture_output=True, text=True, timeout=30, check=True)
    voices = []
    for line in result.stdout.splitlines():
        match = re.match(r"^(.+?)\s+([a-z]{2}_[A-Z]{2})\s+#", line)
        if match:
            voices.append({"name": match.group(1).strip(), "locale": match.group(2)})
    return voices


def choose_voice(voices, language):
    # say's locale ordering includes novelty voices (for example Albert) and
    # does not imply suitability for classroom speech. Prefer natural voices.
    preferred = {
        "en": [("Samantha", "en_US"), ("Daniel", "en_GB"), ("Karen", "en_AU"),
               ("Alex", "en_US"), ("Victoria", "en_US"), ("Moira", "en_IE"), ("Tessa", "en_ZA")],
        "zh": [("Tingting", "zh_CN"), ("Meijia", "zh_TW")],
    }
    for name, locale in preferred.get(language, []):
        for voice in voices:
            base_name = voice["name"].split(" (")[0].casefold()
            if base_name == name.casefold() and voice["locale"] == locale:
                return voice
    return None


def valid_model_folder(path):
    # Hub metadata mirrors the model directory names but contains download
    # bookkeeping rather than loadable Core ML models. Never reuse that tree.
    if not path.is_dir() or any(part in {".cache", ".git"} for part in path.parts):
        return False
    for component in ("MelSpectrogram", "AudioEncoder", "TextDecoder"):
        model = path / (component + ".mlmodelc")
        core = model / "coremldata.bin"
        if not model.is_dir() or not core.is_file() or core.stat().st_size == 0:
            return False
    return True


def cached_base_model(cache):
    candidates = sorted(path.parent for path in (cache / "models").rglob("MelSpectrogram.mlmodelc")
                        if path.parent.name == "openai_whisper-base" and valid_model_folder(path.parent))
    return candidates[0] if candidates else None


def run(args, report, repo, output):
    if platform.system() != "Darwin":
        raise RuntimeError("Blocked: macOS say, afconvert and Core ML are required")
    voices = installed_voices()
    report["available_voices"] = voices
    selected = {language: choose_voice(voices, language) for language in CASES}
    report["selected_voices"] = selected
    for language, voice in selected.items():
        if voice is None:
            for volume in ("clear", "low"):
                report["cases"].append({"language": language, "volume": volume, "status": "blocked", "reason": "No installed preferred natural voice in this language; no voice installation attempted"})
    if not any(selected.values()):
        return
    transform = output / "asr-transform"
    sources = repo / "Examples/WhisperAX/WhisperAX/LectureFlow"
    report["transform_build_seconds"] = command(["swiftc", "-swift-version", "5", "-parse-as-library", sources / "LectureAudioCore.swift",
                                                 sources / "LecturePCMStore.swift", repo / "scripts/LectureFlowASRTransform.swift", "-o", transform],
                                                output / "transform-build.log", args.build_timeout, repo)
    if args.cli:
        cli = args.cli.resolve()
    else:
        report["cli_build_seconds"] = command(["swift", "build", "--disable-automatic-resolution", "-c", "release", "--product", "whisperkit-cli"], output / "cli-build.log", args.build_timeout, repo)
        location = subprocess.run(["swift", "build", "-c", "release", "--show-bin-path"], cwd=repo, capture_output=True, text=True, timeout=60, check=True)
        cli = Path(location.stdout.strip()) / "whisperkit-cli"
    if not cli.is_file():
        raise RuntimeError("Blocked: the repository CLI executable was not produced")
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    model_path = args.model_path.resolve() if args.model_path else None
    if model_path and (not valid_model_folder(model_path) or "base.en" in model_path.name or "base" not in model_path.name):
        raise RuntimeError("Blocked: --model-path must contain complete multilingual base Core ML models, not metadata or base.en")
    for language, fixture in CASES.items():
        voice = selected[language]
        if voice is None:
            continue
        text_path = output / f"{language}-source.txt"
        text_path.write_text(fixture["text"] + "\n", encoding="utf-8")
        generated = output / f"{language}-say.aiff"
        converted = output / f"{language}-converted.wav"
        clear = output / f"{language}-clear.wav"
        try:
            command(["/usr/bin/say", "-v", voice["name"], "-r", "160", "-f", text_path, "-o", generated], output / f"{language}-say.log", 120, repo)
            command(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", generated, converted], output / f"{language}-convert.log", 60, repo)
            # Canonical WAV container for the production store's fixed header.
            samples = pcm(converted)
            write_pcm(clear, samples)
            low = output / f"{language}-low-original.wav"
            attenuation = 10 ** (args.low_db / 20.0)
            write_pcm(low, [round(sample * attenuation) for sample in samples])
            inference = output / f"{language}-low-inference.wav"
            metadata = output / f"{language}-gain.json"
            source_hash = sha256(low)
            command([transform, low, inference, metadata], output / f"{language}-transform.log", 60, repo)
            if sha256(low) != source_hash:
                raise RuntimeError("Production inference preprocessing changed the source WAV")
            gain = json.loads(metadata.read_text(encoding="utf-8"))
            for volume, original, submitted in (("clear", clear, clear), ("low", low, inference)):
                case = {"language": language, "volume": volume, "synthetic": True, "off_device": True, "status": "blocked",
                        "voice": voice, "original_audio": original.name, "inference_audio": submitted.name,
                        "original_audio_stats": stats(original), "inference_audio_stats": stats(submitted)}
                if volume == "low":
                    case.update({"attenuation_db": args.low_db, "production_gain": gain, "original_preserved": sha256(low) == source_hash})
                report["cases"].append(case)
                report_dir = output / f"{language}-{volume}-reports"
                report_dir.mkdir()
                argv = [cli, "transcribe", "--audio-path", submitted, "--language", language, "--task", "transcribe", "--skip-special-tokens",
                        "--word-timestamps", "--report", "--report-path", report_dir, "--download-tokenizer-path", cache / "tokenizers",
                        "--audio-encoder-compute-units", "cpuAndGPU", "--text-decoder-compute-units", "cpuAndGPU"]
                if model_path is not None and not valid_model_folder(model_path):
                    model_path = None
                if model_path:
                    argv += ["--model-path", model_path]
                else:
                    argv += ["--model", "base", "--model-prefix", "openai", "--download-model-path", cache / "models"]
                try:
                    case["elapsed_seconds"] = command(argv, output / f"{language}-{volume}-cli.log", args.cli_timeout, repo)
                    raw_report = report_dir / (submitted.stem + ".json")
                    result = json.loads(raw_report.read_text(encoding="utf-8"))
                    transcript = result.get("text", "")
                    if not isinstance(transcript, str):
                        raise ValueError("CLI report text is not a string")
                    normalized = re.sub(r"\s+", "", transcript.casefold())
                    hits = {concept: any(alias.casefold() in normalized for alias in aliases) for concept, aliases in fixture["keywords"].items()}
                    case.update({"transcript": transcript, "reported_language": result.get("language"), "keyword_hits": hits,
                                 "keyword_hit_count": sum(hits.values()), "cli_report": str(raw_report.relative_to(output))})
                    case["status"] = "passed" if transcript.strip() and result.get("language") == language and sum(hits.values()) >= args.min_keyword_hits else "failed"
                    (output / f"{language}-{volume}-transcript.txt").write_text(transcript + "\n", encoding="utf-8")
                    if model_path is None:
                        model_path = cached_base_model(cache)
                    report["model_path"] = str(model_path) if model_path else "downloaded via CLI base selector"
                except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
                    case["reason"] = str(error)
                    if model_path is None:
                        # Avoid spending four timeout periods on the same initial
                        # model/tokenizer download or Core ML setup failure.
                        report["infrastructure_error"] = "Initial model/inference setup could not be verified; remaining cases were not run"
                        return
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
            for volume in ("clear", "low"):
                report["cases"].append({"language": language, "volume": volume, "status": "blocked", "reason": str(error)})


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=repo / "build/asr-smoke")
    parser.add_argument("--cache", type=Path, default=repo / ".build/lectureflow-asr-cache")
    parser.add_argument("--cli", type=Path, help="An already-built repository whisperkit-cli executable")
    parser.add_argument("--model-path", type=Path, help="An existing multilingual openai_whisper-base folder")
    parser.add_argument("--low-db", type=float, default=-24.0)
    parser.add_argument("--min-keyword-hits", type=int, choices=range(2, 5), default=2)
    parser.add_argument("--build-timeout", type=int, default=900)
    parser.add_argument("--cli-timeout", type=int, default=600)
    args = parser.parse_args()
    if not math.isfinite(args.low_db) or not -40 <= args.low_db <= -6 or min(args.build_timeout, args.cli_timeout) <= 0:
        parser.error("Use low-db between -40 and -6, and positive timeouts")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    # Do not reuse stale audio or reports as evidence for a new run.
    if any(output.iterdir()):
        parser.error("Output directory must be empty; choose a new --output directory")
    report = {"synthetic": True, "off_device": True, "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "model": "multilingual openai_whisper-base", "minimum_keyword_hits": args.min_keyword_hits, "cases": [],
              "scope": "Real repository CLI inference on local system-synthesized speech. Low copies use production normalization and PCM store in bounded file windows. No microphone, teacher recording, iPad ownership/latency, cloud AI quality or device acceptance is tested."}
    try:
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, timeout=10, check=True)
        report["source_commit"] = commit.stdout.strip()
        evidence_sources = [
            "Examples/WhisperAX/WhisperAX/LectureFlow/LectureAudioCore.swift",
            "Examples/WhisperAX/WhisperAX/LectureFlow/LecturePCMStore.swift",
            "Examples/WhisperAX/WhisperAX/LectureFlow/LectureAudioSession.swift",
            "Examples/WhisperAX/WhisperAX/LectureFlow/LectureFlowModel.swift",
            "scripts/lectureflow_asr_smoke.py",
            "scripts/LectureFlowASRTransform.swift",
        ]
        report["source_sha256"] = {relative: sha256(repo / relative) for relative in evidence_sources}
        run(args, report, repo, output)
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        report["infrastructure_error"] = str(error)
    recorded = {(case["language"], case["volume"]) for case in report["cases"]}
    for language in CASES:
        for volume in ("clear", "low"):
            if (language, volume) not in recorded:
                report["cases"].append({"language": language, "volume": volume, "status": "blocked", "reason": "Not executed because preceding setup was blocked"})
    statuses = [case["status"] for case in report["cases"]]
    report["status"] = "passed" if len(statuses) == 4 and all(status == "passed" for status in statuses) and "infrastructure_error" not in report else "failed" if "failed" in statuses else "blocked"
    report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / "ASR-SMOKE.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["LectureFlow synthetic / off_device ASR smoke test", f"Status: {report['status']}", report["scope"], ""]
    for case in report["cases"]:
        lines += [f"{case['language']} / {case['volume']}: {case['status']}", f"Keyword hits: {case.get('keyword_hits', {})}",
                  "Actual transcription: " + case.get("transcript", "[no verified transcription]"), case.get("reason", ""), ""]
    if "infrastructure_error" in report:
        lines.append(report["infrastructure_error"])
    (output / "ASR-SMOKE.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Synthetic off_device ASR smoke: {report['status']}; report: {output / 'ASR-SMOKE.json'}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
