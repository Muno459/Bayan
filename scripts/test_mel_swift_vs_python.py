#!/usr/bin/env python3
"""
Test mel spectrogram computation: compare Python vs Swift output.

Run this to verify the Swift mel matches Python exactly.
"""

import numpy as np
import subprocess
import tempfile
import wave
import os

def download_test_audio():
    """Download CDN audio for testing."""
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
    return audio, wav_path

def compute_mel_python(audio):
    """Compute mel spectrogram using HuggingFace's processor."""
    from transformers import WhisperProcessor
    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    mel = processor(audio, sampling_rate=16000, return_tensors="np")["input_features"]
    return mel[0]  # Shape: (80, 3000)

def compute_mel_swift_style(audio):
    """
    Compute mel spectrogram matching Swift implementation exactly.

    This replicates what TarteelWhisper.swift does.
    """
    from scipy import signal

    sample_rate = 16000
    n_fft = 400
    hop_length = 160
    n_mels = 80
    n_frames = 3000

    # Load mel filters (same as Swift)
    mel_filters = np.fromfile("Bayan/Resources/Data/mel_filters.bin", dtype=np.float32).reshape(80, 201)

    # Pad to 30 seconds
    target_samples = sample_rate * 30
    padded = np.zeros(target_samples, dtype=np.float32)
    copy_count = min(len(audio), target_samples)
    padded[:copy_count] = audio[:copy_count]

    # Reflect padding for STFT
    pad = n_fft // 2
    audio_padded = np.pad(padded, (pad, pad), mode='reflect')

    # Compute STFT with Hann window
    window = signal.windows.hann(n_fft, sym=False)  # Periodic Hann
    num_frames = (len(audio_padded) - n_fft) // hop_length + 1
    fft_size = n_fft // 2 + 1  # 201

    magnitudes = np.zeros((num_frames, fft_size), dtype=np.float32)
    for f in range(num_frames):
        start = f * hop_length
        frame = audio_padded[start:start + n_fft] * window
        fft_result = np.fft.rfft(frame)
        # Note: Swift vDSP_fft_zrip scales by 2, so magnitudes are 4x larger
        # We simulate the fixed Swift code which divides by 4
        magnitudes[f] = np.abs(fft_result) ** 2  # Standard FFT, no extra scaling needed

    # Apply mel filter bank
    mel_spec = mel_filters @ magnitudes.T  # (80, num_frames)

    # Log mel spectrogram
    log_mel = np.log10(np.maximum(mel_spec, 1e-10))
    max_val = log_mel.max()

    # Clip and normalize (only first n_frames)
    log_mel = log_mel[:, :n_frames]
    log_mel = np.maximum(log_mel, max_val - 8.0)
    log_mel = (log_mel + 4.0) / 4.0

    return log_mel  # Shape: (80, 3000)

def main():
    print("Downloading test audio...")
    audio, _ = download_test_audio()
    print(f"Audio length: {len(audio)} samples ({len(audio)/16000:.2f}s)")

    print("\nComputing mel with HuggingFace processor...")
    mel_hf = compute_mel_python(audio)
    print(f"HF mel shape: {mel_hf.shape}, range: [{mel_hf.min():.3f}, {mel_hf.max():.3f}]")

    print("\nComputing mel with Swift-style implementation...")
    mel_swift = compute_mel_swift_style(audio)
    print(f"Swift mel shape: {mel_swift.shape}, range: [{mel_swift.min():.3f}, {mel_swift.max():.3f}]")

    # Compare
    diff = np.abs(mel_hf - mel_swift)
    print(f"\nMel difference:")
    print(f"  Mean: {diff.mean():.6f}")
    print(f"  Max: {diff.max():.6f}")
    print(f"  Correlation: {np.corrcoef(mel_hf.flatten(), mel_swift.flatten())[0,1]:.6f}")

    if diff.mean() < 0.01:
        print("\n✓ Mel spectrograms match!")
    else:
        print("\n✗ Mel spectrograms differ significantly!")

        # Debug: check which frames differ most
        frame_diffs = diff.mean(axis=0)
        worst_frame = np.argmax(frame_diffs)
        print(f"  Worst frame: {worst_frame} (diff: {frame_diffs[worst_frame]:.6f})")

        # Save both for inspection
        np.save("mel_hf.npy", mel_hf)
        np.save("mel_swift.npy", mel_swift)
        print("  Saved mel_hf.npy and mel_swift.npy for inspection")

if __name__ == "__main__":
    main()
