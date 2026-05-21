#!/usr/bin/env python3
"""
Local CoreML test - exports models to mlpackage format for testing.
This tests the exact same inference path as iOS.
"""

import numpy as np
import subprocess
import tempfile
import wave
import os
import json
import torch
from transformers import WhisperForConditionalGeneration, WhisperProcessor
import coremltools as ct

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"


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
    """Compute mel spectrogram exactly as Swift does."""
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
    audio_padded[:pad] = padded[1:pad+1][::-1]
    audio_padded[pad:pad+len(padded)] = padded
    audio_padded[pad+len(padded):] = padded[-2:-pad-2:-1]

    # Hann window
    window = np.hanning(n_fft).astype(np.float32)

    # STFT
    num_frames = (len(audio_padded) - n_fft) // hop_length + 1
    fft_size = n_fft // 2 + 1

    magnitudes = np.zeros((num_frames, fft_size), dtype=np.float32)

    for f in range(num_frames):
        start = f * hop_length
        frame = audio_padded[start:start + n_fft] * window
        fft_result = np.fft.rfft(frame)
        magnitudes[f] = np.abs(fft_result) ** 2

    mel_spec = mel_filters @ magnitudes.T
    log_mel = np.log10(np.maximum(mel_spec[:, :n_frames], 1e-10))
    max_val = log_mel.max()
    log_mel = np.maximum(log_mel, max_val - 8.0)
    log_mel = (log_mel + 4.0) / 4.0

    return log_mel.astype(np.float32)


def build_byte_decoder():
    """Build GPT-2 byte decoder."""
    bs = list(range(ord("!"), ord("~")+1)) + list(range(0xA1, 0xAD)) + list(range(0xAE, 0x100))
    cs = bs[:]
    n = 0
    for b in range(256):
        if b not in bs:
            bs.append(b)
            cs.append(256 + n)
            n += 1
    return {chr(c): b for b, c in zip(bs, cs)}


def decode_tokens(tokens, vocab, byte_decoder):
    """Decode tokens to text."""
    byte_list = []
    for token in tokens:
        if token in vocab:
            word = vocab[token]
            if word.startswith("<|") and word.endswith("|>"):
                continue
            for char in word:
                if char in byte_decoder:
                    byte_list.append(byte_decoder[char])
    return bytes(byte_list).decode("utf-8", errors="replace").strip()


