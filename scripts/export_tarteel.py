#!/usr/bin/env python3
"""
Export tarteel-ai/whisper-tiny-ar-quran to CoreML.

This exports:
1. TarteelEncoder - takes mel spectrogram, outputs encoder hidden states
2. TarteelDecoder - takes tokens + encoder output, outputs logits

The mel spectrogram is computed in Swift to ensure exact match.
"""

import torch
import numpy as np
import coremltools as ct
from transformers import WhisperForConditionalGeneration, WhisperProcessor
import subprocess
import tempfile
import wave
import os
import shutil

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"
OUTPUT_DIR = "Bayan/Resources/Data"


def download_test_audio():
    """Download CDN audio for testing."""
    url = "https://audio.qurancdn.com/wbw/002_002_003.mp3"
    mp3_path = tempfile.mktemp(suffix=".mp3")
    wav_path = tempfile.mktemp(suffix=".wav")
    subprocess.run(["curl", "-sL", "-o", mp3_path, url], capture_output=True)
    subprocess.run(["ffmpeg", "-y", "-i", mp3_path, "-ar", "16000", "-ac", "1", "-f", "wav", wav_path],
                   capture_output=True)

    with wave.open(wav_path, "rb") as wav:
        frames = wav.readframes(wav.getnframes())
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    os.unlink(mp3_path)
    os.unlink(wav_path)
    return audio


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("=" * 60)
    print("TARTEEL WHISPER COREML EXPORT")
    print("=" * 60)

    # Load model
    print("\n[1/6] Loading HuggingFace model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Test with CDN audio
    print("\n[2/6] Testing HuggingFace model...")
    audio = download_test_audio()
    mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

    with torch.no_grad():
        forced = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
        gen = model.generate(mel, forced_decoder_ids=forced, max_new_tokens=10)
        text = processor.decode(gen[0], skip_special_tokens=True)

    print(f"   Audio: {len(audio)} samples")
    print(f"   Mel: {mel.shape}")
    print(f"   Transcription: '{text}' (expected: 'لَا')")

    if "لَا" not in text and "لا" not in text and "ل" not in text:
        print("   ERROR: HuggingFace model not working correctly!")
        return
    print("   ✓ HuggingFace model works")

    # Export encoder
    print("\n[3/6] Exporting encoder...")

    class EncoderWrapper(torch.nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(self, mel):
            return self.encoder(mel).last_hidden_state

    encoder_wrapper = EncoderWrapper(model.model.encoder)
    encoder_wrapper.eval()

    dummy_mel = torch.randn(1, 80, 3000)
    traced_encoder = torch.jit.trace(encoder_wrapper, dummy_mel)

    encoder_model = ct.convert(
        traced_encoder,
        inputs=[ct.TensorType(name="mel", shape=(1, 80, 3000), dtype=np.float32)],
        outputs=[ct.TensorType(name="encoder_output", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )

    encoder_path = f"{OUTPUT_DIR}/TarteelEncoder.mlpackage"
    encoder_model.save(encoder_path)
    print(f"   ✓ Saved {encoder_path}")

    # Export decoder
    print("\n[4/6] Exporting decoder...")

    class DecoderWrapper(torch.nn.Module):
        def __init__(self, decoder, proj_out):
            super().__init__()
            self.decoder = decoder
            self.proj_out = proj_out

        def forward(self, input_ids, encoder_output):
            dec_out = self.decoder(
                input_ids=input_ids,
                encoder_hidden_states=encoder_output,
                use_cache=False
            )
            return self.proj_out(dec_out.last_hidden_state)

    decoder_wrapper = DecoderWrapper(model.model.decoder, model.proj_out)
    decoder_wrapper.eval()

    dummy_tokens = torch.tensor([[50258, 50272, 50359, 50363]], dtype=torch.long)
    dummy_enc = torch.randn(1, 1500, 384)

    with torch.no_grad():
        traced_decoder = torch.jit.trace(decoder_wrapper, (dummy_tokens, dummy_enc))

    decoder_model = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="input_ids", shape=ct.Shape((1, ct.RangeDim(1, 448))), dtype=np.int32),
            ct.TensorType(name="encoder_output", shape=(1, 1500, 384), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )

    decoder_path = f"{OUTPUT_DIR}/TarteelDecoder.mlpackage"
    decoder_model.save(decoder_path)
    print(f"   ✓ Saved {decoder_path}")

    # Save mel filter bank for iOS
    print("\n[5/6] Saving mel filter bank...")
    from transformers import WhisperFeatureExtractor
    fe = WhisperFeatureExtractor()
    mel_filters = fe.mel_filters.astype(np.float32)  # Shape: (80, 201)
    mel_filters.tofile(f"{OUTPUT_DIR}/mel_filters.bin")
    print(f"   ✓ Saved mel_filters.bin ({mel_filters.shape})")

    # Verify CoreML models (before compilation)
    print("\n[6/6] Verifying CoreML models...")

    # Use the mlpackage before compilation for verification
    encoder_cml = encoder_model
    decoder_cml = decoder_model

    # Test encoder
    mel_np = mel.numpy()
    enc_result = encoder_cml.predict({"mel": mel_np})
    enc_cml = enc_result["encoder_output"]

    with torch.no_grad():
        enc_hf = model.model.encoder(mel).last_hidden_state.numpy()

    enc_diff = np.abs(enc_cml - enc_hf).mean()
    print(f"   Encoder diff: {enc_diff:.6f}")

    # Test decoder
    tokens = np.array([[50258, 50272, 50359, 50363]], dtype=np.int32)
    dec_result = decoder_cml.predict({"input_ids": tokens, "encoder_output": enc_cml})
    logits_cml = dec_result["logits"]

    with torch.no_grad():
        dec_hf = model.model.decoder(
            input_ids=torch.tensor(tokens, dtype=torch.long),
            encoder_hidden_states=torch.tensor(enc_hf),
            use_cache=False
        )
        logits_hf = model.proj_out(dec_hf.last_hidden_state).numpy()

    logits_diff = np.abs(logits_cml - logits_hf).mean()
    print(f"   Logits diff: {logits_diff:.6f}")

    token_cml = int(np.argmax(logits_cml[0, -1, :51865]))
    token_hf = int(np.argmax(logits_hf[0, -1, :51865]))
    print(f"   Token - CoreML: {token_cml}, HF: {token_hf}")

    if token_cml == token_hf:
        print("   ✓ CoreML matches HuggingFace!")
    else:
        print("   ✗ CoreML differs from HuggingFace!")
        return

    # Save test data for iOS verification
    mel_np.astype(np.float32).tofile(f"{OUTPUT_DIR}/test_mel.bin")
    enc_hf.astype(np.float32).tofile(f"{OUTPUT_DIR}/test_encoder.bin")
    print(f"\n   Saved test_mel.bin and test_encoder.bin for iOS verification")
    print(f"   Expected token: {token_hf}")

    # Compile models for iOS
    print("\n[7/7] Compiling for iOS...")

    compiled_encoder = f"{OUTPUT_DIR}/TarteelEncoder.mlmodelc"
    if os.path.exists(compiled_encoder):
        shutil.rmtree(compiled_encoder)
    subprocess.run(["xcrun", "coremlcompiler", "compile", encoder_path, OUTPUT_DIR], check=True)
    shutil.rmtree(encoder_path)
    print(f"   ✓ Compiled {compiled_encoder}")

    compiled_decoder = f"{OUTPUT_DIR}/TarteelDecoder.mlmodelc"
    if os.path.exists(compiled_decoder):
        shutil.rmtree(compiled_decoder)
    subprocess.run(["xcrun", "coremlcompiler", "compile", decoder_path, OUTPUT_DIR], check=True)
    shutil.rmtree(decoder_path)
    print(f"   ✓ Compiled {compiled_decoder}")

    print("\n" + "=" * 60)
    print("EXPORT COMPLETE")
    print("=" * 60)


if __name__ == "__main__":
    main()
