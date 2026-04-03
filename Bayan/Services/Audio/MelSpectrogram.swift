import Accelerate
import Foundation

/// Compute log-mel spectrogram matching Whisper's exact preprocessing.
/// Reference: openai/whisper/audio.py log_mel_spectrogram()
enum MelSpectrogram {
    static let sampleRate = 16000
    static let nFFT = 400
    static let hopLength = 160
    static let nMels = 80
    static let nFrames = 3000

    static func compute(audio: [Float]) -> [Float] {
        // 1. Pad/trim to 30 seconds
        let nSamples = sampleRate * 30
        var samples = [Float](repeating: 0, count: nSamples)
        let count = min(audio.count, nSamples)
        for i in 0..<count { samples[i] = audio[i] }

        // 2. STFT with Hann window — use 512-point FFT (next power of 2 above 400)
        let fftN = 512
        let log2n = vDSP_Length(9) // 2^9 = 512
        let nFreqBins = nFFT / 2 + 1 // 201 bins
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return [Float](repeating: 0, count: nMels * nFrames)
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        // Hann window
        var window = [Float](repeating: 0, count: nFFT)
        vDSP_hann_window(&window, vDSP_Length(nFFT), Int32(vDSP_HANN_NORM))

        // Load mel filterbank
        let filters = loadMelFilters()

        var melSpec = [Float](repeating: 0, count: nMels * nFrames)
        var fftReal = [Float](repeating: 0, count: fftN / 2)
        var fftImag = [Float](repeating: 0, count: fftN / 2)

        for frame in 0..<nFrames {
            let start = frame * hopLength
            if start + nFFT > nSamples { break }

            // Apply Hann window
            var windowed = [Float](repeating: 0, count: fftN) // zero-padded to 512
            vDSP_vmul(Array(samples[start..<start + nFFT]), 1, window, 1, &windowed, 1, vDSP_Length(nFFT))

            // Pack for vDSP_fft_zrip: interleaved real pairs
            for i in 0..<fftN / 2 {
                fftReal[i] = windowed[2 * i]
                fftImag[i] = windowed[2 * i + 1]
            }

            fftReal.withUnsafeMutableBufferPointer { rBuf in
                fftImag.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                    // Compute power spectrum for the first nFreqBins
                    let magBase = frame * nFreqBins

                    // DC: real part squared (packed in realp[0])
                    melSpec[magBase] = split.realp[0] * split.realp[0]

                    // Bins 1..nFreqBins-2
                    for k in 1..<min(nFreqBins - 1, fftN / 2) {
                        let r = split.realp[k]
                        let im = split.imagp[k]
                        // Store power spectrum temporarily in melSpec (will be overwritten)
                        melSpec[magBase + k] = r * r + im * im
                    }

                    // Nyquist: imagp[0] squared
                    if nFreqBins <= fftN / 2 + 1 {
                        melSpec[magBase + nFreqBins - 1] = split.imagp[0] * split.imagp[0]
                    }
                }
            }
        }

        // Now melSpec contains [nFrames * nFreqBins] power values (frame-major)
        // 3. Apply mel filterbank: for each frame, multiply power by filters
        var melResult = [Float](repeating: 0, count: nMels * nFrames)

        for frame in 0..<nFrames {
            for mel in 0..<nMels {
                var sum: Float = 0
                let fBase = mel * nFreqBins
                let pBase = frame * nFreqBins
                for k in 0..<nFreqBins {
                    if fBase + k < filters.count && pBase + k < melSpec.count {
                        sum += filters[fBase + k] * melSpec[pBase + k]
                    }
                }
                // Output in mel-major order: melResult[mel * nFrames + frame]
                melResult[mel * nFrames + frame] = sum
            }
        }

        // 4. Log10 scale
        for i in 0..<melResult.count {
            melResult[i] = log10(max(melResult[i], 1e-10))
        }

        // 5. Whisper normalization: clamp to (max - 8.0), then (x + 4.0) / 4.0
        var maxVal: Float = -Float.infinity
        for v in melResult { if v > maxVal { maxVal = v } }
        let floor = maxVal - 8.0
        for i in 0..<melResult.count {
            melResult[i] = (max(melResult[i], floor) + 4.0) / 4.0
        }

        return melResult
    }

    private static func loadMelFilters() -> [Float] {
        guard let url = Bundle.main.url(forResource: "mel_filters", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let filterData = json["data"] as? [Double]
        else {
            return [Float](repeating: 0, count: nMels * (nFFT / 2 + 1))
        }
        return filterData.map { Float($0) }
    }
}
