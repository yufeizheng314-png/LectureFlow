//  For licensing see accompanying LICENSE.md file.

import CoreML
import Foundation
@testable import WhisperKit
import XCTest

final class TokenSamplerFallbackTests: XCTestCase {
    // These exercise the public sampler with fixed logits, without models or a
    // tokenizer. On macOS 15 / iOS 18+, update() uses the MLTensor path implicated
    // in https://github.com/argmaxinc/argmax-oss-swift/issues/539.
    func testSaturatedFallbackDoesNotSampleNegligibleEndToken() async throws {
        let endToken = 50257
        let speechToken = 50360
        let logits = try makeLogits([
            speechToken: 19, 50264: 7, endToken: 5, 50259: 4, 50261: 3,
        ])
        let sampler = GreedyTokenSampler(temperature: 0.2, eotToken: endToken,
                                        decodingOptions: DecodingOptions(topK: 5))
        let prefix = [50258, 50264]
        for draw in 0..<32 {
            let result = await sampler.update(tokens: prefix, logits: logits, logProbs: [0, 0])
            XCTAssertEqual(result.tokens, prefix + [speechToken], "Saturated fallback draw \(draw)")
            XCTAssertFalse(result.completed, "A negligible EOT must not discard audible speech")
            XCTAssertEqual(try XCTUnwrap(result.logProbs.last), 0, accuracy: 0.00001)
        }
    }

    func testSaturatedFallbackStillCompletesWhenEndTokenDominates() async throws {
        let endToken = 50257
        let logits = try makeLogits([
            endToken: 19, 50360: 7, 50264: 5, 50259: 4, 50261: 3,
        ])
        let sampler = GreedyTokenSampler(temperature: 0.2, eotToken: endToken,
                                        decodingOptions: DecodingOptions(topK: 5))
        let prefix = [50258, 50264]
        for draw in 0..<32 {
            let result = await sampler.update(tokens: prefix, logits: logits, logProbs: [0, 0])
            XCTAssertEqual(result.tokens, prefix + [endToken], "Dominant EOT draw \(draw)")
            XCTAssertTrue(result.completed)
            XCTAssertEqual(try XCTUnwrap(result.logProbs.last), 0, accuracy: 0.00001)
        }
    }

    func testZeroTemperatureKeepsArgmaxAndItsLogProbability() async throws {
        let values: [Float] = [-2, 3, 0, 1, -3]
        let logits = try makeLogits(Dictionary(uniqueKeysWithValues: values.enumerated().map { ($0.offset, $0.element) }),
                                    vocabularySize: values.count)
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: 4,
                                        decodingOptions: DecodingOptions(topK: 5))
        let prefix = [12, 13]
        let priorLogProbs: [Float] = [-0.4, -0.8]
        let result = await sampler.update(tokens: prefix, logits: logits, logProbs: priorLogProbs)
        let expectedLogProbability = Double(values[1]) - log(values.reduce(0.0) { $0 + exp(Double($1)) })
        XCTAssertEqual(result.tokens, prefix + [1])
        XCTAssertFalse(result.completed)
        XCTAssertEqual(Array(result.logProbs.dropLast()), priorLogProbs)
        XCTAssertEqual(Double(try XCTUnwrap(result.logProbs.last)), expectedLogProbability, accuracy: 0.002)
    }

    func testNonzeroTemperatureSamplesTheTopKDistribution() async throws {
        let expected: [Double] = [0.6, 0.3, 0.1]
        let temperature: Float = 0.5
        let active = Dictionary(uniqueKeysWithValues: expected.enumerated().map {
            ($0.offset, temperature * Float(log($0.element)))
        })
        let logits = try makeLogits(active, vocabularySize: 8, floor: -20)
        let sampler = GreedyTokenSampler(temperature: FloatType(temperature), eotToken: 2,
                                        decodingOptions: DecodingOptions(topK: 3))
        let draws = 512
        var counts = [Int](repeating: 0, count: expected.count)
        for _ in 0..<draws {
            let result = await sampler.update(tokens: [12], logits: logits, logProbs: [-0.4])
            let selected = try XCTUnwrap(result.tokens.last)
            guard counts.indices.contains(selected) else {
                XCTFail("Sampled token \(selected) lies outside top-k")
                return
            }
            counts[selected] += 1
            XCTAssertEqual(result.tokens.count, 2)
            XCTAssertEqual(result.tokens.first, 12)
            XCTAssertEqual(result.completed, selected == 2)
            XCTAssertEqual(result.logProbs.first, -0.4)
            XCTAssertEqual(Double(try XCTUnwrap(result.logProbs.last)), log(expected[selected]), accuracy: 0.005)
        }
        // Each tolerance is over five binomial standard deviations; this catches
        // always-argmax/always-tail selection without depending on a random seed.
        for token in expected.indices {
            XCTAssertEqual(Double(counts[token]) / Double(draws), expected[token], accuracy: 0.12,
                           "Token \(token), observed counts \(counts)")
        }
    }

    private func makeLogits(_ active: [Int: Float], vocabularySize: Int = 51866,
                            floor: Float = -10) throws -> MLMultiArray {
        #if (os(macOS) || targetEnvironment(macCatalyst)) && arch(x86_64)
        let dataType: MLMultiArrayDataType = .float32
        #else
        let dataType: MLMultiArrayDataType = .float16
        #endif
        let logits = try MLMultiArray(shape: [1, 1, NSNumber(value: vocabularySize)],
                                     dataType: dataType, initialValue: FloatType(floor))
        for (token, value) in active {
            logits[token] = NSNumber(value: value)
        }
        return logits
    }
}
