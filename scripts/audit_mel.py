#!/usr/bin/env python3
"""
Detailed audit of Swift mel spectrogram computation vs HuggingFace.

Compares each step to identify any discrepancies.
"""

import numpy as np
from scipy import signal
import subprocess
import tempfile
import wave
import os

# Constants matching Swift
SAMPLE_RATE = 16000
N_FFT = 400
HOP_LENGTH = 160
N_MELS = 80
N_FRAMES = 3000

def download_test_audio():
    url = "https://audio.qurancdn.com/wbw/002_002_003.mp3"
    mp3_path = tempfile.mktemp(suffix=".mp3")
    wav_path = tempfile.mktemp(suffix=".wav")
    subprocess.run(["curl", "-sL", "-o", mp3_path, url], capture_output=True)
    subprocess.run(["ffmpeg", "-y", "-i", mp3_path, "-ar", "16000", "-ac", "1", "-f", "wav", wav_path], capture_output=True)
    with wave.open(wav_path, "rb") as wav:
        frames = wav.readframes(wav.getnframes())
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0
    os.unlink(mp3_path)
    os.unlink(wav_path)
    return audio

def compute_mel_swift_exact(audio):
    """
    Exact replication of Swift computeMelSpectrogram function.
    """
    print("\n" + "="*60)
    print("SWIFT MEL COMPUTATION (STEP BY STEP)")
    print("="*60)

    # Load mel filters
    mel_filters = np.fromfile("Bayan/Resources/Data/mel_filters.bin", dtype=np.float32).reshape(N_MELS, N_FFT // 2 + 1)
    print(f"\n[1] Mel filters: shape={mel_filters.shape}, sum={mel_filters.sum():.4f}")

    # Step 1: Pad audio to 30 seconds
    target_samples = SAMPLE_RATE * 30
    padded = np.zeros(target_samples, dtype=np.float32)
    copy_count = min(len(audio), target_samples)
    padded[:copy_count] = audio[:copy_count]
    print(f"\n[2] Padded to 30s: {len(padded)} samples, non-zero: {np.count_nonzero(padded)}")

    # Step 2: Reflect padding for STFT
    pad = N_FFT // 2  # 200
    audio_padded = np.zeros(len(padded) + 2 * pad, dtype=np.float32)

    # Reflect left: audioPadded[pad - 1 - i] = padded[i + 1] for i in 0..<pad
    for i in range(pad):
        audio_padded[pad - 1 - i] = padded[i + 1]

    # Copy center
    audio_padded[pad:pad + len(padded)] = padded

    # Reflect right: audioPadded[pad + padded.count + i] = padded[padded.count - 2 - i]
    for i in range(pad):
        audio_padded[pad + len(padded) + i] = padded[len(padded) - 2 - i]

    print(f"\n[3] Reflect padded: {len(audio_padded)} samples")
    print(f"    Left edge (should be reflected): {audio_padded[:5]}")
    print(f"    Audio start: {audio_padded[pad:pad+5]}")

    # Step 3: Compute STFT parameters
    num_frames = (len(audio_padded) - N_FFT) // HOP_LENGTH + 1
    fft_size = N_FFT // 2 + 1  # 201
    print(f"\n[4] STFT params: num_frames={num_frames}, fft_size={fft_size}")

    # Step 4: Hann window (vDSP_hann_window with vDSP_HANN_NORM)
    # vDSP_HANN_NORM creates: w[i] = 0.5 * (1 - cos(2*pi*i/N))
    # This is the PERIODIC Hann window
    window = 0.5 * (1 - np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT))
    window = window.astype(np.float32)
    print(f"\n[5] Hann window: sum={window.sum():.4f}, first 5: {window[:5]}")

    # Compare with scipy
    scipy_periodic = signal.windows.hann(N_FFT, sym=False).astype(np.float32)
    scipy_symmetric = signal.windows.hann(N_FFT, sym=True).astype(np.float32)
    print(f"    scipy periodic match: {np.allclose(window, scipy_periodic)}")
    print(f"    scipy symmetric match: {np.allclose(window, scipy_symmetric)}")

    # Step 5: Compute magnitudes for each frame
    magnitudes = np.zeros((num_frames, fft_size), dtype=np.float32)

    for f in range(num_frames):
        start = f * HOP_LENGTH
        frame = audio_padded[start:start + N_FFT] * window

        # FFT (numpy rfft is standard, no scaling)
        fft_result = np.fft.rfft(frame)

        # Magnitude squared with vDSP scaling correction (divide by 4)
        mag_sq = np.abs(fft_result) ** 2
        magnitudes[f] = mag_sq * 0.25  # vDSP scaling correction

    print(f"\n[6] Magnitudes: shape={magnitudes.shape}")
    print(f"    First frame mag[0:5]: {magnitudes[0, :5]}")
    print(f"    Max magnitude: {magnitudes.max():.6f}")

    # Step 6: Apply mel filter bank
    # mel = melFilters @ magnitudes.T  -> (80, num_frames)
    mel_spec = mel_filters @ magnitudes.T
    print(f"\n[7] Mel spec: shape={mel_spec.shape}")
    print(f"    First mel band [0:5]: {mel_spec[0, :5]}")
    print(f"    Max mel: {mel_spec.max():.6f}, Min mel: {mel_spec.min():.9f}")

    # Step 7: Log mel (only first N_FRAMES)
    log_mel = np.zeros((N_MELS, N_FRAMES), dtype=np.float32)
    max_val = -np.inf

    for m in range(N_MELS):
        for f in range(N_FRAMES):
            val = mel_spec[m, f]
            log_val = np.log10(max(val, 1e-10))
            log_mel[m, f] = log_val
            max_val = max(max_val, log_val)

    print(f"\n[8] Log mel (before clip): shape={log_mel.shape}")
    print(f"    max_val: {max_val:.4f}")
    print(f"    Range: [{log_mel.min():.4f}, {log_mel.max():.4f}]")

    # Step 8: Clip and normalize
    log_mel = np.maximum(log_mel, max_val - 8.0)
    log_mel = (log_mel + 4.0) / 4.0

    print(f"\n[9] Final mel (after clip/norm):")
    print(f"    Range: [{log_mel.min():.4f}, {log_mel.max():.4f}]")
    print(f"    First frame [0:5]: {log_mel[:, 0][:5]}")

    return log_mel

