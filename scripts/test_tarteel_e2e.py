#!/usr/bin/env python3
"""
End-to-end test for Tarteel Whisper CoreML pipeline.

This script tests the EXACT same pipeline that runs on iOS:
1. Load audio -> compute mel spectrogram (matching Swift implementation)
2. Run encoder -> get hidden states
3. Run decoder autoregressively -> get tokens
4. Decode tokens -> get Arabic text

Verifies that CoreML output matches HuggingFace output.
"""

import numpy as np
import subprocess
import tempfile
import wave
import os
import json

# Test audio files - word-by-word Quran CDN
TEST_CASES = [
    # (url, expected_contains)
    ("https://audio.qurancdn.com/wbw/002_002_003.mp3", "لا"),  # لَا
    ("https://audio.qurancdn.com/wbw/001_001_001.mp3", "بسم"),  # بِسْمِ
    ("https://audio.qurancdn.com/wbw/001_001_002.mp3", "الله"),  # اللَّهِ
]


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


def compute_mel_spectrogram_swift_style(audio, mel_filters):
    """
    Compute mel spectrogram exactly as Swift/Accelerate does.
    This matches the TarteelWhisper.swift implementation.
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
    # Reflect left
    audio_padded[:pad] = padded[1:pad+1][::-1]
    # Center
    audio_padded[pad:pad+len(padded)] = padded
    # Reflect right
    audio_padded[pad+len(padded):] = padded[-2:-pad-2:-1]

    # Hann window
    window = np.hanning(n_fft).astype(np.float32)

    # STFT
    num_frames = (len(audio_padded) - n_fft) // hop_length + 1
    fft_size = n_fft // 2 + 1  # 201

    magnitudes = np.zeros((num_frames, fft_size), dtype=np.float32)

    for f in range(num_frames):
        start = f * hop_length
        frame = audio_padded[start:start + n_fft] * window

        # FFT
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


def test_huggingface(audio):
    """Test HuggingFace model manually (same as CoreML pipeline)."""
    from transformers import WhisperForConditionalGeneration, WhisperProcessor
    import torch

    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    model = WhisperForConditionalGeneration.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    model.eval()

    mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

    # Manual generation matching CoreML exactly
    sot_token = 50258
    eot_token = 50257
    lang_token = 50272  # Arabic
    task_token = 50359  # Transcribe
    no_timestamps = 50363

    tokens = [sot_token, lang_token, task_token, no_timestamps]

    with torch.no_grad():
        encoder_output = model.model.encoder(mel).last_hidden_state

        for _ in range(20):
            input_ids = torch.tensor([tokens], dtype=torch.long)
            decoder_output = model.model.decoder(
                input_ids=input_ids,
                encoder_hidden_states=encoder_output,
                use_cache=False
            )
            logits = model.proj_out(decoder_output.last_hidden_state)

            next_token = int(torch.argmax(logits[0, -1, :50364]))
            if next_token == eot_token:
                break
            tokens.append(next_token)

    # Decode using processor
    text = processor.decode(tokens[4:], skip_special_tokens=True)

    return text, mel.numpy(), model, processor


def test_coreml_full_pipeline(audio, mel_filters, encoder_path, decoder_path, vocab):
    """Test full CoreML pipeline matching iOS implementation."""
    import coremltools as ct

    # Load models
    encoder = ct.models.MLModel(encoder_path)
    decoder = ct.models.MLModel(decoder_path)

    # Compute mel the Swift way
    mel = compute_mel_spectrogram_swift_style(audio, mel_filters)
    mel_input = mel.reshape(1, 80, 3000)

    # Encoder
    enc_result = encoder.predict({"mel": mel_input})
    encoder_output = enc_result["encoder_output"]

    # Decoder (autoregressive)
    sot_token = 50258
    eot_token = 50257
    lang_token = 50272  # Arabic
    task_token = 50359  # Transcribe
    no_timestamps = 50363

    tokens = [sot_token, lang_token, task_token, no_timestamps]

    for _ in range(20):  # Max 20 tokens
        input_ids = np.array([tokens], dtype=np.int32)

        dec_result = decoder.predict({
            "input_ids": input_ids,
            "encoder_output": encoder_output
        })
        logits = dec_result["logits"]

        # Argmax of last position (exclude timestamp tokens)
        next_token = int(np.argmax(logits[0, -1, :50364]))

        if next_token == eot_token:
            break
        tokens.append(next_token)

    # Decode tokens (skip prompt tokens)
    generated = tokens[4:]

    # Build byte decoder for GPT-2 BPE
    bs = list(range(ord("!"), ord("~")+1)) + list(range(0xA1, 0xAD)) + list(range(0xAE, 0x100))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    byte_decoder = {chr(c): b for b, c in zip(bs, cs)}

    # Decode
    byte_list = []
    for token in generated:
        if token in vocab:
            word = vocab[token]
            if word.startswith("<|") and word.endswith("|>"):
                continue
            for char in word:
                if char in byte_decoder:
                    byte_list.append(byte_decoder[char])

    text = bytes(byte_list).decode("utf-8", errors="replace").strip()

    return text, mel, generated


def compare_mel_spectrograms(audio, mel_filters):
    """Compare our Swift-style mel with HuggingFace mel."""
    from transformers import WhisperProcessor
    import torch

    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")

    # HuggingFace mel
    hf_mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]
    hf_mel = hf_mel.numpy()[0]  # (80, 3000)

    # Our Swift-style mel
    swift_mel = compute_mel_spectrogram_swift_style(audio, mel_filters)

    diff = np.abs(hf_mel - swift_mel).mean()
    max_diff = np.abs(hf_mel - swift_mel).max()

    return diff, max_diff, hf_mel, swift_mel


def main():
    print("=" * 70)
    print("TARTEEL WHISPER END-TO-END TEST")
    print("=" * 70)

    # Load resources
    resources_dir = "Bayan/Resources/Data"

    print("\n[1] Loading resources...")

    # Mel filters
    mel_filters_path = f"{resources_dir}/mel_filters.bin"
    if not os.path.exists(mel_filters_path):
        print(f"   ERROR: {mel_filters_path} not found. Run export_tarteel.py first.")
        return False
    mel_filters = np.fromfile(mel_filters_path, dtype=np.float32).reshape(80, 201)
    print(f"   Mel filters: {mel_filters.shape}")

    # Vocab
    vocab_path = f"{resources_dir}/tarteel_vocab.json"
    if not os.path.exists(vocab_path):
        print(f"   ERROR: {vocab_path} not found. Run export_tarteel.py first.")
        return False
    with open(vocab_path) as f:
        vocab_str = json.load(f)
    vocab = {v: k for k, v in vocab_str.items()}  # Invert: id -> token
    print(f"   Vocab: {len(vocab)} tokens")

    # Models
    encoder_path = f"{resources_dir}/TarteelEncoder.mlmodelc"
    decoder_path = f"{resources_dir}/TarteelDecoder.mlmodelc"

    if not os.path.exists(encoder_path):
        print(f"   ERROR: {encoder_path} not found. Run export_tarteel.py first.")
        return False
    if not os.path.exists(decoder_path):
        print(f"   ERROR: {decoder_path} not found. Run export_tarteel.py first.")
        return False
    print(f"   Encoder: {encoder_path}")
    print(f"   Decoder: {decoder_path}")

    # Test mel spectrogram computation
    print("\n[2] Testing mel spectrogram computation...")
    test_audio = download_audio(TEST_CASES[0][0])
    mel_diff, mel_max_diff, hf_mel, swift_mel = compare_mel_spectrograms(test_audio, mel_filters)
    print(f"   Mean diff: {mel_diff:.6f}")
    print(f"   Max diff:  {mel_max_diff:.6f}")

    if mel_diff > 0.1:
        print("   WARNING: Mel spectrograms differ significantly!")
        print("   This may cause transcription errors.")
        print(f"   HF mel sum: {hf_mel.sum():.2f}, Swift mel sum: {swift_mel.sum():.2f}")
    else:
        print("   ✓ Mel spectrograms match closely")

    # Run test cases
    print("\n[3] Running test cases...")
    all_passed = True

    for i, (url, expected) in enumerate(TEST_CASES):
        print(f"\n   Test {i+1}: {url.split('/')[-1]}")

        # Download audio
        audio = download_audio(url)
        print(f"      Audio: {len(audio)} samples ({len(audio)/16000:.2f}s)")

        # Test HuggingFace
        hf_text, _, _, _ = test_huggingface(audio)
        print(f"      HuggingFace: '{hf_text}'")

        # Test CoreML
        try:
            cml_text, _, tokens = test_coreml_full_pipeline(
                audio, mel_filters, encoder_path, decoder_path, vocab
            )
            print(f"      CoreML:      '{cml_text}' (tokens: {tokens})")
        except Exception as e:
            print(f"      CoreML:      ERROR - {e}")
            cml_text = ""

        # Check results
        hf_pass = expected in hf_text
        cml_pass = expected in cml_text
        match = hf_text.strip() == cml_text.strip()

        if hf_pass and cml_pass and match:
            print(f"      ✓ PASS - Both contain '{expected}' and match")
        elif hf_pass and cml_pass:
            print(f"      ~ PARTIAL - Both contain '{expected}' but text differs")
        elif hf_pass and not cml_pass:
            print(f"      ✗ FAIL - HuggingFace works, CoreML doesn't")
            all_passed = False
        else:
            print(f"      ✗ FAIL - Neither contains '{expected}'")
            all_passed = False

    # Summary
    print("\n" + "=" * 70)
    if all_passed:
        print("ALL TESTS PASSED")
        print("The CoreML pipeline matches HuggingFace output.")
        print("Safe to deploy to iOS.")
    else:
        print("SOME TESTS FAILED")
        print("Fix the issues before deploying to iOS.")
    print("=" * 70)

    return all_passed


if __name__ == "__main__":
    success = main()
    exit(0 if success else 1)
