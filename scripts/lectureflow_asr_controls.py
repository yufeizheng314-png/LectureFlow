#!/usr/bin/env python3
"""Independent off-device ASR controls, not LectureFlow acceptance.

Run the tracked JFK recording and the same natural-English water-cycle synthesis
with and without timestamps using the repository CLI and multilingual base.
No microphone, personal API Key, cloud notes or voice installation is used.
Public Core ML and tokenizer files may be downloaded into the shared smoke cache.
"""
import argparse
import datetime
import json
from pathlib import Path
import platform
import re
import shutil
import subprocess

import lectureflow_asr_smoke as smoke


MODES = ("word_timestamps", "without_timestamps")
FIXTURES = {
    "jfk": {
        "synthetic": False,
        "keywords": {"Americans": ["americans"], "country": ["country"],
                     "ask": ["ask"], "fellow": ["fellow"]},
        "description": "Tracked upstream JFK speech fixture, not a personal recording",
    },
    "water_cycle": {
        "synthetic": True,
        "keywords": smoke.CASES["en"]["keywords"],
        "description": "Natural system say voice, same water-cycle text as the full smoke",
    },
}


def cli_arguments(cli, audio, report_dir, cache, model_path, compute_units, mode):
    if mode not in MODES:
        raise ValueError("Unknown control mode")
    argv = [cli, "transcribe", "--audio-path", audio, "--language", "en", "--task", "transcribe",
            "--skip-special-tokens", "--report", "--report-path", report_dir,
            "--download-tokenizer-path", cache / "tokenizers", "--verbose", "--diagnostic-tensors",
            "--use-prefill-prompt", "--temperature-fallback-count", "1", "--concurrent-worker-count", "1",
            "--chunking-strategy", "none", "--first-token-log-prob-threshold=-1.5",
            "--mel-compute-units", compute_units, "--audio-encoder-compute-units", compute_units,
            "--text-decoder-compute-units", compute_units]
    argv.append("--word-timestamps" if mode == "word_timestamps" else "--without-timestamps")
    # Keep MLTensor's default policy for both modes; this is a separate control
    # from the previous all-CPU + explicit MLTensor CPU diagnostic.
    if model_path is not None:
        argv += ["--model-path", model_path]
    else:
        argv += ["--model", "base", "--model-prefix", "openai", "--download-model-path", cache / "models"]
    return argv


def evaluate_transcript(result, keywords):
    text = result.get("text")
    if not isinstance(text, str):
        raise ValueError("CLI JSON report has no string transcription")
    words = set(re.findall(r"[a-z]+", text.casefold()))
    hits = {name: any(alias.casefold() in words for alias in aliases) for name, aliases in keywords.items()}
    usable = bool(text.strip()) and result.get("language") == "en" and sum(hits.values()) >= 2
    return text, hits, usable


