#!/usr/bin/env swift
// Test CoreML models on macOS

import Foundation
import CoreML

// Paths
let baseDir = FileManager.default.currentDirectoryPath
let encoderPath = "\(baseDir)/Bayan/Resources/Data/TarteelEncoder.mlmodelc"
let decoderPath = "\(baseDir)/Bayan/Resources/Data/TarteelDecoder.mlmodelc"
let melPath = "\(baseDir)/Bayan/Resources/Data/test_mel.bin"

print("Testing CoreML models on macOS")
print("==============================")

// Load mel from Python-generated file
guard let melData = FileManager.default.contents(atPath: melPath) else {
    print("ERROR: Cannot load test_mel.bin")
    exit(1)
}

let mel = melData.withUnsafeBytes { ptr in
    Array(ptr.bindMemory(to: Float.self))
}
print("Loaded mel: \(mel.count) values")
print("Mel range: [\(mel.min() ?? 0), \(mel.max() ?? 0)]")
print("Mel first 5: \(Array(mel.prefix(5)))")

// Load encoder
guard let encoderURL = URL(string: "file://\(encoderPath)"),
      let encoder = try? MLModel(contentsOf: encoderURL) else {
    print("ERROR: Cannot load encoder from \(encoderPath)")
    exit(1)
}
print("\nLoaded encoder")

// Create mel input
let melInput = try! MLMultiArray(shape: [1, 80, 3000], dataType: .float32)
let melPtr = melInput.dataPointer.bindMemory(to: Float.self, capacity: 80 * 3000)
mel.withUnsafeBufferPointer { src in
    melPtr.update(from: src.baseAddress!, count: min(mel.count, 80 * 3000))
}

// Run encoder
let encoderFeatures = try! MLDictionaryFeatureProvider(dictionary: ["mel": melInput])
let encoderResult = try! encoder.prediction(from: encoderFeatures)
guard let encoderOutput = encoderResult.featureValue(for: "encoder_output")?.multiArrayValue else {
    print("ERROR: Encoder failed")
    exit(1)
}

var encMin: Float = .infinity
var encMax: Float = -.infinity
for i in 0..<encoderOutput.count {
    let v = encoderOutput[i].floatValue
    encMin = min(encMin, v)
    encMax = max(encMax, v)
}
print("Encoder output: \(encoderOutput.count) values, range: [\(encMin), \(encMax)]")

// Load decoder
guard let decoderURL = URL(string: "file://\(decoderPath)"),
      let decoder = try? MLModel(contentsOf: decoderURL) else {
    print("ERROR: Cannot load decoder from \(decoderPath)")
    exit(1)
}
print("Loaded decoder")

// Decode
let sotToken = 50258
let eotToken = 50257
let langToken = 50272
let taskToken = 50359
let noTimestamps = 50363
let maxSeqLen = 24

var tokens = [sotToken, langToken, taskToken, noTimestamps]

for _ in 0..<20 {
    var padded = tokens
    while padded.count < maxSeqLen {
        padded.append(eotToken)
    }

    let inputIds = try! MLMultiArray(shape: [1, NSNumber(value: maxSeqLen)], dataType: .int32)
    for (i, t) in padded.enumerated() {
        inputIds[i] = NSNumber(value: t)
    }

    let decoderFeatures = try! MLDictionaryFeatureProvider(dictionary: [
        "input_ids": inputIds,
        "encoder_output": encoderOutput
    ])
    let decoderResult = try! decoder.prediction(from: decoderFeatures)
    guard let logits = decoderResult.featureValue(for: "logits")?.multiArrayValue else {
        print("ERROR: Decoder failed")
        exit(1)
    }

    let vocabSize = logits.shape[2].intValue
    let lastPos = tokens.count - 1
    let stride1 = logits.strides[1].intValue
    let stride2 = logits.strides[2].intValue

    var maxIdx = 0
    var maxVal: Float = -.infinity
    for i in 0..<min(vocabSize, 50364) {
        let idx = lastPos * stride1 + i * stride2
        let val = logits[idx].floatValue
        if val > maxVal {
            maxVal = val
            maxIdx = i
        }
    }

    if maxIdx == eotToken { break }
    tokens.append(maxIdx)

    if tokens.count >= maxSeqLen { break }
}

print("\nGenerated tokens: \(Array(tokens.dropFirst(4)))")
print("Expected tokens: [1211, 6808, 995]")

if Array(tokens.dropFirst(4)) == [1211, 6808, 995] {
    print("\n✓ CoreML models work correctly!")
} else {
    print("\n✗ Output differs from expected!")
}
