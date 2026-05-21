#!/usr/bin/env python3
"""
Compare mel spectrogram computation: Swift-style vs HuggingFace.
This verifies our Swift implementation is correct.
"""

import numpy as np
import subprocess
import tempfile
import wave
import os
from transformers import WhisperProcessor


def download_audio(url):
    """Download and convert audio to 16kHz mono WAV."""
    mp3_path = tempfile.mktemp(suffix=".mp3")
    wav_path = tempfile.mktemp(suffix=".wav")

    subprocess.run(["curl", "-sL", "-o", mp3_path, url], check=True)
    subprocess.run([
        "ffmpeg", "-y", "-i", mp3_path,
        "-ar", "16000", "-ac", "1", "-f", "wav", wav_path
    ], capture_output=True, check=True)

    with wave.open(wav_path, "rb") as wav:
        frames = wav.readframes(wav.getnframes())
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    os.unlink(mp3_path)
    os.unlink(wav_path)
    return audio


def compute_mel_swift_style(audio, mel_filters):
    """
    Compute mel spectrogram exactly as Swift/Accelerate does.
    This matches TarteelWhisper.swift implementation.
    """
    sample_rate = 16000
    n_fft = 400
    hop_length = 160
    n_mels = 80
    n_frames = 3000

    # Pad to 30 seconds
    target_samples = sample_rate * 30
    padded = np.zeros(target_samples, dtype=np.float32)
    copy_count = min(len(audio), target_samples)
    padded[:copy_count] = audio[:copy_count]

    # Reflect padding for STFT
    pad = n_fft // 2
    audio_padded = np.zeros(len(padded) + 2 * pad, dtype=np.float32)
    # Reflect left: indices [0, pad-1] = audio[1:pad+1] reversed
    audio_padded[:pad] = padded[1:pad+1][::-1]
    # Center
    audio_padded[pad:pad+len(padded)] = padded
    # Reflect right
    audio_padded[pad+len(padded):] = padded[-2:-pad-2:-1]

    # Hann window (matching vDSP_hann_window NORM)
    window = np.hanning(n_fft).astype(np.float32)

    # STFT
    num_frames = (len(audio_padded) - n_fft) // hop_length + 1
    fft_size = n_fft // 2 + 1  # 201

    magnitudes = np.zeros((num_frames, fft_size), dtype=np.float32)

    for f in range(num_frames):
        start = f * hop_length
        frame = audio_padded[start:start + n_fft] * window

        # FFT - rfft gives the first fft_size complex values
        fft_result = np.fft.rfft(frame)
        magnitudes[f] = np.abs(fft_result) ** 2

    # Apply mel filter bank: (80, 201) @ (num_frames, 201).T -> (80, num_frames)
    mel_spec = mel_filters @ magnitudes.T

    # Log mel with clipping (only use n_frames columns)
    log_mel = np.log10(np.maximum(mel_spec[:, :n_frames], 1e-10))
    max_val = log_mel.max()
    log_mel = np.maximum(log_mel, max_val - 8.0)
    log_mel = (log_mel + 4.0) / 4.0

    return log_mel.astype(np.float32)


def main():
    print("=" * 70)
    print("MEL SPECTROGRAM COMPARISON")
    print("=" * 70)

    # Load mel filters
    mel_filters_path = "Bayan/Resources/Data/mel_filters.bin"
    mel_filters = np.fromfile(mel_filters_path, dtype=np.float32).reshape(80, 201)
    print(f"\nMel filters loaded: {mel_filters.shape}")

    # Load HuggingFace processor
    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")

    # Test audio
    print("\nDownloading test audio...")
    audio = download_audio("https://audio.qurancdn.com/wbw/002_002_003.mp3")
    print(f"Audio samples: {len(audio)} ({len(audio)/16000:.2f}s)")

    # Compute both mel spectrograms
    print("\nComputing mel spectrograms...")

    # HuggingFace
    mel_hf = processor(audio, sampling_rate=16000, return_tensors="np")["input_features"][0]
    print(f"HuggingFace mel: {mel_hf.shape}, range [{mel_hf.min():.3f}, {mel_hf.max():.3f}]")

    # Swift-style
    mel_swift = compute_mel_swift_style(audio, mel_filters)
    print(f"Swift-style mel: {mel_swift.shape}, range [{mel_swift.min():.3f}, {mel_swift.max():.3f}]")

    # Compare
    diff = np.abs(mel_hf - mel_swift)
    print(f"\nDifference statistics:")
    print(f"  Mean:   {diff.mean():.6f}")
    print(f"  Std:    {diff.std():.6f}")
    print(f"  Max:    {diff.max():.6f}")
    print(f"  Median: {np.median(diff):.6f}")

    # Where are the differences?
    mel_region = mel_hf[:, :200]  # First 200 frames (where audio is)
    swift_region = mel_swift[:, :200]
    region_diff = np.abs(mel_region - swift_region)
    print(f"\nIn audio region (first 200 frames):")
    print(f"  Mean diff: {region_diff.mean():.6f}")
    print(f"  Max diff:  {region_diff.max():.6f}")

    # Correlation
    corr = np.corrcoef(mel_hf.flatten(), mel_swift.flatten())[0, 1]
    print(f"\nCorrelation: {corr:.6f}")

    # Decision
    print("\n" + "=" * 70)
    if region_diff.mean() < 0.1 and corr > 0.95:
        print("MEL SPECTROGRAM IMPLEMENTATION: ACCEPTABLE")
        print("Small differences may cause minor transcription variations.")
    else:
        print("MEL SPECTROGRAM IMPLEMENTATION: NEEDS WORK")
        print("Significant differences may cause transcription errors.")
    print("=" * 70)


if __name__ == "__main__":
    main()
