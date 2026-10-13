//  For licensing see accompanying LICENSE.md file.
//  Copyright © 2024 Argmax, Inc. All rights reserved.

import ArgumentParser
import CoreML
import Foundation
import SpeakerKit
import WhisperKit
import TTSKit

struct TranscribeCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe audio to text using WhisperKit"
    )

    @OptionGroup
    var cliArguments: TranscribeCLIArguments

    @Flag(name: .long, help: "Enable speaker diarization")
    var diarization: Bool = false

    @Option(name: .long, help: "Number of speakers for diarization (default: automatic)")
    var diarizationNumSpeakers: Int?

    @Option(name: .long, help: "Path to diarization model files (skips download)")
    var diarizationModelPath: String?

    @Option(name: .long, help: "HuggingFace repo for diarization models")
    var diarizationModelRepo: String?

    mutating func validate() throws {
        if let language = cliArguments.language {
            if !Constants.languages.values.contains(language) {
                throw ValidationError("Invalid language code \"\(language)\". Supported languages: \(Constants.languages.values)")
            }
        }

        if cliArguments.audioPath.isEmpty && !cliArguments.stream {
            guard let audioFolder = cliArguments.audioFolder else {
                throw ValidationError("Either audioPath or audioFolder must be provided.")
            }
            let fileManager = FileManager.default
            let audioExtensions = ["mp3", "wav", "m4a", "flac", "aiff", "aac"]
            let audioFiles = try fileManager.contentsOfDirectory(atPath: audioFolder)
                .filter { fileName in
                    let fileExtension = fileName.lowercased().components(separatedBy: ".").last
                    return audioExtensions.contains(fileExtension ?? "")
                }

            cliArguments.audioPath = audioFiles.map { audioFolder + "/" + $0 }
        }

        if ChunkingStrategy(rawValue: cliArguments.chunkingStrategy) == nil {
            throw ValidationError("Wrong chunking strategy \"\(cliArguments.chunkingStrategy)\", valid strategies: \(ChunkingStrategy.allCases.map { $0.rawValue })")
        }

        if cliArguments.incrementalLoading {
            if let duration = cliArguments.incrementalChunkDuration {
                guard duration.isFinite, duration > 0 else {
                    throw ValidationError("--incremental-chunk-duration must be greater than 0")
                }
            }

            if let bufferSize = cliArguments.incrementalChunkBufferSize {
                guard bufferSize > 0 else {
                    throw ValidationError("--incremental-chunk-buffer-size must be greater than 0")
                }
            }

            guard cliArguments.clipTimestamps.isEmpty else {
                throw ValidationError("--clip-timestamps is not supported with --incremental-loading")
            }
        }
    }

    mutating func run() async throws {
        if cliArguments.verbose {
            Logging.shared.logLevel = .debug
            Logging.shared.loggingCallback = { print($0) }
        }
        if cliArguments.stream {
            try await transcribeStream()
        } else if cliArguments.streamSimulated {
            try await transcribeStreamSimulated()
        } else {
            try await transcribe()
        }
    }

    private func transcribe() async throws {
        if cliArguments.verbose {
            print("\nStarting transcription process...")
        }

        let resolvedAudioPaths = cliArguments.audioPath.map { FileManager.resolveAbsolutePath($0) }
        if cliArguments.verbose {
            print("\nResolved audio paths:")
            resolvedAudioPaths.forEach { print("  - \($0)") }
        }

        for resolvedAudioPath in resolvedAudioPaths {
            guard FileManager.default.fileExists(atPath: resolvedAudioPath) else {
                if cliArguments.verbose {
                    print("\nError: File not found at path: \(resolvedAudioPath)")
                }
                throw CocoaError.error(.fileNoSuchFile)
            }
        }

        let task: DecodingTask
        if cliArguments.task.lowercased() == "translate" {
            task = .translate
            if cliArguments.verbose {
                print("\nUsing translation task")
            }
        } else {
            task = .transcribe
            if cliArguments.verbose {
                print("\nUsing transcription task")
            }
        }

        if cliArguments.verbose {
            print("Task: \(task.description.capitalized) audio at \(cliArguments.audioPath)")
            print("Initializing models...")
        }

        let config = TranscribeCLIUtils.createWhisperKitConfig(from: cliArguments)
        let whisperKit = try await WhisperKit(config)

        if cliArguments.diagnosticTensors {
            print("Diagnostic model: \(whisperKit.modelVariant), multilingual: \(whisperKit.textDecoder.isModelMultilingual), mel bands: \(String(describing: whisperKit.featureExtractor.melCount)), encoder dimension: \(String(describing: whisperKit.audioEncoder.embedSize)), decoder cache dimension: \(String(describing: whisperKit.textDecoder.kvCacheEmbedDim))")
            for path in resolvedAudioPaths {
                let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: path, endTime: 30)
                let rms = sqrt(audio.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, audio.count)))
                print("Diagnostic decoded audio: frames=\(audio.count), rms=\(rms), peak=\(audio.map { abs($0) }.max() ?? 0)")
                if let padded = AudioProcessor.padOrTrimAudio(fromArray: audio),
                   let mel = try await whisperKit.featureExtractor.logMelSpectrogram(fromAudio: padded) as? MLMultiArray,
                   let encoded = try await whisperKit.audioEncoder.encodeFeatures(mel) as? MLMultiArray {
                    printDiagnosticTensor(mel, name: "mel")
                    printDiagnosticTensor(encoded, name: "encoder")
                    if let tokenizer = whisperKit.tokenizer,
                       let inputs = try whisperKit.textDecoder.prepareDecoderInputs(withPrompt: [tokenizer.specialTokens.startOfTranscriptToken]) as? DecodingInputs {
                        inputs.inputIds[0] = NSNumber(value: tokenizer.specialTokens.startOfTranscriptToken)
                        for (name, tensor) in [("key-input", inputs.keyCache), ("value-input", inputs.valueCache),
                                               ("padding-mask", inputs.decoderKeyPaddingMask), ("update-mask", inputs.kvCacheUpdateMask)] {
                            printDiagnosticTensor(tensor, name: name)
                        }
                        let predicted = try await whisperKit.textDecoder.predictLogits(TextDecoderMLMultiArrayInputType(
                            inputIds: inputs.inputIds, cacheLength: inputs.cacheLength, keyCache: inputs.keyCache,
                            valueCache: inputs.valueCache, kvCacheUpdateMask: inputs.kvCacheUpdateMask,
                            encoderOutputEmbeds: encoded, decoderKeyPaddingMask: inputs.decoderKeyPaddingMask)) as? TextDecoderMLMultiArrayOutputType
                        if let logits = predicted?.logits {
                            printDiagnosticTensor(logits, name: "raw-SOT-logits")
                            let top = (0..<logits.count).map { ($0, logits[$0].doubleValue) }.sorted { $0.1 > $1.1 }.prefix(5)
                            print("Diagnostic SOT top logits: \(top.map { "\($0.0):\($0.1):\(tokenizer.decode(tokens: [$0.0]))" })")
                        }
                        if let key = predicted?.cache?.keyCache {
                            printDiagnosticTensor(key, name: "key-output")
                            printDiagnosticBufferLayout(key, name: "key-output")
                        }
                        if let value = predicted?.cache?.valueCache {
                            printDiagnosticTensor(value, name: "value-output")
                            printDiagnosticBufferLayout(value, name: "value-output")
                        }
                    }
                }
            }
        }

        if cliArguments.verbose {
            print("\nModel initialization complete:")
            print("  - Model folder: \(whisperKit.modelFolder?.path ?? "Not specified")")
            print("  - Tokenizer folder: \(whisperKit.tokenizerFolder?.path ?? "Not specified")")
            print("  - Total load time: \(String(format: "%.2f", whisperKit.currentTimings.modelLoading)) seconds")
            print("  - Encoder load time: \(String(format: "%.2f", whisperKit.currentTimings.encoderLoadTime)) seconds")
            print("  - Decoder load time: \(String(format: "%.2f", whisperKit.currentTimings.decoderLoadTime)) seconds")
            print("  - Tokenizer load time: \(String(format: "%.2f", whisperKit.currentTimings.tokenizerLoadTime)) seconds")
        }

        var options = TranscribeCLIUtils.createDecodingOptions(from: cliArguments, task: task)
        if diarization {
            options.wordTimestamps = true
        }
        if cliArguments.verbose {
            print("\nConfiguring decoding options...")
        }
        let audioInputOptions = TranscribeCLIUtils.createAudioInputOptions(from: cliArguments)
        if cliArguments.verbose {
            switch audioInputOptions.audioLoadingMode {
            case .fullFile:
                print("File loading mode: full file")
            case .incremental(let chunkDurationSeconds, let maxBufferedChunks):
                print("File loading mode: incremental")
                print(String(format: "  - Chunk duration: %.2f seconds", chunkDurationSeconds))
                print("  - Chunk buffer size: \(maxBufferedChunks)")
                print("  - VAD boundary detection: enabled")
            }
        }

        if let promptText = cliArguments.prompt, promptText.count > 0, let tokenizer = whisperKit.tokenizer {
            if cliArguments.verbose {
                print("Processing prompt text: \"\(promptText)\"")
            }
            options.promptTokens = tokenizer.encode(text: " " + promptText.trimmingCharacters(in: .whitespaces)).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
            if cliArguments.verbose {
                print("Encoded prompt tokens: \(options.promptTokens ?? [])")
            }
        }

        if let prefixText = cliArguments.prefix, prefixText.count > 0, let tokenizer = whisperKit.tokenizer {
            if cliArguments.verbose {
                print("Processing prefix text: \"\(prefixText)\"")
            }
            options.prefixTokens = tokenizer.encode(text: " " + prefixText.trimmingCharacters(in: .whitespaces)).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
            if cliArguments.verbose {
                print("Encoded prefix tokens: \(options.prefixTokens ?? [])")
            }
        }

        // Record the start time
        let startTime = Date()
        
        // Actor to manage shared state safely
        actor ProgressState {
            var isTranscribing = true
            var emaEstimatedTotalTime: TimeInterval = 0
            
            func stopTranscribing() {
                isTranscribing = false
            }
            
            func updateEmaEstimatedTotalTime(_ newValue: TimeInterval, smoothingFactor: Double) {
                if emaEstimatedTotalTime == 0 {
                    emaEstimatedTotalTime = newValue
                } else {
                    emaEstimatedTotalTime = smoothingFactor * newValue + (1 - smoothingFactor) * emaEstimatedTotalTime
                }
            }
            
            func getEmaEstimatedTotalTime() -> TimeInterval {
                return emaEstimatedTotalTime
            }
            
            func getIsTranscribing() -> Bool {
                return isTranscribing
            }
        }
        
        let progressState = ProgressState()
        var progressBarTask: Task<Void, Never>?
        
        if cliArguments.verbose {
            print("\nStarting transcription with progress tracking...")

            let smoothingFactor = 0.1 // For exponential moving average

            // Start the progress bar task
            let weakWhisperKit = WeakSendableWrapper(whisperKit)
            progressBarTask = Task {
                guard let whisperKit = weakWhisperKit.value else { return }
                while await progressState.getIsTranscribing() {
                    let progress = whisperKit.progress.fractionCompleted
                    let currentTime = Date()
                    let elapsedTime = currentTime.timeIntervalSince(startTime)

                    // Update estimated total time and remaining time
                    var estimatedTimeRemaining: TimeInterval? = nil
                    if progress > 0.05 { // Start estimating after 5% progress
                        let currentEstimatedTotalTime = elapsedTime / progress
                        // Apply exponential moving average for smoothing
                        await progressState.updateEmaEstimatedTotalTime(currentEstimatedTotalTime, smoothingFactor: smoothingFactor)
                        let emaEstimatedTotalTime = await progressState.getEmaEstimatedTotalTime()
                        estimatedTimeRemaining = max(emaEstimatedTotalTime - elapsedTime, 0)
                    }

                    printProgressBar(progress: progress, elapsedTime: elapsedTime, estimatedTimeRemaining: estimatedTimeRemaining)

                    try? await Task.sleep(nanoseconds: 100_000_000) // Sleep for 0.1 seconds
                }
            }
        }

        // Start the transcription
        let transcribeResult: [Result<[TranscriptionResult], Swift.Error>]
        if cliArguments.tensorCpuOnly {
            if #available(macOS 15, iOS 18, *) {
                transcribeResult = await withMLTensorComputePolicy(.cpuOnly) {
                    await whisperKit.transcribeWithResults(audioPaths: resolvedAudioPaths,
                        audioInputOptions: audioInputOptions, decodeOptions: options)
                }
            } else {
                throw ValidationError("CPU-only tensor diagnosis requires macOS 15 or later")
            }
        } else {
            transcribeResult = await whisperKit.transcribeWithResults(audioPaths: resolvedAudioPaths,
                audioInputOptions: audioInputOptions, decodeOptions: options)
        }

        if cliArguments.verbose {
            // Indicate that transcription is done
            await progressState.stopTranscribing()
            // Wait for the progress bar task to finish
            await progressBarTask?.value
            
            let finalElapsedTime = Date().timeIntervalSince(startTime)
            printProgressBar(progress: 1.0, elapsedTime: finalElapsedTime, estimatedTimeRemaining: 0)
            
            // Move to new line after finishing
            print()
        }

        // TODO: we need to track the results between audio files, and shouldnt merge them
        // ONLY merge results for different chunks of the same audio file or array

        // Continue with processing the transcription results
        let allSuccessfulResults = transcribeResult.compactMap { try? $0.get() }.flatMap { $0 }

        // Log timings for full transcription run
        if cliArguments.verbose {
            let mergedResult = TranscriptionUtilities.mergeTranscriptionResults(allSuccessfulResults)
            mergedResult.logTimings()
            // Output tokensPerSecond, realTimeFactor, and speedFactor
            let timings = mergedResult.timings
            print("Transcription Performance:")
            print(String(format: "  - Tokens per second: %.2f", timings.tokensPerSecond))
            print(String(format: "  - Real-time factor: %.2f", timings.realTimeFactor))
            print(String(format: "  - Speed factor: %.2f", timings.speedFactor))
        }

        for (audioPath, result) in zip(resolvedAudioPaths, transcribeResult) {
            do {
                let partialResult = try result.get()
                let mergedPartialResult = TranscriptionUtilities.mergeTranscriptionResults(partialResult)
                processTranscriptionResult(audioPath: audioPath, transcribeResult: mergedPartialResult)
            } catch {
                print("Error when transcribing \(audioPath): \(error)")
            }
        }

        if diarization {
            for (audioPath, result) in zip(resolvedAudioPaths, transcribeResult) {
                do {
                    let partialResult = try result.get()
                    try await runDiarization(audioPath: audioPath, transcriptionResults: partialResult)
                } catch {
                    print("Error during diarization for \(audioPath): \(error)")
                }
            }
        }
    }

    private func printDiagnosticBufferLayout(_ tensor: MLMultiArray, name: String) {
        guard tensor.dataType == .float16, tensor.shape.count == 4 else { return }
        let originalStrides = tensor.strides.map { $0.intValue }
        let channelCount = tensor.shape[1].intValue
        let channels = Array(Set(Array(0..<min(8, channelCount)) + [channelCount - 1])).sorted()
        let logical = channels.map { tensor[[0, NSNumber(value: $0), 0, 0]].doubleValue }
        tensor.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: Float16.self)
            let capturedStrideValues = channels.map { channel -> Double? in
                let offset = channel * originalStrides[1]
                return offset < pointer.count ? Double(pointer[offset]) : nil
            }
            print("Diagnostic \(name) read buffer: bytes=\(bytes.count), channels=\(channels), original-strides=\(originalStrides), inside-strides=\(tensor.strides), logical=\(logical), original-stride-values=\(capturedStrideValues)")
        }
        tensor.withUnsafeMutableBytes { bytes, actualStrides in
            let pointer = bytes.bindMemory(to: Float16.self)
            let currentStrideValues = channels.map { channel -> Double? in
                let offset = channel * actualStrides[1]
                return offset < pointer.count ? Double(pointer[offset]) : nil
            }
            print("Diagnostic \(name) mutable buffer: bytes=\(bytes.count), buffer-strides=\(actualStrides), buffer-stride-values=\(currentStrideValues)")
        }
    }

    private func printDiagnosticTensor(_ tensor: MLMultiArray, name: String) {
        let indices = stride(from: 0, to: tensor.count, by: max(1, tensor.count / 4096))
        let values = indices.map { tensor[$0].doubleValue }
        let finite = values.filter { $0.isFinite }
        print("Diagnostic \(name): shape=\(tensor.shape), dtype=\(tensor.dataType.rawValue), strides=\(tensor.strides), sampled=\(values.count), finite=\(finite.count), min=\(finite.min() ?? .nan), max=\(finite.max() ?? .nan), rms=\(sqrt(finite.reduce(0) { $0 + $1 * $1 } / Double(max(1, finite.count))))")
    }

    private func transcribeStream() async throws {
        if cliArguments.verbose {
            print("Task: stream transcription, using microphone audio")
            print("Initializing models...")
        }

        let config = TranscribeCLIUtils.createWhisperKitConfig(from: cliArguments)
        let whisperKit = try await WhisperKit(config)
        guard let tokenizer = whisperKit.tokenizer else {
            throw WhisperError.tokenizerUnavailable()
        }

        if cliArguments.verbose {
            print("Models initialized")
        }

        let decodingOptions = TranscribeCLIUtils.createDecodingOptions(from: cliArguments, task: .transcribe)

        let audioStreamTranscriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions
        ) { oldState, newState in
            guard oldState.currentText != newState.currentText ||
                oldState.unconfirmedSegments != newState.unconfirmedSegments ||
                oldState.confirmedSegments != newState.confirmedSegments
            else {
                return
            }
            // TODO: Print only net new text without any repeats
            print("---")
            for segment in newState.confirmedSegments {
                print("Confirmed segment: \(segment.text)")
            }
            for segment in newState.unconfirmedSegments {
                print("Unconfirmed segment: \(segment.text)")
            }
            print("Current text: \(newState.currentText)")
        }
        print("Transcribing audio stream, press Ctrl+C to stop.")
        try await audioStreamTranscriber.startStreamTranscription()
    }

    private func transcribeStreamSimulated() async throws {
        guard let audioPath = cliArguments.audioPath.first else {
            throw CocoaError.error(.fileNoSuchFile)
        }
        let resolvedAudioPath = FileManager.resolveAbsolutePath(audioPath)
        guard FileManager.default.fileExists(atPath: resolvedAudioPath) else {
            throw CocoaError.error(.fileNoSuchFile)
        }

        if cliArguments.verbose {
            print("Task: simulated stream transcription, using audio file at \(audioPath)")
            print("Initializing models...")
        }

        let config = TranscribeCLIUtils.createWhisperKitConfig(from: cliArguments)
        let whisperKit = try await WhisperKit(config)

        if cliArguments.verbose {
            print("Models initialized")
        }

        let audioBuffer = try AudioProcessor.loadAudio(fromPath: resolvedAudioPath)
        let audioArray = AudioProcessor.convertBufferToArray(buffer: audioBuffer)

        var results: [TranscriptionResult?] = []
        var prevResult: TranscriptionResult?
        var lastAgreedSeconds: Float = 0.0
        let agreementCountNeeded = 2
        var hypothesisWords: [WordTiming] = []
        var prevWords: [WordTiming] = []
        var lastAgreedWords: [WordTiming] = []
        var confirmedWords: [WordTiming] = []

        let options = TranscribeCLIUtils.createDecodingOptions(from: cliArguments, task: .transcribe)

        for seekSample in stride(from: 16000, to: audioArray.count, by: 16000) {
            let endSample = min(seekSample + 16000, audioArray.count)
            if cliArguments.verbose {
                print("[argmax-cli] \(lastAgreedSeconds)-\(Double(endSample) / 16000.0) seconds")
            }

            let simulatedStreamingAudio = Array(audioArray[..<endSample])
            var streamOptions = options
            streamOptions.clipTimestamps = [lastAgreedSeconds]
            let lastAgreedTokens = lastAgreedWords.flatMap { $0.tokens }
            streamOptions.prefixTokens = lastAgreedTokens
            do {
                let result: TranscriptionResult? = try await whisperKit.transcribe(audioArray: simulatedStreamingAudio, decodeOptions: streamOptions).first
                var skipAppend = false
                if let result = result, let _ = result.segments.first?.words {
                    hypothesisWords = result.allWords.filter { $0.start >= lastAgreedSeconds }

                    if let prevResult = prevResult {
                        prevWords = prevResult.allWords.filter { $0.start >= lastAgreedSeconds }
                        let commonPrefix = TranscriptionUtilities.findLongestCommonPrefix(prevWords, hypothesisWords)
                        if cliArguments.verbose {
                            print("[argmax-cli] Prev \"\((prevWords.map { $0.word }).joined())\"")
                            print("[argmax-cli] Next \"\((hypothesisWords.map { $0.word }).joined())\"")
                            print("[argmax-cli] Found common prefix \"\((commonPrefix.map { $0.word }).joined())\"")
                        }

                        if commonPrefix.count >= agreementCountNeeded {
                            lastAgreedWords = commonPrefix.suffix(agreementCountNeeded)
                            lastAgreedSeconds = lastAgreedWords.first!.start
                            if cliArguments.verbose {
                                print("[argmax-cli] Found new last agreed word \(lastAgreedWords.first!.word) at \(lastAgreedSeconds) seconds")
                            }

                            confirmedWords.append(contentsOf: commonPrefix.prefix(commonPrefix.count - agreementCountNeeded))
                            let currentWords = confirmedWords.map { $0.word }.joined()
                            if cliArguments.verbose {
                                print("[argmax-cli] Current: \(lastAgreedSeconds) -> \(Double(endSample) / 16000.0) \(currentWords)")
                            }
                        } else {
                            if cliArguments.verbose {
                                print("[argmax-cli] Using same last agreed time \(lastAgreedSeconds)")
                            }
                            skipAppend = true
                        }
                    }
                    prevResult = result
                } else {
                    if cliArguments.verbose {
                        print("[argmax-cli] No word timings found, this may be due to alignment weights missing from the model being used")
                    }
                }
                if !skipAppend {
                    results.append(result)
                }
            } catch {
                if cliArguments.verbose {
                    print("Error: \(error.localizedDescription)")
                }
            }
        }

        let final = lastAgreedWords + TranscriptionUtilities.findLongestDifferentSuffix(prevWords, hypothesisWords)
        confirmedWords.append(contentsOf: final)

        let mergedResult = TranscriptionUtilities.mergeTranscriptionResults(results, confirmedWords: confirmedWords)

        processTranscriptionResult(audioPath: audioPath, transcribeResult: mergedResult)
    }





    private func runDiarization(audioPath: String, transcriptionResults: [TranscriptionResult]) async throws {
        let config = PyannoteConfig(
            modelRepo: diarizationModelRepo ?? "argmaxinc/speakerkit-coreml",
            modelFolder: diarizationModelPath,
            download: diarizationModelPath == nil,
            load: true,
            verbose: cliArguments.verbose
        )

        let loadStart = Date()
        let speakerKit = try await SpeakerKit(config)
        let loadTime = Date().timeIntervalSince(loadStart)

        if cliArguments.verbose {
            print("\nDiarization model initialization complete:")
            print(String(format: "  - Total load time: %.2f seconds", loadTime))
        }

        let audioFrames = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)

        let options = PyannoteDiarizationOptions(numberOfSpeakers: diarizationNumSpeakers)
        let diarizationResult = try await speakerKit.diarize(audioArray: audioFrames, options: options)

        let rttmLines = SpeakerKit.generateRTTM(
            from: diarizationResult,
            transcription: transcriptionResults,
            fileName: URL(filePath: audioPath).deletingPathExtension().lastPathComponent
        )

        print("\n---- Speaker Diarization Results ----")
        for line in rttmLines {
            print(line)
        }
    }

    private func processTranscriptionResult(
        audioPath: String,
        transcribeResult: TranscriptionResult?
    ) {
        if cliArguments.verbose {
            print("\nProcessing transcription result for: \(audioPath)")
        }

        let audioFile = URL(fileURLWithPath: audioPath).lastPathComponent
        let audioFileName = URL(fileURLWithPath: audioPath).deletingPathExtension().lastPathComponent
        let transcription = transcribeResult?.text ?? "Transcription failed"

        if cliArguments.report, let result = transcribeResult {
            if cliArguments.verbose {
                print("\nGenerating reports...")
            }

            // Write SRT (SubRip Subtitle Format) for the transcription
            let srtReportWriter = WriteSRT(outputDir: cliArguments.reportPath)
            if cliArguments.verbose {
                print("Writing SRT report to: \(cliArguments.reportPath)")
            }

            let savedSrtReport = srtReportWriter.write(result: result, to: audioFileName)
            if cliArguments.verbose {
                switch savedSrtReport {
                    case let .success(reportPath):
                        print("\n\nSaved SRT Report: \n\n\(reportPath)\n")
                    case let .failure(error):
                        print("\n\nCouldn't save report: \(error)\n")
                }
            }

            // Write JSON for all metadata
            let jsonReportWriter = WriteJSON(outputDir: cliArguments.reportPath)
            let savedJsonReport = jsonReportWriter.write(result: result, to: audioFileName)
            if cliArguments.verbose {
                switch savedJsonReport {
                    case let .success(reportPath):
                        print("\n\nSaved JSON Report: \n\n\(reportPath)\n")
                    case let .failure(error):
                        print("\n\nCouldn't save report: \(error)\n")
                }
            }
        }

        if cliArguments.verbose {
            print("\n\nTranscription of \(audioFile): \n\n\(transcription)\n")
        } else {
            print(transcription)
        }
    }

    private func printProgressBar(progress: Double, elapsedTime: TimeInterval, estimatedTimeRemaining: TimeInterval?) {
        let progressPercentage = Int(progress * 100)
        let barLength = 50
        let completedLength = Int(progress * Double(barLength))
        let bar = String(repeating: "=", count: completedLength) + String(repeating: " ", count: barLength - completedLength)

        let estimatedTimeRemainingString: String
        if let estimatedTimeRemaining = estimatedTimeRemaining {
            estimatedTimeRemainingString = String(format: "%.2f s", estimatedTimeRemaining)
        } else {
            estimatedTimeRemainingString = "Estimating..."
        }

        // Clear the current line and return to the beginning
        print("\r\u{001B}[K", terminator: "")

        var statusLine = "[\(bar)] \(progressPercentage)%"
        statusLine += String(format: " | Elapsed Time: %.2f s", elapsedTime)
        statusLine += " | Remaining: \(estimatedTimeRemainingString)"

        print(statusLine, terminator: "")
        fflush(stdout) // Ensure the output is flushed immediately
    }
}
