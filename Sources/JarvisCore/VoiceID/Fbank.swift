import Accelerate
import Foundation

/// Kaldi-style log mel filterbank features, the input the speaker model was trained on:
/// 16 kHz audio, 25 ms frames every 10 ms, DC removal, pre-emphasis 0.97, Hamming window, 512-point
/// power spectrum, 80 triangular mel filters from 20 Hz to 8 kHz, log, then mean subtraction over time.
public enum Fbank {
    public static let sampleRate = 16_000.0
    public static let frameLength = 400
    public static let frameShift = 160
    public static let fftSize = 512
    public static let melBins = 80

    static let window: [Float] = (0..<frameLength).map { Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(frameLength - 1))) }

    /// melBins × (fftSize/2) triangular weights, row-major.
    static let filters: [Float] = {
        func mel(_ f: Double) -> Double { 1127.0 * log(1.0 + f / 700.0) }
        let lo = mel(20), hi = mel(sampleRate / 2)
        let delta = (hi - lo) / Double(melBins + 1)
        let half = fftSize / 2
        var w = [Float](repeating: 0, count: melBins * half)
        for b in 0..<melBins {
            let left = lo + Double(b) * delta, center = left + delta, right = center + delta
            for i in 0..<half {
                let m = mel(Double(i) * sampleRate / Double(fftSize))
                guard m > left, m < right else { continue }
                w[b * half + i] = Float(m <= center ? (m - left) / (center - left) : (right - m) / (right - center))
            }
        }
        return w
    }()

    /// How many frames `sampleCount` samples give.
    public static func frameCount(_ sampleCount: Int) -> Int {
        sampleCount < frameLength ? 0 : 1 + (sampleCount - frameLength) / frameShift
    }

    /// Features for `samples` (−1…1, 16 kHz mono): frames × 80, row-major, mean-normalized per bin.
    public static func compute(_ samples: [Float]) -> (frames: Int, features: [Float]) {
        let frames = frameCount(samples.count)
        guard frames > 0, let dft = vDSP.DFT(count: fftSize, direction: .forward, transformType: .complexComplex, ofType: Float.self) else { return (0, []) }
        let half = fftSize / 2
        var out = [Float](repeating: 0, count: frames * melBins)
        var frame = [Float](repeating: 0, count: fftSize)
        let zeros = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize), imag = [Float](repeating: 0, count: fftSize)
        var power = [Float](repeating: 0, count: half)
        var energies = [Float](repeating: 0, count: melBins)
        let floor = Float.ulpOfOne

        for f in 0..<frames {
            let start = f * frameShift
            var mean: Float = 0
            for i in 0..<frameLength { frame[i] = samples[start + i] * 32768; mean += frame[i] }
            mean /= Float(frameLength)
            for i in 0..<frameLength { frame[i] -= mean }                                  // remove DC
            for i in stride(from: frameLength - 1, to: 0, by: -1) { frame[i] -= 0.97 * frame[i - 1] }   // pre-emphasis
            frame[0] -= 0.97 * frame[0]
            vDSP.multiply(frame[0..<frameLength], window, result: &frame[0..<frameLength])
            for i in frameLength..<fftSize { frame[i] = 0 }
            dft.transform(inputReal: frame, inputImaginary: zeros, outputReal: &real, outputImaginary: &imag)
            for i in 0..<half { power[i] = real[i] * real[i] + imag[i] * imag[i] }
            filters.withUnsafeBufferPointer { w in
                power.withUnsafeBufferPointer { p in
                    vDSP_mmul(w.baseAddress!, 1, p.baseAddress!, 1, &energies, 1, vDSP_Length(melBins), 1, vDSP_Length(half))
                }
            }
            for b in 0..<melBins { out[f * melBins + b] = log(max(energies[b], floor)) }
        }
        // Cepstral mean normalization: subtract each bin's mean over the utterance.
        for b in 0..<melBins {
            var sum: Float = 0
            for f in 0..<frames { sum += out[f * melBins + b] }
            let m = sum / Float(frames)
            for f in 0..<frames { out[f * melBins + b] -= m }
        }
        return (frames, out)
    }
}
