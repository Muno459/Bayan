#!/usr/bin/env python3
"""
Compare mel spectrogram output: Python vs what iOS should produce.
This helps verify the CoreML mel extractor is working correctly.
"""

import torch
import numpy as np
from transformers import WhisperProcessor, WhisperForConditionalGeneration

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

def test_short_word():
    """Test transcribing a short word like 'la' (لا)."""
    print(f"Loading {MODEL_NAME}...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Simulate a short "la" sound -
    # A voiced fricative/stop would be ~100-300Hz fundamental with harmonics
    sr = 16000
    duration = 1.5  # seconds - similar to what user recorded (1.7s)
    t = np.linspace(0, duration, int(sr * duration))

    # Simulate "la" - /l/ is a lateral approximant, /a/ is an open vowel
    # Create a simple approximation with fundamental + harmonics
    f0 = 150  # fundamental frequency (typical male voice)

    # Envelope: quick onset, sustain, decay
    envelope = np.ones_like(t)
    attack = int(0.05 * sr)  # 50ms attack
    decay_start = int(0.8 * sr)  # decay starts at 0.8s
    envelope[:attack] = np.linspace(0, 1, attack)
    envelope[decay_start:] = np.linspace(1, 0, len(t) - decay_start)

    # Voice signal with harmonics
    voice = np.zeros_like(t)
    for harmonic in range(1, 6):
        voice += (1/harmonic) * np.sin(2 * np.pi * f0 * harmonic * t)

    # Add some noise (breathiness)
    voice += np.random.randn(len(t)) * 0.1

    # Apply envelope and normalize
    audio = (voice * envelope).astype(np.float32)
    audio = audio / np.abs(audio).max() * 0.5  # normalize to 0.5 peak

    print(f"\nSynthetic 'la' audio: {len(audio)} samples, {duration}s, max={np.abs(audio).max():.3f}")

    # Process with Whisper
    inputs = processor(audio, sampling_rate=sr, return_tensors="pt")
    mel = inputs["input_features"]
    print(f"Mel shape: {mel.shape}")
    print(f"Mel sum (first 1000): {mel[0, :, :1000].sum().item():.2f}")
    print(f"Mel min: {mel.min().item():.4f}, max: {mel.max().item():.4f}")

    # Get encoder output
    with torch.no_grad():
        encoder_out = model.model.encoder(mel)[0]
        print(f"Encoder output shape: {encoder_out.shape}")
        print(f"Encoder sum (first 1000): {encoder_out[0, :, :].flatten()[:1000].sum().item():.2f}")

    # Transcribe
    with torch.no_grad():
        forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
        generated = model.generate(
            mel,
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=10,
        )
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Transcription: '{text}'")
        print(f"Tokens: {generated[0].tolist()}")


def test_with_actual_la():
    """Test with various pronunciations of 'la'."""
    print("\n" + "="*50)
    print("Testing different audio patterns for 'لا'")
    print("="*50)

    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    sr = 16000

    tests = [
        ("Short burst (0.3s)", 0.3),
        ("Medium (0.8s)", 0.8),
        ("Long (1.5s)", 1.5),
        ("Very long (3s)", 3.0),
    ]

    for name, duration in tests:
        t = np.linspace(0, duration, int(sr * duration))
        f0 = 150

        # Simple voiced sound
        voice = np.sin(2 * np.pi * f0 * t)
        for h in range(2, 5):
            voice += (0.5/h) * np.sin(2 * np.pi * f0 * h * t)

        # Envelope
        envelope = np.ones_like(t)
        attack = min(int(0.03 * sr), len(t)//4)
        decay = min(int(0.1 * sr), len(t)//4)
        if attack > 0:
            envelope[:attack] = np.linspace(0, 1, attack)
        if decay > 0:
            envelope[-decay:] = np.linspace(1, 0, decay)

        audio = (voice * envelope).astype(np.float32)
        audio = audio / np.abs(audio).max() * 0.5

        inputs = processor(audio, sampling_rate=sr, return_tensors="pt")

        with torch.no_grad():
            forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
            generated = model.generate(
                inputs["input_features"],
                forced_decoder_ids=forced_decoder_ids,
                max_new_tokens=10,
            )
            text = processor.decode(generated[0], skip_special_tokens=True)
            print(f"{name}: '{text}'")


def test_real_arabic_words():
    """Test with some known Arabic words to verify the model works."""
    print("\n" + "="*50)
    print("Model sanity check - does it produce any reasonable Arabic?")
    print("="*50)

    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # The model was trained on Quran - let's see what it produces for various inputs
    sr = 16000

    # Test 1: Complete silence
    silence = np.zeros(sr * 5, dtype=np.float32)
    inputs = processor(silence, sampling_rate=sr, return_tensors="pt")
    with torch.no_grad():
        forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
        generated = model.generate(inputs["input_features"], forced_decoder_ids=forced_decoder_ids, max_new_tokens=10)
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Silence (5s): '{text}'")

    # Test 2: White noise at different levels
    for level in [0.01, 0.05, 0.1, 0.3]:
        noise = (np.random.randn(sr * 2) * level).astype(np.float32)
        inputs = processor(noise, sampling_rate=sr, return_tensors="pt")
        with torch.no_grad():
            generated = model.generate(inputs["input_features"], forced_decoder_ids=forced_decoder_ids, max_new_tokens=10)
            text = processor.decode(generated[0], skip_special_tokens=True)
            print(f"Noise (level={level}): '{text}'")


if __name__ == "__main__":
    test_short_word()
    test_with_actual_la()
    test_real_arabic_words()
