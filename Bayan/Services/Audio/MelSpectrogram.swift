import Accelerate
import Foundation

/// Compute a log-mel spectrogram matching Whisper's preprocessing.
/// Uses vDSP for FFT and the actual Whisper mel filterbank.
enum MelSpectrogram {
    static let sampleRate = 16000
    static let nFFT = 400
    static let hopLength = 160
    static let nMels = 80
    static let nFrames = 3000 // 30 seconds

    /// Compute log-mel spectrogram from raw audio samples.
    /// Input: mono float32 audio at 16kHz
    /// Output: [nMels * nFrames] flat array (row-major)
    static func compute(audio: [Float]) -> [Float] {
        // Pad or trim to 30 seconds
        let nSamples = sampleRate * 30
        var padded = [Float](repeating: 0, count: nSamples)
        let copyCount = min(audio.count, nSamples)
        padded.replaceSubrange(0..<copyCount, with: audio[0..<copyCount])

        // Load mel filters
        let melFilters = loadMelFilters()

        // Hann window
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))

        // FFT setup
        let log2n = vDSP_Length(log2(Float(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: nMels * nFrames)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let nFreqBins = nFFT / 2 + 1
        var melOutput = [Float](repeating: 0, count: nMels * nFrames)

        // Process each frame
        var realPart = [Float](repeating: 0, count: nFFT)
        var imagPart = [Float](repeating: 0, count: nFFT)
        var magnitudes = [Float](repeating: 0, count: nFreqBins)

        for frame in 0..<nFrames {
            let start = frame * hopLength
            if start + nFFT > nSamples { break }

            // Apply window
            var windowed = [Float](repeating: 0, count: nFFT)
            vDSP_vmul(Array(padded[start..<(start + nFFT)]), 1, window, 1, &windowed, 1, vDSP_Length(nFFT))

            // FFT
            realPart = windowed
            imagPart = [Float](repeating: 0, count: nFFT)

            realPart.withUnsafeMutableBufferPointer { realBuf in
                imagPart.withUnsafeMutableBufferPointer { imagBuf in
                    var splitComplex = DSPSplitComplex(
                        realp: realBuf.baseAddress!,
                        imagp: imagBuf.baseAddress!
                    )

                    // Pack into split complex
                    windowed.withUnsafeBufferPointer { inputBuf in
                        inputBuf.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(nFFT / 2))
                        }
                    }

                    // Forward FFT
                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(kFFTDirection_Forward))

                    // Compute power spectrum |X|^2
                    vDSP_zvmags(&splitComplex, 1, &magnitudes, 1, vDSP_Length(nFreqBins))
                }
            }

            // Apply mel filterbank: mel_output = mel_filters @ magnitudes
            for mel in 0..<nMels {
                var dot: Float = 0
                let filterOffset = mel * nFreqBins
                if filterOffset + nFreqBins <= melFilters.count {
                    vDSP_dotpr(
                        Array(melFilters[filterOffset..<(filterOffset + nFreqBins)]), 1,
                        magnitudes, 1,
                        &dot,
                        vDSP_Length(nFreqBins)
                    )
                }
                // Log scale with floor
                melOutput[mel * nFrames + frame] = log10(max(dot, 1e-10))
            }
        }

        // Normalize: scale to roughly [-1, 1] range
        var maxVal: Float = 0
        vDSP_maxv(melOutput, 1, &maxVal, vDSP_Length(melOutput.count))
        if maxVal > 0 {
            let scale = 1.0 / maxVal
            vDSP_vsmul(melOutput, 1, [scale], &melOutput, 1, vDSP_Length(melOutput.count))
        }

        vDSP_destroy_fftsetup(fftSetup)

        return melOutput
    }

    // MARK: - Mel Filters

    private static func loadMelFilters() -> [Float] {
        guard let url = Bundle.main.url(forResource: "mel_filters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filterData = json["data"] as? [Double]
        else {
            // Fallback: return empty filters
            return [Float](repeating: 0, count: nMels * (nFFT / 2 + 1))
        }
        return filterData.map { Float($0) }
    }
}