def run(args, report, repo, output):
    if platform.system() != "Darwin":
        raise RuntimeError("Blocked: macOS say, afconvert and Core ML are required")
    cache = args.cache.resolve()
    cache.mkdir(parents=True, exist_ok=True)
    model_path = args.model_path.resolve() if args.model_path else smoke.cached_base_model(cache)
    if model_path and (not smoke.valid_model_folder(model_path) or model_path.name != "openai_whisper-base"):
        raise RuntimeError("Blocked: model path must be the complete multilingual openai_whisper-base folder")
    if args.cli:
        cli = args.cli.resolve()
    else:
        report["cli_build_seconds"] = smoke.command(
            ["swift", "build", "--disable-automatic-resolution", "-c", "release", "--product", "whisperkit-cli"],
            output / "cli-build.log", args.build_timeout, repo)
        location = subprocess.run(["swift", "build", "--disable-automatic-resolution", "-c", "release", "--show-bin-path"],
                                  cwd=repo, capture_output=True, text=True, timeout=60, check=True)
        cli = Path(location.stdout.strip()) / "whisperkit-cli"
    if not cli.is_file():
        raise RuntimeError("Blocked: repository CLI executable was not produced")

    audio = {}
    source_errors = {}
    jfk = repo / "Tests/WhisperKitTests/Resources/jfk.wav"
    report["jfk_source_sha256"] = smoke.sha256(jfk)
    jfk_copy = output / "jfk.wav"
    shutil.copyfile(jfk, jfk_copy)
    smoke.stats(jfk_copy)
    audio["jfk"] = jfk_copy
    voices = smoke.installed_voices()
    voice = smoke.choose_voice(voices, "en")
    report["selected_english_voice"] = voice
    text_file = output / "water-cycle-source.txt"
    text_file.write_text(smoke.CASES["en"]["text"] + "\n", encoding="utf-8")
    if voice is None:
        source_errors["water_cycle"] = "No installed preferred natural English voice; no installation attempted"
    else:
        try:
            aiff = output / "water-cycle-say.aiff"
            converted = output / "water-cycle-converted.wav"
            clear = output / "water-cycle.wav"
            smoke.command(["/usr/bin/say", "-v", voice["name"], "-r", "160", "-f", text_file, "-o", aiff],
                          output / "say.log", 120, repo)
            smoke.command(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff, converted],
                          output / "convert.log", 60, repo)
            smoke.write_pcm(clear, smoke.pcm(converted))
            audio["water_cycle"] = clear
        except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
            source_errors["water_cycle"] = str(error)

    for fixture, metadata in FIXTURES.items():
        for mode in MODES:
            case = {"fixture": fixture, "mode": mode, "off_device": True, "synthetic": metadata["synthetic"],
                    "description": metadata["description"], "status": "blocked"}
            report["cases"].append(case)
            if fixture not in audio:
                case["reason"] = source_errors.get(fixture, "Audio fixture was not prepared")
                continue
            submitted = audio[fixture]
            original_sha = smoke.sha256(submitted)
            case["audio_stats"] = smoke.stats(submitted)
            case["audio_file"] = submitted.name
            report_dir = output / f"{fixture}-{mode}-reports"
            report_dir.mkdir()
            argv = cli_arguments(cli, submitted, report_dir, cache, model_path, args.compute_units, mode)
            case["cli_arguments"] = [str(value) for value in argv]
            try:
                case["elapsed_seconds"] = smoke.command(argv, output / f"{fixture}-{mode}-cli.log", args.cli_timeout, repo)
                raw_report = report_dir / (submitted.stem + ".json")
                result = json.loads(raw_report.read_text(encoding="utf-8"))
                text, hits, usable = evaluate_transcript(result, metadata["keywords"])
                case.update({"transcript": text, "reported_language": result.get("language"), "keyword_hits": hits,
                             "keyword_hit_count": sum(hits.values()), "cli_report": str(raw_report.relative_to(output)),
                             "status": "passed" if usable else "failed"})
                (output / f"{fixture}-{mode}-transcript.txt").write_text(text + "\n", encoding="utf-8")
            except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
                case["reason"] = str(error)
            finally:
                case["audio_preserved"] = smoke.sha256(submitted) == original_sha
                if not case["audio_preserved"]:
                    case["status"] = "failed"
                    case["reason"] = "Inference changed the control audio"
                model_path = model_path or smoke.cached_base_model(cache)
                report["model_path"] = str(model_path) if model_path else None
            if model_path is None and case["status"] == "blocked":
                raise RuntimeError("Initial model/inference setup blocked; remaining controls were not executed")
    report["jfk_source_preserved"] = smoke.sha256(jfk) == report["jfk_source_sha256"]
    if not report["jfk_source_preserved"]:
        raise RuntimeError("Tracked JFK source changed during the controls")
    if model_path:
        report["model_files"] = [
            {"path": str(path.relative_to(model_path)), "bytes": path.stat().st_size, "sha256": smoke.sha256(path)}
            for component in ("MelSpectrogram", "AudioEncoder", "TextDecoder")
            for path in sorted((model_path / f"{component}.mlmodelc").rglob("*")) if path.is_file()
        ]