def main():
    print("=" * 70)
    print("LOCAL COREML TEST")
    print("=" * 70)

    # Load mel filters
    mel_filters_path = "Bayan/Resources/Data/mel_filters.bin"
    mel_filters = np.fromfile(mel_filters_path, dtype=np.float32).reshape(80, 201)

    # Load vocab
    vocab_path = "Bayan/Resources/Data/tarteel_vocab.json"
    with open(vocab_path) as f:
        vocab_str = json.load(f)
    vocab = {v: k for k, v in vocab_str.items()}
    byte_decoder = build_byte_decoder()

    # Load HuggingFace model
    print("\n[1] Loading HuggingFace model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Export to CoreML mlpackage (not compiled - can run on any Mac)
    print("\n[2] Exporting to CoreML mlpackage...")

    # Encoder
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

    encoder_cml = ct.convert(
        traced_encoder,
        inputs=[ct.TensorType(name="mel", shape=(1, 80, 3000), dtype=np.float32)],
        outputs=[ct.TensorType(name="encoder_output", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    print("   ✓ Encoder exported")

    # Decoder
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

    decoder_cml = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="input_ids", shape=ct.Shape((1, ct.RangeDim(1, 448))), dtype=np.int32),
            ct.TensorType(name="encoder_output", shape=(1, 1500, 384), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    print("   ✓ Decoder exported")

    # Test cases
    test_cases = [
        ("https://audio.qurancdn.com/wbw/002_002_003.mp3", "لا"),
        ("https://audio.qurancdn.com/wbw/001_001_001.mp3", "بسم"),
        ("https://audio.qurancdn.com/wbw/001_001_002.mp3", "الله"),
    ]

    print("\n[3] Running tests...")
    all_passed = True

    for url, expected in test_cases:
        print(f"\n   Testing: {url.split('/')[-1]} (expect '{expected}')")

        # Download audio
        audio = download_audio(url)
        print(f"      Audio: {len(audio)} samples ({len(audio)/16000:.2f}s)")

        # ---- HuggingFace ----
        mel_hf = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

        sot, eot = 50258, 50257
        lang, task, no_ts = 50272, 50359, 50363
        tokens_hf = [sot, lang, task, no_ts]

        with torch.no_grad():
            enc_hf = model.model.encoder(mel_hf).last_hidden_state
            for _ in range(20):
                input_ids = torch.tensor([tokens_hf], dtype=torch.long)
                dec_out = model.model.decoder(input_ids=input_ids, encoder_hidden_states=enc_hf, use_cache=False)
                logits = model.proj_out(dec_out.last_hidden_state)
                next_tok = int(torch.argmax(logits[0, -1, :50364]))
                if next_tok == eot:
                    break
                tokens_hf.append(next_tok)

        text_hf = processor.decode(tokens_hf[4:], skip_special_tokens=True)
        print(f"      HuggingFace: '{text_hf}'")

        # ---- CoreML (Swift-style mel) ----
        mel_swift = compute_mel_swift_style(audio, mel_filters)
        mel_input = mel_swift.reshape(1, 80, 3000)

        enc_cml = encoder_cml.predict({"mel": mel_input})["encoder_output"]

        tokens_cml = [sot, lang, task, no_ts]
        for _ in range(20):
            input_ids = np.array([tokens_cml], dtype=np.int32)
            logits = decoder_cml.predict({"input_ids": input_ids, "encoder_output": enc_cml})["logits"]
            next_tok = int(np.argmax(logits[0, -1, :50364]))
            if next_tok == eot:
                break
            tokens_cml.append(next_tok)

        text_cml = decode_tokens(tokens_cml[4:], vocab, byte_decoder)
        print(f"      CoreML:      '{text_cml}' (tokens: {tokens_cml[4:]})")

        # ---- Compare ----
        # Also test CoreML with HF mel to isolate mel vs model issues
        enc_cml_hf_mel = encoder_cml.predict({"mel": mel_hf.numpy()})["encoder_output"]
        tokens_cml_hf_mel = [sot, lang, task, no_ts]
        for _ in range(20):
            input_ids = np.array([tokens_cml_hf_mel], dtype=np.int32)
            logits = decoder_cml.predict({"input_ids": input_ids, "encoder_output": enc_cml_hf_mel})["logits"]
            next_tok = int(np.argmax(logits[0, -1, :50364]))
            if next_tok == eot:
                break
            tokens_cml_hf_mel.append(next_tok)
        text_cml_hf_mel = decode_tokens(tokens_cml_hf_mel[4:], vocab, byte_decoder)
        print(f"      CoreML+HFmel: '{text_cml_hf_mel}'")

        # Check
        hf_ok = expected in text_hf
        cml_ok = expected in text_cml
        cml_hf_mel_ok = expected in text_cml_hf_mel

        if hf_ok and cml_ok:
            print(f"      ✓ PASS - Both contain '{expected}'")
        elif hf_ok and cml_hf_mel_ok and not cml_ok:
            print(f"      ~ MEL ISSUE - CoreML works with HF mel, but not Swift mel")
            all_passed = False
        elif hf_ok and not cml_hf_mel_ok:
            print(f"      ✗ FAIL - CoreML model differs from HuggingFace")
            all_passed = False
        else:
            print(f"      ✗ FAIL - Neither works")
            all_passed = False

    print("\n" + "=" * 70)
    if all_passed:
        print("ALL TESTS PASSED - Safe to deploy to iOS")
    else:
        print("SOME TESTS FAILED - Fix before deploying")
    print("=" * 70)

    return all_passed


if __name__ == "__main__":
    exit(0 if main() else 1)