def compute_mel_huggingface(audio):
    """
    Compute mel using HuggingFace WhisperProcessor.
    """
    print("\n" + "="*60)
    print("HUGGINGFACE MEL COMPUTATION")
    print("="*60)

    from transformers import WhisperProcessor
    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    mel = processor(audio, sampling_rate=16000, return_tensors="np")["input_features"][0]

    print(f"\nHF mel shape: {mel.shape}")
    print(f"HF mel range: [{mel.min():.4f}, {mel.max():.4f}]")
    print(f"HF first frame [0:5]: {mel[:, 0][:5]}")

    return mel

def main():
    print("Downloading test audio...")
    audio = download_test_audio()
    print(f"Audio: {len(audio)} samples ({len(audio)/16000:.2f}s)")

    # Compute both
    mel_swift = compute_mel_swift_exact(audio)
    mel_hf = compute_mel_huggingface(audio)

    # Compare
    print("\n" + "="*60)
    print("COMPARISON")
    print("="*60)

    diff = np.abs(mel_swift - mel_hf)
    print(f"\nDifference:")
    print(f"  Mean: {diff.mean():.6f}")
    print(f"  Max: {diff.max():.6f}")
    print(f"  Std: {diff.std():.6f}")

    corr = np.corrcoef(mel_swift.flatten(), mel_hf.flatten())[0, 1]
    print(f"  Correlation: {corr:.6f}")

    # Check specific positions
    print(f"\nSpot checks:")
    for pos in [(0, 0), (0, 100), (40, 500), (79, 2999)]:
        m, f = pos
        print(f"  [{m},{f}]: Swift={mel_swift[m,f]:.4f}, HF={mel_hf[m,f]:.4f}, diff={abs(mel_swift[m,f]-mel_hf[m,f]):.6f}")

    if diff.mean() < 0.01:
        print("\n✓ MEL SPECTROGRAMS MATCH!")
    else:
        print("\n✗ MEL SPECTROGRAMS DIFFER!")

        # Find where they differ most
        max_diff_idx = np.unravel_index(np.argmax(diff), diff.shape)
        print(f"  Worst mismatch at {max_diff_idx}: Swift={mel_swift[max_diff_idx]:.4f}, HF={mel_hf[max_diff_idx]:.4f}")

        # Save for inspection
        np.save("mel_swift_audit.npy", mel_swift)
        np.save("mel_hf_audit.npy", mel_hf)
        print("  Saved mel_swift_audit.npy and mel_hf_audit.npy")

if __name__ == "__main__":
    main()