def main():
    repo = Path(__file__).resolve().parent.parent
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=repo / "build/asr-controls")
    parser.add_argument("--cache", type=Path, default=repo / ".build/lectureflow-asr-cache")
    parser.add_argument("--cli", type=Path, help="Already-built repository whisperkit-cli")
    parser.add_argument("--model-path", type=Path, help="Complete multilingual openai_whisper-base cache folder")
    parser.add_argument("--compute-units", choices=("cpuAndGPU", "cpuOnly", "cpuAndNeuralEngine"), default="cpuAndGPU")
    parser.add_argument("--build-timeout", type=int, default=900)
    parser.add_argument("--cli-timeout", type=int, default=600)
    args = parser.parse_args()
    if min(args.build_timeout, args.cli_timeout) <= 0:
        parser.error("Timeouts must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        parser.error("Output directory must be empty; use a new --output directory")
    report = {"diagnostic_only": True, "off_device": True, "replaces_full_smoke": False, "expected_case_count": 4,
              "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "cases": [],
              "model": "multilingual openai_whisper-base", "compute_units": args.compute_units,
              "tensor_compute_policy": "default", "minimum_keyword_hits": 2,
              "decoding_configuration": {"temperature_fallback_count": 1, "concurrent_worker_count": 1,
                                         "chunking_strategy": "none", "use_prefill_prompt": True,
                                         "first_token_log_prob_threshold": -1.5},
              "scope": "Independent JFK and natural English controls with/without timestamps. Actual repository CLI inference only. This does not verify bilingual/low-volume full smoke, microphone windows, iPad performance, teacher audio or cloud AI quality."}
    try:
        commit = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo, capture_output=True, text=True, timeout=10, check=True)
        report["source_commit"] = commit.stdout.strip()
        evidence = ["scripts/lectureflow_asr_controls.py", "scripts/lectureflow_asr_smoke.py",
                    "Sources/ArgmaxCLI/TranscribeCLI.swift", "Sources/ArgmaxCLI/TranscribeCLIArguments.swift",
                    "Sources/ArgmaxCLI/TranscribeCLIUtils.swift", "Sources/WhisperKit/Core/TextDecoder.swift",
                    "Sources/WhisperKit/Core/Text/TokenSampler.swift", "Sources/WhisperKit/Core/Text/LogitsFilter.swift",
                    "Sources/WhisperKit/Core/FeatureExtractor.swift", "Sources/WhisperKit/Core/AudioEncoder.swift",
                    "Sources/WhisperKit/Core/Audio/AudioProcessor.swift", "Sources/WhisperKit/Core/WhisperKit.swift"]
        report["source_sha256"] = {relative: smoke.sha256(repo / relative) for relative in evidence}
        run(args, report, repo, output)
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        report["infrastructure_error"] = str(error)
    recorded = {(case["fixture"], case["mode"]) for case in report["cases"]}
    for fixture in FIXTURES:
        for mode in MODES:
            if (fixture, mode) not in recorded:
                report["cases"].append({"fixture": fixture, "mode": mode, "status": "blocked",
                                        "reason": "Not executed because setup was blocked"})
    statuses = [case["status"] for case in report["cases"]]
    report["status"] = "passed" if len(statuses) == 4 and all(status == "passed" for status in statuses) and "infrastructure_error" not in report else "failed" if "failed" in statuses else "blocked"
    report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / "ASR-CONTROLS.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lines = ["LectureFlow independent off-device ASR controls (not full smoke or acceptance)",
             f"Status: {report['status']}", f"Core ML compute: {args.compute_units}; MLTensor: default", report["scope"], ""]
    for case in report["cases"]:
        lines += [f"{case['fixture']} / {case['mode']}: {case['status']}",
                  "Keyword hits: " + json.dumps(case.get("keyword_hits", {})),
                  "Actual transcription: " + case.get("transcript", "[no verified transcription]"), case.get("reason", ""), ""]
    if "infrastructure_error" in report:
        lines.append(report["infrastructure_error"])
    (output / "ASR-CONTROLS.txt").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Independent ASR controls only: {report['status']}; {output / 'ASR-CONTROLS.json'}")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
