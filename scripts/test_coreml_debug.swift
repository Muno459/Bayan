#!/usr/bin/env swift
// Debug CoreML decoder

import Foundation
import CoreML

let baseDir = FileManager.default.currentDirectoryPath
let encoderPath = "\(baseDir)/Bayan/Resources/Data/TarteelEncoder.mlmodelc"
let decoderPath = "\(baseDir)/Bayan/Resources/Data/TarteelDecoder.mlmodelc"
let melPath = "\(baseDir)/Bayan/Resources/Data/test_mel.bin"

// Load mel
guard let melData = FileManager.default.contents(atPath: melPath) else {
    print("ERROR: Cannot load test_mel.bin"); exit(1)
}
let mel = melData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
print("Mel: \(mel.count) values, range: [\(mel.min()!), \(mel.max()!)]")

// Load models
let encoderURL = URL(fileURLWithPath: encoderPath)
let decoderURL = URL(fileURLWithPath: decoderPath)
let encoder = try! MLModel(contentsOf: encoderURL)
let decoder = try! MLModel(contentsOf: decoderURL)

// Run encoder
let melInput = try! MLMultiArray(shape: [1, 80, 3000], dataType: .float32)
let melPtr = melInput.dataPointer.bindMemory(to: Float.self, capacity: 80 * 3000)
mel.withUnsafeBufferPointer { melPtr.update(from: $0.baseAddress!, count: mel.count) }

let encResult = try! encoder.prediction(from: MLDictionaryFeatureProvider(dictionary: ["mel": melInput]))
let encoderOutput = encResult.featureValue(for: "encoder_output")!.multiArrayValue!

print("Encoder: shape=\(encoderOutput.shape), strides=\(encoderOutput.strides)")

// First decoder call with just prompt
let prompt = [50258, 50272, 50359, 50363]  // SOT, ar, transcribe, notimestamps
let eot = 50257
let maxSeqLen = 24

var padded = prompt
while padded.count < maxSeqLen { padded.append(eot) }

let inputIds = try! MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .int32)
for (i, t) in padded.enumerated() { inputIds[i] = NSNumber(value: t) }

print("\nInput IDs: \(padded)")

let decResult = try! decoder.prediction(from: MLDictionaryFeatureProvider(dictionary: [
    "input_ids": inputIds,
    "encoder_output": encoderOutput
]))
let logits = decResult.featureValue(for: "logits")!.multiArrayValue!

print("Logits: shape=\(logits.shape), strides=\(logits.strides)")

// Check logits at position 3 (last prompt token)
let pos = 3
let stride0 = logits.strides[0].intValue
let stride1 = logits.strides[1].intValue
let stride2 = logits.strides[2].intValue
let vocabSize = logits.shape[2].intValue

print("\nStrides: [\(stride0), \(stride1), \(stride2)]")
print("Vocab size: \(vocabSize)")

// Get top 10 tokens at position 3
var tokensWithScores: [(Int, Float)] = []
for i in 0..<min(vocabSize, 50364) {
    let idx = pos * stride1 + i * stride2
    let val = logits[idx].floatValue
    tokensWithScores.append((i, val))
}
tokensWithScores.sort { $0.1 > $1.1 }

print("\nTop 10 tokens at position \(pos):")
for (token, score) in tokensWithScores.prefix(10) {
    print("  Token \(token): \(score)")
}

// Also check position 0, 1, 2 for comparison
for checkPos in 0..<4 {
    var best = (0, Float(-1e9))
    for i in 0..<min(vocabSize, 50364) {
        let idx = checkPos * stride1 + i * stride2
        let val = logits[idx].floatValue
        if val > best.1 { best = (i, val) }
    }
    print("Position \(checkPos) best token: \(best.0) (score: \(best.1))")
}

// Expected: token 1211 at position 3
print("\nExpected token 1211, got token \(tokensWithScores[0].0)")
