#!/usr/bin/env python3
"""
Compare our custom mel extractor with Whisper's official preprocessing.
This will show exactly what's wrong.
"""

import torch
import numpy as np
from transformers import WhisperProcessor, WhisperFeatureExtractor

def compare_mel_extractors():
    print("=== Comparing Mel Extractors ===\n")

    # Create test audio - 1.7s of voiced sound (similar to user's recording)
    sr = 16000
    duration = 1.7
    t = np.linspace(0, duration, int(sr * duration))
    f0 = 150
    audio = np.sin(2 * np.pi * f0 * t).astype(np.float32) * 0.5

    # Pad to 30 seconds (480000 samples) like Whisper expects
    audio_padded = np.pad(audio, (0, 480000 - len(audio)))

    print(f"Audio: {len(audio)} samples, padded to {len(audio_padded)}")

    # === Method 1: Official Whisper Feature Extractor ===
    print("\n--- Official WhisperFeatureExtractor ---")
    fe = WhisperFeatureExtractor()
    official_mel = fe(audio, sampling_rate=sr, return_tensors="pt")["input_features"]
    print(f"Shape: {official_mel.shape}")
    print(f"Min: {official_mel.min().item():.4f}, Max: {official_mel.max().item():.4f}")
    print(f"Mean: {official_mel.mean().item():.4f}, Std: {official_mel.std().item():.4f}")
    print(f"Sum (first 1000): {official_mel[0, :, :].flatten()[:1000].sum().item():.2f}")

    # === Method 2: Our custom mel extractor (from notebook) ===
    print("\n--- Our Custom MelExtractor ---")

    class MelExtractor(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.n_fft = 400
            self.hop_length = 160
            fe = WhisperFeatureExtractor()
            # NOTE: mel_filters from FE is (201, 80), we need (80, 201) for matmul
            print(f"  mel_filters from FE: {fe.mel_filters.shape}")
            self.register_buffer("mel_filters", torch.tensor(fe.mel_filters.T, dtype=torch.float32))

        def forward(self, audio):
            window = torch.hann_window(self.n_fft, device=audio.device)
            stft = torch.stft(audio.squeeze(0), n_fft=self.n_fft, hop_length=self.hop_length,
                              window=window, return_complex=True)
            magnitudes = stft.abs() ** 2
            mel_spec = torch.matmul(self.mel_filters, magnitudes)
            log_mel = torch.clamp(mel_spec, min=1e-10).log10()
            log_mel = torch.maximum(log_mel, log_mel.max() - 8.0)
            log_mel = (log_mel + 4.0) / 4.0
            return log_mel.unsqueeze(0)

    mel_extractor = MelExtractor()
    mel_extractor.eval()

    audio_tensor = torch.tensor(audio_padded).unsqueeze(0)
    with torch.no_grad():
        custom_mel = mel_extractor(audio_tensor)

    print(f"Shape: {custom_mel.shape}")
    print(f"Min: {custom_mel.min().item():.4f}, Max: {custom_mel.max().item():.4f}")
    print(f"Mean: {custom_mel.mean().item():.4f}, Std: {custom_mel.std().item():.4f}")
    print(f"Sum (first 1000): {custom_mel[0, :, :].flatten()[:1000].sum().item():.2f}")

    # === Compare ===
    print("\n--- Comparison ---")

    # Trim to same size
    min_frames = min(official_mel.shape[2], custom_mel.shape[2])
    official_trimmed = official_mel[:, :, :min_frames]
    custom_trimmed = custom_mel[:, :, :min_frames]

    diff = (official_trimmed - custom_trimmed).abs()
    print(f"Absolute difference - Mean: {diff.mean().item():.4f}, Max: {diff.max().item():.4f}")

    correlation = torch.corrcoef(torch.stack([
        official_trimmed.flatten(),
        custom_trimmed.flatten()
    ]))[0, 1].item()
    print(f"Correlation: {correlation:.4f}")

    if correlation < 0.9:
        print("\n⚠️  LOW CORRELATION - Mel extractors produce different outputs!")
        print("This explains why the model fails.")
    else:
        print("\n✓ High correlation - Mel extractors are similar")

    # === Show what official Whisper does differently ===
    print("\n--- Whisper's actual preprocessing steps ---")
    print(f"1. n_fft: {fe.n_fft}")
    print(f"2. hop_length: {fe.hop_length}")
    print(f"3. n_mels: {fe.n_mels}")
    print(f"4. sampling_rate: {fe.sampling_rate}")
    print(f"5. feature_size: {fe.feature_size}")
    print(f"6. padding_value: {fe.padding_value}")
    print(f"7. mel_filters shape: {fe.mel_filters.shape}")

    # Check if filters match
    our_filters = mel_extractor.mel_filters.numpy()
    whisper_filters = fe.mel_filters
    filter_diff = np.abs(our_filters - whisper_filters).max()
    print(f"8. Mel filter max difference: {filter_diff:.6f}")

if __name__ == "__main__":
    compare_mel_extractors()
