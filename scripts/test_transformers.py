#!/usr/bin/env python3
"""
Test the Tarteel model using HuggingFace transformers directly.
This verifies the model works correctly before CoreML conversion.
"""

import torch
import numpy as np

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

def test_model():
    from transformers import WhisperProcessor, WhisperForConditionalGeneration

    print(f"Loading {MODEL_NAME}...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    print("\n=== Test 1: Silence (should produce minimal/no output) ===")
    silence = np.zeros(16000 * 5, dtype=np.float32)  # 5 seconds of silence
    inputs = processor(silence, sampling_rate=16000, return_tensors="pt")

    with torch.no_grad():
        forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
        generated = model.generate(
            inputs["input_features"],
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=20,
        )
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Transcription: '{text}'")
        print(f"Tokens: {generated[0].tolist()}")

    print("\n=== Test 2: Random noise (may produce hallucinations) ===")
    noise = np.random.randn(16000 * 5).astype(np.float32) * 0.1
    inputs = processor(noise, sampling_rate=16000, return_tensors="pt")

    with torch.no_grad():
        generated = model.generate(
            inputs["input_features"],
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=20,
        )
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Transcription: '{text}'")
        print(f"Tokens: {generated[0].tolist()}")

    print("\n=== Test 3: 440Hz tone (should be gibberish for this model) ===")
    t = np.linspace(0, 5, 16000 * 5)
    tone = np.sin(2 * np.pi * 440 * t).astype(np.float32) * 0.5
    inputs = processor(tone, sampling_rate=16000, return_tensors="pt")

    with torch.no_grad():
        generated = model.generate(
            inputs["input_features"],
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=20,
        )
        text = processor.decode(generated[0], skip_special_tokens=True)
        print(f"Transcription: '{text}'")
        print(f"Tokens: {generated[0].tolist()}")

    print("\n=== Test 4: Compare encoder outputs ===")
    # Test that encoder produces different outputs for different inputs
    silence_input = processor(silence, sampling_rate=16000, return_tensors="pt")["input_features"]
    noise_input = processor(noise, sampling_rate=16000, return_tensors="pt")["input_features"]
    tone_input = processor(tone, sampling_rate=16000, return_tensors="pt")["input_features"]

    with torch.no_grad():
        enc_silence = model.model.encoder(silence_input)[0]
        enc_noise = model.model.encoder(noise_input)[0]
        enc_tone = model.model.encoder(tone_input)[0]

        print(f"Encoder output shape: {enc_silence.shape}")
        print(f"Silence encoder sum: {enc_silence.sum().item():.2f}")
        print(f"Noise encoder sum: {enc_noise.sum().item():.2f}")
        print(f"Tone encoder sum: {enc_tone.sum().item():.2f}")

        # Check if outputs are different
        diff_sn = (enc_silence - enc_noise).abs().sum().item()
        diff_st = (enc_silence - enc_tone).abs().sum().item()
        print(f"Difference silence vs noise: {diff_sn:.2f}")
        print(f"Difference silence vs tone: {diff_st:.2f}")

    print("\n=== Test 5: Check decoder cross-attention ===")
    # Manually run decoder to verify cross-attention works
    decoder_input_ids = torch.tensor([[50258, 50272, 50359, 50363]])  # SOT, AR, TRANSCRIBE, NOTIMESTAMPS

    with torch.no_grad():
        # Run with silence encoder output
        out_silence = model.model.decoder(
            input_ids=decoder_input_ids,
            encoder_hidden_states=enc_silence,
            use_cache=False,
        )

        # Run with noise encoder output
        out_noise = model.model.decoder(
            input_ids=decoder_input_ids,
            encoder_hidden_states=enc_noise,
            use_cache=False,
        )

        # Check if outputs differ
        logits_silence = model.proj_out(out_silence.last_hidden_state)
        logits_noise = model.proj_out(out_noise.last_hidden_state)

        print(f"Logits shape: {logits_silence.shape}")
        diff = (logits_silence - logits_noise).abs().sum().item()
        print(f"Logits difference: {diff:.2f}")

        # Get predicted tokens
        pred_silence = logits_silence[0, -1, :51865].argmax().item()
        pred_noise = logits_noise[0, -1, :51865].argmax().item()
        print(f"Predicted next token (silence): {pred_silence}")
        print(f"Predicted next token (noise): {pred_noise}")

        if pred_silence != pred_noise:
            print("✓ Different encoder outputs produce different decoder predictions!")
        else:
            print("⚠ Same prediction for different inputs - may indicate cross-attention issue")

if __name__ == "__main__":
    test_model()
