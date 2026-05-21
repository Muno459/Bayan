#!/usr/bin/env python3
"""
End-to-end CoreML model test.

Tests the full pipeline: audio -> mel -> encoder -> decoder -> text
"""

import numpy as np
import subprocess
import tempfile
import wave
import os
import json

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

def compute_mel_hf(audio):
    """Compute mel using HuggingFace processor (known-good)."""
    from transformers import WhisperProcessor
    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    mel = processor(audio, sampling_rate=16000, return_tensors="np")["input_features"]
    return mel.astype(np.float32)

def run_swift_inference(audio):
    """
    Run inference using Swift CLI tool.
    This will help us verify the Swift implementation.
    """
    # Save audio to temp file
    wav_path = tempfile.mktemp(suffix=".wav")
    import wave
    with wave.open(wav_path, "wb") as f:
        f.setnchannels(1)
        f.setsampwidth(2)
        f.setframerate(16000)
        audio_int16 = (audio * 32767).astype(np.int16)
        f.writeframes(audio_int16.tobytes())

    # TODO: Create a Swift CLI test tool
    os.unlink(wav_path)
    return None

def run_inference_via_predict(mel):
    """
    Run inference using coremltools predict.
    This tests the models directly.
    """
    import coremltools as ct

    # Load models
    encoder = ct.models.MLModel("Bayan/Resources/Data/TarteelEncoder.mlpackage")
    decoder = ct.models.MLModel("Bayan/Resources/Data/TarteelDecoder.mlpackage")

    # Run encoder
    enc_out = encoder.predict({"mel": mel})["encoder_output"]
    print(f"Encoder output shape: {enc_out.shape}")

    # Decode
    sot, eot = 50258, 50257
    lang, task, no_ts = 50272, 50359, 50363
    prompt = [sot, lang, task, no_ts]
    pad_token = eot
    MAX_SEQ_LEN = 24

    tokens = prompt.copy()
    for step in range(20):
        padded = tokens + [pad_token] * (MAX_SEQ_LEN - len(tokens))
        ids = np.array([padded], dtype=np.int32)
        logits = decoder.predict({"input_ids": ids, "encoder_output": enc_out})["logits"]

        # Get next token from last actual position
        pos = len(tokens) - 1
        next_tok = int(np.argmax(logits[0, pos, :50364]))

        if next_tok == eot:
            break
        tokens.append(next_tok)

    return tokens[4:]  # Skip prompt

def decode_tokens(tokens):
    """Decode tokens to text using HuggingFace processor."""
    from transformers import WhisperProcessor
    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    return processor.decode(tokens, skip_special_tokens=True)

def main():
    print("=" * 60)
    print("COREML END-TO-END TEST")
    print("=" * 60)

    # Download audio
    print("\n[1/4] Downloading test audio...")
    audio = download_test_audio()
    print(f"Audio: {len(audio)} samples ({len(audio)/16000:.2f}s)")

    # Compute mel with HuggingFace
    print("\n[2/4] Computing mel spectrogram...")
    mel = compute_mel_hf(audio)
    print(f"Mel shape: {mel.shape}")

    # Check if mlpackage exists
    encoder_pkg = "Bayan/Resources/Data/TarteelEncoder.mlpackage"
    decoder_pkg = "Bayan/Resources/Data/TarteelDecoder.mlpackage"

    if not os.path.exists(encoder_pkg) or not os.path.exists(decoder_pkg):
        print("\n[!] mlpackage files not found - running export first...")
        subprocess.run(["python3", "scripts/export_tarteel_ane.py"])

    # Run inference
    print("\n[3/4] Running CoreML inference...")
    try:
        tokens = run_inference_via_predict(mel)
        print(f"Generated tokens: {tokens}")

        # Decode
        print("\n[4/4] Decoding tokens...")
        text = decode_tokens(tokens)
        print(f"Output text: '{text}'")

        # Expected for this audio
        print(f"\nExpected: 'الْحَمْدُ' (or similar)")
        if "الحمد" in text or "الْحَمْدُ" in text:
            print("✓ Output looks correct!")
        else:
            print("✗ Output may be incorrect")

    except Exception as e:
        print(f"Error: {e}")
        import traceback
        traceback.print_exc()

    print("\n" + "=" * 60)

if __name__ == "__main__":
    main()
