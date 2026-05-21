#!/usr/bin/env python3
"""
Test the full Whisper pipeline with our corrected mel extractor.
"""

import torch
import numpy as np
from transformers import WhisperProcessor, WhisperForConditionalGeneration, WhisperFeatureExtractor

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

def test_pipeline():
    print("Loading models...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Create our mel extractor (matching export_mel.py)
    fe = WhisperFeatureExtractor()

    class OurMelExtractor(torch.nn.Module):
        def __init__(self):
            super().__init__()
            self.n_fft = 400
            self.hop_length = 160
            self.register_buffer("mel_filters", torch.tensor(fe.mel_filters.T, dtype=torch.float32))

        def forward(self, audio):
            pad = self.n_fft // 2
            audio_padded = torch.nn.functional.pad(audio, (pad, pad), mode='reflect')
            audio_1d = audio_padded.squeeze(0)

            window = torch.hann_window(self.n_fft, device=audio.device, dtype=audio.dtype)
            stft = torch.stft(audio_1d, n_fft=self.n_fft, hop_length=self.hop_length,
                             window=window, return_complex=True, center=False)
            magnitudes = stft.abs() ** 2
            mel_spec = torch.matmul(self.mel_filters, magnitudes)

            log_mel = torch.clamp(mel_spec, min=1e-10).log10()
            log_mel = torch.maximum(log_mel, log_mel.max() - 8.0)
            log_mel = (log_mel + 4.0) / 4.0

            return log_mel.unsqueeze(0)

    our_mel = OurMelExtractor()
    our_mel.eval()

    # Test 1: Synthetic "la" sound
    print("\n=== Test 1: Synthetic voice (should produce something) ===")
    sr = 16000
    duration = 1.5
    t = np.linspace(0, duration, int(sr * duration))
    f0 = 150
    audio = np.sin(2 * np.pi * f0 * t).astype(np.float32)
    for h in range(2, 5):
        audio += (0.5/h) * np.sin(2 * np.pi * f0 * h * t)
    audio = audio / np.abs(audio).max() * 0.5

    # Pad to 30s
    audio_padded = np.pad(audio, (0, 480000 - len(audio)))
    audio_tensor = torch.tensor(audio_padded).unsqueeze(0)

    # Our mel extractor
    with torch.no_grad():
        our_mel_output = our_mel(audio_tensor)
        # Trim to 3000 frames to match encoder expectation
        our_mel_output = our_mel_output[:, :, :3000]
        print(f"Our mel: shape={our_mel_output.shape}, sum={our_mel_output.sum().item():.2f}")

        # Run through encoder
        encoder_out = model.model.encoder(our_mel_output)[0]
        print(f"Encoder: shape={encoder_out.shape}, sum={encoder_out.sum().item():.2f}")

        # Generate
        forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
        generated = model.generate(
            our_mel_output,
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=10,
        )
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Transcription (our mel): '{text}'")

    # Compare with official
    official_mel = processor(audio, sampling_rate=sr, return_tensors="pt")["input_features"]
    print(f"Official mel: shape={official_mel.shape}, sum={official_mel.sum().item():.2f}")

    with torch.no_grad():
        generated = model.generate(
            official_mel,
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=10,
        )
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Transcription (official mel): '{text}'")

    # Test 2: Different pattern
    print("\n=== Test 2: Silence vs Noise ===")

    # Silence
    silence = np.zeros(480000, dtype=np.float32)
    silence_tensor = torch.tensor(silence).unsqueeze(0)
    with torch.no_grad():
        silence_mel = our_mel(silence_tensor)[:, :, :3000]
        generated = model.generate(silence_mel, forced_decoder_ids=forced_decoder_ids, max_new_tokens=10)
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Silence (our mel): '{text}'")

    # Noise
    noise = (np.random.randn(480000) * 0.5).astype(np.float32)
    noise_tensor = torch.tensor(noise).unsqueeze(0)
    with torch.no_grad():
        noise_mel = our_mel(noise_tensor)[:, :, :3000]
        generated = model.generate(noise_mel, forced_decoder_ids=forced_decoder_ids, max_new_tokens=10)
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Noise (our mel): '{text}'")

    print("\n✓ Pipeline test complete!")

if __name__ == "__main__":
    test_pipeline()
