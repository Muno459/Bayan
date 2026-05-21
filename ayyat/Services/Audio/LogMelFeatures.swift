import Accelerate
import CoreML
import Foundation

/// 80-channel log-mel spectrogram extractor matched **exactly** to NVIDIA
/// NeMo's `FilterbankFeatures` (HTK preset) — the preprocessing the
/// FastConformer-Quran model was trained against and the upstream demo
/// Space uses.
///
/// Critical contract (no deviations — the upstream engineer confirmed
/// each one of these):
///
///   1. Reflect-pad audio (NOT zero-pad) by nFFT/2 on each end *before*
///      STFT framing. No pre-emphasis filter — NeMo's default does not
///      apply one for this checkpoint.
///   2. STFT: nFFT=512, hop=160 (10 ms), window = Hann(400) *symmetric*,
///      zero-padded to 512 for the FFT (the trailing 112 samples are 0).
///   3. Mel filterbank: HTK natural-log scale (`1127 · ln(1 + hz/700)`),
///      raw triangle filters with floor'd integer bin edges, **no
///      Slaney amplitude norm**.
///   4. Log compression: `log(mel + 1e-5)` (ADD epsilon then log, do not
///      `max(mel, 1e-5)`).
///   5. Per-channel mean / std normalisation over **real frames only**
///      (the padded silence tail must NOT be included in the statistics
///      — including it pulls the mean toward zero and shifts every
///      feature value).
///   6. Pad mel rows to bucket T=800 with zeros (post-normalize zero =
///      channel mean, so the padded region is statistically neutral).
///   7. Pack as FLOAT16 — the ANE-ready model's input contract.
enum LogMelFeatures {
    static let sampleRate: Int = 16_000
    static let nFFT: Int = 512
    static let hopLength: Int = 160
    static let winLength: Int = 400        // 25 ms @ 16 kHz, Hann is this long
    static let nMels: Int = 80
    static let melFloor: Float = 1e-5
    static let normEpsilon: Float = 1e-5
    static let modelInputFrames: Int = 800
    static let encoderSubsamplingRatio: Int = 8

    /// Build the log-mel buffer + return the real (pre-padding) frame count.
    static func compute(samples: [Float]) throws -> (features: MLMultiArray, frameCount: Int) {
        guard !samples.isEmpty else {
            throw NSError(domain: "LogMelFeatures", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "empty audio buffer"])
        }

        // 1. Reflect-pad nFFT/2 on each end (matches `np.pad(mode='reflect')`).
        //    No pre-emphasis — NeMo's default for this checkpoint doesn't use it.
        let pad = nFFT / 2
        var padded = [Float](repeating: 0, count: samples.count + 2 * pad)
        for i in 0..<pad {
            let mirror = pad - i
            padded[i] = samples[min(mirror, samples.count - 1)]
        }
        for i in 0..<samples.count { padded[pad + i] = samples[i] }
        for i in 0..<pad {
            let idx = samples.count - 2 - i
            padded[pad + samples.count + i] = samples[max(idx, 0)]
        }

