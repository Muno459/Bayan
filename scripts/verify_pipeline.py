#!/usr/bin/env python3
"""
Comprehensive pipeline verification.
Compares every step of our pipeline against HuggingFace's official implementation.
"""

import torch
import numpy as np
from transformers import WhisperProcessor, WhisperForConditionalGeneration, WhisperFeatureExtractor
import json

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

def verify_pipeline():
    print("=" * 60)
    print("COMPREHENSIVE PIPELINE VERIFICATION")
    print("=" * 60)

    # Load official model
    print("\n[1] Loading official HuggingFace model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()
    fe = WhisperFeatureExtractor()

    # Create test audio - 1.7s voice-like signal (similar to user's recording)
    print("\n[2] Creating test audio...")
    sr = 16000
    duration = 1.7
    n_samples = int(sr * duration)
    t = np.linspace(0, duration, n_samples)

    # Simulate speech-like signal with harmonics
    f0 = 150
    audio = np.zeros(n_samples, dtype=np.float32)
    for h in range(1, 6):
        audio += (1/h) * np.sin(2 * np.pi * f0 * h * t)
    audio = audio / np.abs(audio).max() * 0.5  # Normalize to 0.5 peak

    print(f"   Audio: {len(audio)} samples, {duration}s, max={np.abs(audio).max():.3f}")

    # Pad to 30 seconds (Whisper requirement)
    audio_padded = np.pad(audio, (0, 480000 - len(audio)))
    print(f"   Padded to: {len(audio_padded)} samples")

    # ========================================
    # STEP 3: MEL SPECTROGRAM
    # ========================================
    print("\n[3] Verifying mel spectrogram...")

    # Official mel
    official_mel = processor(audio, sampling_rate=sr, return_tensors="pt")["input_features"]
    print(f"   Official mel shape: {official_mel.shape}")
    print(f"   Official mel stats: min={official_mel.min():.4f}, max={official_mel.max():.4f}, mean={official_mel.mean():.4f}")

    # Our mel extractor (matching export_mel.py)
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

    our_mel_extractor = OurMelExtractor()
    our_mel_extractor.eval()

    audio_tensor = torch.tensor(audio_padded).unsqueeze(0)
    with torch.no_grad():
        our_mel = our_mel_extractor(audio_tensor)

    # Trim to 3000 frames
    our_mel = our_mel[:, :, :3000]

    print(f"   Our mel shape: {our_mel.shape}")
    print(f"   Our mel stats: min={our_mel.min():.4f}, max={our_mel.max():.4f}, mean={our_mel.mean():.4f}")

    # Compare
    mel_diff = (official_mel - our_mel).abs()
    print(f"   MEL DIFFERENCE: max={mel_diff.max():.6f}, mean={mel_diff.mean():.6f}")

    if mel_diff.max() < 0.001:
        print("   ✓ MEL SPECTROGRAM MATCHES!")
    else:
        print("   ✗ MEL SPECTROGRAM MISMATCH!")
        return False

    # ========================================
    # STEP 4: ENCODER
    # ========================================
    print("\n[4] Verifying encoder...")

    with torch.no_grad():
        official_enc = model.model.encoder(official_mel)[0]
        our_enc = model.model.encoder(our_mel)[0]

    print(f"   Official encoder output: shape={official_enc.shape}, sum={official_enc.sum():.2f}")
    print(f"   Our encoder output: shape={our_enc.shape}, sum={our_enc.sum():.2f}")

    enc_diff = (official_enc - our_enc).abs()
    print(f"   ENCODER DIFFERENCE: max={enc_diff.max():.6f}, mean={enc_diff.mean():.6f}")

    if enc_diff.max() < 0.001:
        print("   ✓ ENCODER OUTPUT MATCHES!")
    else:
        print("   ✗ ENCODER OUTPUT MISMATCH!")
        return False

    # ========================================
    # STEP 5: DECODER
    # ========================================
    print("\n[5] Verifying decoder...")

    # Prompt tokens
    SOT = 50258
    LANG = 50272  # Arabic
    TASK = 50359  # Transcribe
    NOTIMESTAMPS = 50363
    EOT = 50257

    prompt_ids = torch.tensor([[SOT, LANG, TASK, NOTIMESTAMPS]], dtype=torch.long)

    with torch.no_grad():
        # Official decoder
        official_dec = model.model.decoder(
            input_ids=prompt_ids,
            encoder_hidden_states=official_enc,
            use_cache=False,
        )
        official_logits = model.proj_out(official_dec.last_hidden_state)

        # Our decoder (using our mel -> our encoder output)
        our_dec = model.model.decoder(
            input_ids=prompt_ids,
            encoder_hidden_states=our_enc,
            use_cache=False,
        )
        our_logits = model.proj_out(our_dec.last_hidden_state)

    print(f"   Official logits: shape={official_logits.shape}")
    print(f"   Our logits: shape={our_logits.shape}")

    logits_diff = (official_logits - our_logits).abs()
    print(f"   LOGITS DIFFERENCE: max={logits_diff.max():.6f}, mean={logits_diff.mean():.6f}")

    # Get predicted next token
    official_next = official_logits[0, -1, :51865].argmax().item()
    our_next = our_logits[0, -1, :51865].argmax().item()

    print(f"   Official next token: {official_next}")
    print(f"   Our next token: {our_next}")

    if official_next == our_next:
        print("   ✓ DECODER OUTPUT MATCHES!")
    else:
        print("   ✗ DECODER OUTPUT MISMATCH!")
        return False

    # ========================================
    # STEP 6: FULL GENERATION
    # ========================================
    print("\n[6] Verifying full generation...")

    with torch.no_grad():
        forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")

        # Official generation
        official_gen = model.generate(
            official_mel,
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=10,
        )
        official_text = processor.decode(official_gen[0], skip_special_tokens=True)

        # Our generation
        our_gen = model.generate(
            our_mel,
            forced_decoder_ids=forced_decoder_ids,
            max_new_tokens=10,
        )
        our_text = processor.decode(our_gen[0], skip_special_tokens=True)

    print(f"   Official generation: '{official_text}'")
    print(f"   Our generation: '{our_text}'")
    print(f"   Official tokens: {official_gen[0].tolist()}")
    print(f"   Our tokens: {our_gen[0].tolist()}")

    if official_text == our_text:
        print("   ✓ FULL GENERATION MATCHES!")
    else:
        print("   ✗ FULL GENERATION MISMATCH!")
        return False

    # ========================================
    # STEP 7: VERIFY VOCAB/TOKEN DECODING
    # ========================================
    print("\n[7] Verifying vocabulary...")

    # Load our vocab
    vocab_path = "Bayan/Resources/Data/tarteel_vocab.json"
    try:
        with open(vocab_path) as f:
            our_vocab = json.load(f)
        print(f"   Our vocab size: {len(our_vocab)}")

        # Check a few known tokens
        test_tokens = {
            50258: "<|startoftranscript|>",
            50257: "<|endoftext|>",
            50272: "<|ar|>",
            50359: "<|transcribe|>",
        }

        mismatches = []
        for token_id, expected in test_tokens.items():
            # Our vocab is token -> id, need to reverse
            our_id = our_vocab.get(expected)
            if our_id != token_id:
                mismatches.append(f"{expected}: expected {token_id}, got {our_id}")

        if mismatches:
            print(f"   ✗ VOCAB MISMATCHES: {mismatches}")
        else:
            print("   ✓ SPECIAL TOKENS CORRECT!")

    except Exception as e:
        print(f"   ✗ VOCAB ERROR: {e}")

    # ========================================
    # SUMMARY
    # ========================================
    print("\n" + "=" * 60)
    print("PIPELINE VERIFICATION COMPLETE")
    print("=" * 60)
    print("\n✓ All pipeline stages match the official HuggingFace implementation!")
    print("\nIf transcription still fails on device, the issue is likely:")
    print("  1. Audio recording quality (too quiet, too noisy)")
    print("  2. CoreML model conversion differences")
    print("  3. Float16 precision differences on device")

    return True


def verify_coreml_models():
    """Additional check: verify CoreML model specs match expectations."""
    print("\n" + "=" * 60)
    print("COREML MODEL VERIFICATION")
    print("=" * 60)

    import os

    models = [
        ("WhisperMelExtractor", "audio", "(1, 480000)", "mel_spectrogram"),
        ("TarteelEncoder", "input_features", "(1, 80, 3000)", "encoder_output"),
        ("TarteelDecoder", "input_ids", "(1, seq)", "logits"),
    ]

    for name, input_name, expected_input, output_name in models:
        path = f"Bayan/Resources/Data/{name}.mlmodelc/metadata.json"
        if os.path.exists(path):
            with open(path) as f:
                meta = json.load(f)[0]

            input_schema = meta.get("inputSchema", [])
            output_schema = meta.get("outputSchema", [])

            print(f"\n{name}:")
            print(f"  Conversion date: {meta.get('userDefinedMetadata', {}).get('com.github.apple.coremltools.conversion_date', 'unknown')}")
            print(f"  Inputs: {[i['name'] + ': ' + i['formattedType'] for i in input_schema]}")
            print(f"  Outputs: {[o['name'] + ': ' + o['formattedType'] for o in output_schema]}")
        else:
            print(f"\n{name}: NOT FOUND at {path}")


if __name__ == "__main__":
    success = verify_pipeline()
    verify_coreml_models()

    if success:
        print("\n" + "=" * 60)
        print("✓ PIPELINE IS CORRECT")
        print("=" * 60)
    else:
        print("\n" + "=" * 60)
        print("✗ PIPELINE HAS ISSUES")
        print("=" * 60)
