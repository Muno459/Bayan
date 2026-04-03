import Accelerate
import CoreML
import Foundation

/// Compute log-mel spectrogram matching Whisper's preprocessing using Accelerate/vDSP.
/// Only processes frames containing actual audio — skips silence.
/// For a 0.5s word, computes ~50 frames instead of 3000 (60x speedup).
enum MelSpectrogram {
    static let sampleRate = 16000
    static let nFFT = 400
    static let hopLength = 160
    static let nMels = 80
    static let nFrames = 3000
    static let fftSize = 512 // Next power of 2 above 400

    /// Compute mel spectrogram and return as MLMultiArray (1, 80, 3000) ready for encoder.
    /// Only processes frames where audio exists — rest is filled with silence floor value.
    static func compute(audio: [Float]) -> MLMultiArray? {
        let nFreqBins = nFFT / 2 + 1 // 201

        // Load mel filterbank (80 x 201)
        guard let filters = loadMelFilters() else { return nil }

        // How many frames of actual audio?
        let audioFrames = max(1, (audio.count - nFFT) / hopLength + 1)
        let framesToCompute = min(audioFrames, nFrames)

        // FFT setup
        let log2n = vDSP_Length(9) // 2^9 = 512
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))

        // Output: (nMels, nFrames) — initialize with silence floor
        let silenceFloor: Float = -1.0 // Will be overwritten by normalization
        var melOutput = [Float](repeating: silenceFloor, count: nMels * nFrames)

        // Buffers reused per frame
        var paddedFrame = [Float](repeating: 0, count: fftSize)
        var fftReal = [Float](repeating: 0, count: fftSize / 2)
        var fftImag = [Float](repeating: 0, count: fftSize / 2)
        var powerSpectrum = [Float](repeating: 0, count: nFreqBins)

        // Pad audio to at least nFFT samples
        var paddedAudio = audio
        if paddedAudio.count < nFFT {
            paddedAudio.append(contentsOf: [Float](repeating: 0, count: nFFT - paddedAudio.count))
        }

        for frame in 0..<framesToCompute {
            let start = frame * hopLength
            if start + nFFT > paddedAudio.count { break }

            // Apply Hann window + zero-pad to 512
            for i in 0..<fftSize { paddedFrame[i] = 0 }
            vDSP_vmul(Array(paddedAudio[start..<start + nFFT]), 1, window, 1, &paddedFrame, 1, vDSP_Length(nFFT))

            // Pack interleaved pairs for vDSP_fft_zrip
            for i in 0..<fftSize / 2 {
                fftReal[i] = paddedFrame[2 * i]
                fftImag[i] = paddedFrame[2 * i + 1]
            }

            fftReal.withUnsafeMutableBufferPointer { rBuf in
                fftImag.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                    // Power spectrum
                    powerSpectrum[0] = split.realp[0] * split.realp[0] // DC
                    for k in 1..<min(nFreqBins - 1, fftSize / 2) {
                        powerSpectrum[k] = split.realp[k] * split.realp[k] + split.imagp[k] * split.imagp[k]
                    }
                    powerSpectrum[nFreqBins - 1] = split.imagp[0] * split.imagp[0] // Nyquist
                }
            }

            // Apply mel filterbank: mel = filters @ power
            for mel in 0..<nMels {
                var sum: Float = 0
                vDSP_dotpr(
                    Array(filters[mel * nFreqBins..<(mel + 1) * nFreqBins]), 1,
                    powerSpectrum, 1,
                    &sum,
                    vDSP_Length(nFreqBins)
                )
                // Log10 with floor
                melOutput[mel * nFrames + frame] = log10(max(sum, 1e-10))
            }
        }

        // Whisper normalization: clamp to (max - 8.0), then (x + 4.0) / 4.0
        var maxVal: Float = -Float.infinity
        for v in melOutput { if v > maxVal { maxVal = v } }
        let floor = maxVal - 8.0
        for i in 0..<melOutput.count {
            melOutput[i] = (max(melOutput[i], floor) + 4.0) / 4.0
        }

        // Pack into MLMultiArray (1, 80, 3000) as float16 for encoder
        guard let result = try? MLMultiArray(shape: [1, 80, NSNumber(value: nFrames)], dataType: .float16) else {
            return nil
        }
        let dstPtr = result.dataPointer.bindMemory(to: Float16.self, capacity: nMels * nFrames)
        for i in 0..<nMels * nFrames {
            dstPtr[i] = Float16(melOutput[i])
        }

        return result
    }

    // MARK: - Mel Filters

    private static func loadMelFilters() -> [Float]? {
        guard let url = Bundle.main.url(forResource: "mel_filters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filterData = json["data"] as? [Double]
        else {
            return nil
        }
        return filterData.map { Float($0) }
    }
}