        // 2. Frame count = 1 + (paddedLen - nFFT) // hop
        guard padded.count >= nFFT else {
            throw NSError(domain: "LogMelFeatures", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "padded audio too short"])
        }
        let realFrameCount = 1 + (padded.count - nFFT) / hopLength

        // 3. Hann window of length 400 (25 ms), symmetric. The FFT is
        //    512-point so we zero-pad the trailing 112 samples per frame.
        let hann = makeNumpyHanning(length: winLength)

        // 4. FFT setup
        let log2n = vDSP_Length(log2(Float(nFFT)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2)) else {
            throw NSError(domain: "LogMelFeatures", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "could not create FFT setup"])
        }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let melBank = melFilterbank()
        let nBins = nFFT / 2 + 1

        var realBuf = [Float](repeating: 0, count: nFFT / 2)
        var imagBuf = [Float](repeating: 0, count: nFFT / 2)
        var windowed = [Float](repeating: 0, count: nFFT)
        var magSq = [Float](repeating: 0, count: nBins)

        // Channel-major output: (m * T + t)
        var realMel = [Float](repeating: 0, count: nMels * realFrameCount)

        for frame in 0..<realFrameCount {
            let start = frame * hopLength
            // Window the first 400 samples with Hann(400); zero the last 112.
            for i in 0..<winLength {
                windowed[i] = padded[start + i] * hann[i]
            }
            for i in winLength..<nFFT { windowed[i] = 0 }

            realBuf.withUnsafeMutableBufferPointer { rp in
                imagBuf.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    windowed.withUnsafeBufferPointer { wp in
                        wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: nFFT / 2) { cptr in
                            vDSP_ctoz(cptr, 2, &split, 1, vDSP_Length(nFFT / 2))
                            vDSP_fft_zrip(fftSetup, &split, 1, log2n, Int32(FFT_FORWARD))
                        }
                    }
                }
            }

            // One-sided |X|² — vDSP packs Nyquist into realBuf[0].imag.
            magSq[0] = realBuf[0] * realBuf[0]
            magSq[nFFT / 2] = imagBuf[0] * imagBuf[0]
            for k in 1..<(nFFT / 2) {
                let re = realBuf[k]
                let im = imagBuf[k]
                magSq[k] = re * re + im * im
            }
            // vDSP's FFT is 2× the mathematical transform → power is 4×.
            // numpy's np.fft.rfft is exact, so divide by 4 to match.
            var scale: Float = 0.25
            vDSP_vsmul(magSq, 1, &scale, &magSq, 1, vDSP_Length(magSq.count))

            // Mel projection: mel[m] = Σ_k bank[m, k] · magSq[k]
            for m in 0..<nMels {
                var dot: Float = 0
                let row = melBank[m]
                for k in 0..<nBins {
                    dot += row[k] * magSq[k]
                }
                // log(mel + 1e-5) — ADD epsilon, then log.
                realMel[m * realFrameCount + frame] = log(dot + melFloor)
            }
        }

        // 5. Per-channel mean/std normalize over REAL frames only.
        for m in 0..<nMels {
            var mean: Float = 0
            realMel.withUnsafeBufferPointer { ptr in
                vDSP_meanv(ptr.baseAddress! + m * realFrameCount, 1, &mean, vDSP_Length(realFrameCount))
            }
            var sumSq: Float = 0
            for t in 0..<realFrameCount {
                let d = realMel[m * realFrameCount + t] - mean
                sumSq += d * d
            }
            let std = sqrt(sumSq / Float(realFrameCount)) + normEpsilon
            let invStd = 1 / std
            for t in 0..<realFrameCount {
                realMel[m * realFrameCount + t] = (realMel[m * realFrameCount + t] - mean) * invStd
            }
        }

        // 6. Pad/truncate mel rows to the fixed-shape model bucket T=800.
        //    Zero-pad post-normalize = channel mean (already 0 after norm)
        //    so the padded tail is statistically neutral.
        let outputFrameCount = modelInputFrames
        var output = [Float](repeating: 0, count: nMels * outputFrameCount)
        let copyT = min(realFrameCount, outputFrameCount)
        for m in 0..<nMels {
            for t in 0..<copyT {
                output[m * outputFrameCount + t] = realMel[m * realFrameCount + t]
            }
        }

        // 7. Pack into MLMultiArray (1, 80, 800) FLOAT16 — ANE-ready model input.
        let array = try MLMultiArray(
            shape: [1, NSNumber(value: nMels), NSNumber(value: outputFrameCount)],
            dataType: .float16
        )
        var src = output
        let count = src.count
        try src.withUnsafeMutableBufferPointer { srcPtr in
            var srcBuf = vImage_Buffer(
                data: srcPtr.baseAddress,
                height: 1, width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<Float>.size
            )
            let dst16 = UnsafeMutableRawPointer(mutating: array.dataPointer)
            var dstBuf = vImage_Buffer(
                data: dst16,
                height: 1, width: vImagePixelCount(count),
                rowBytes: count * MemoryLayout<UInt16>.size
            )
            let result = vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, vImage_Flags(kvImageNoFlags))
            if result != kvImageNoError {
                throw NSError(domain: "LogMelFeatures", code: 5,
                              userInfo: [NSLocalizedDescriptionKey: "float32→16 conversion failed (\(result))"])
            }
        }

        let logicalFrameCount = min(realFrameCount, outputFrameCount)
        return (array, logicalFrameCount)
    }

    // MARK: - Mel filterbank (HTK natural-log, no Slaney norm)

    private static let cachedFilterbank: [[Float]] = {
        return buildMelFilterbank()
    }()

    static func melFilterbank() -> [[Float]] { cachedFilterbank }

    /// HTK natural-log mel scale + raw triangular filters with floor'd
    /// integer bin centres.
    ///
    ///   mel = 1127 · ln(1 + f/700)
    ///   bin = floor((n_fft + 1) · hz / sr)
    ///   triangle: rise from l to c (1.0 at c), fall from c to r
    ///   no per-filter amplitude norm
    private static func buildMelFilterbank() -> [[Float]] {
        let sr = Float(sampleRate)
        let melMax: Float = 1127.0 * log(1.0 + (sr / 2.0) / 700.0)
        let nEdges = nMels + 2
        var melPts = [Float](repeating: 0, count: nEdges)
        for i in 0..<nEdges {
            melPts[i] = melMax * Float(i) / Float(nEdges - 1)
        }
        var hzPts = [Float](repeating: 0, count: nEdges)
        for i in 0..<nEdges {
            hzPts[i] = 700.0 * (exp(melPts[i] / 1127.0) - 1.0)
        }
        var binPts = [Int](repeating: 0, count: nEdges)
        for i in 0..<nEdges {
            binPts[i] = Int(floor(Float(nFFT + 1) * hzPts[i] / sr))
        }

        let nBins = nFFT / 2 + 1
        var fb = [[Float]](repeating: [Float](repeating: 0, count: nBins), count: nMels)
        for m in 0..<nMels {
            let l = binPts[m]
            let c = binPts[m + 1]
            let r = binPts[m + 2]
            if c != l {
                let denom = Float(c - l)
                for k in l..<c where k < nBins && k >= 0 {
                    fb[m][k] = Float(k - l) / denom
                }
            }
            if r != c {
                let denom = Float(r - c)
                for k in c..<r where k < nBins && k >= 0 {
                    fb[m][k] = Float(r - k) / denom
                }
            }
        }
        return fb
    }

    /// `np.hanning(N)` — symmetric Hann of length N:
    ///   w[n] = 0.5 · (1 − cos(2π · n / (N−1))),  n = 0, …, N−1
    private static func makeNumpyHanning(length: Int) -> [Float] {
        var w = [Float](repeating: 0, count: length)
        let denom = Float(length - 1)
        for i in 0..<length {
            w[i] = 0.5 * (1 - cos(2 * .pi * Float(i) / denom))
        }
        return w
    }
}
