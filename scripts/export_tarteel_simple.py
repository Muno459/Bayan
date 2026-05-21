#!/usr/bin/env python3
"""
Export Tarteel Whisper with FIXED input size decoder.

Simple approach:
- Decoder takes fixed-size input (padded to MAX_SEQ_LEN)
- Use attention mask to handle variable actual length
- No KV-cache complexity
- Works on iOS 17+

This avoids dynamic shapes entirely.
"""

import torch
import torch.nn as nn
import numpy as np
import coremltools as ct
from transformers import WhisperForConditionalGeneration, WhisperProcessor
import subprocess
import tempfile
import wave
import os
import shutil
import json

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"
OUTPUT_DIR = "Bayan/Resources/Data"

MAX_SEQ_LEN = 24  # Fixed decoder input size


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


class FixedSizeDecoder(nn.Module):
    """
    Whisper decoder with fixed input size.

    Takes input_ids of fixed length (padded with pad_token).
    Uses the decoder's built-in causal attention masking.
    Returns logits for all positions.
    """

    def __init__(self, whisper_model):
        super().__init__()
        self.decoder = whisper_model.model.decoder
        self.proj_out = whisper_model.proj_out

    def forward(self, input_ids: torch.Tensor, encoder_output: torch.Tensor) -> torch.Tensor:
        """
        Args:
            input_ids: (1, MAX_SEQ_LEN) - padded token IDs
            encoder_output: (1, 1500, 384) - encoder hidden states

        Returns:
            logits: (1, MAX_SEQ_LEN, vocab_size)
        """
        # The decoder already handles causal masking internally
        # We just need to run it with the padded input
        decoder_output = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_output,
            use_cache=False,
            return_dict=False
        )
        # decoder_output is a tuple, first element is hidden states
        hidden = decoder_output[0]
        logits = self.proj_out(hidden)
        return logits


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("=" * 60)
    print("TARTEEL WHISPER FIXED-SIZE EXPORT")
    print("=" * 60)

    # Load model
    print("\n[1/7] Loading HuggingFace model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Get pad token (use EOT as pad)
    pad_token = 50257  # EOT

    # Verify HuggingFace works
    print("\n[2/7] Testing HuggingFace model...")
    audio = download_test_audio()
    mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

    sot, eot = 50258, 50257
    lang, task, no_ts = 50272, 50359, 50363
    prompt = [sot, lang, task, no_ts]

    tokens = prompt.copy()
    with torch.no_grad():
        enc = model.model.encoder(mel).last_hidden_state
        for _ in range(20):
            ids = torch.tensor([tokens], dtype=torch.long)
            dec = model.model.decoder(input_ids=ids, encoder_hidden_states=enc, use_cache=False)
            logits = model.proj_out(dec.last_hidden_state)
            next_tok = int(torch.argmax(logits[0, -1, :50364]))
            if next_tok == eot:
                break
            tokens.append(next_tok)

    text = processor.decode(tokens[4:], skip_special_tokens=True)
    print(f"   HuggingFace: '{text}'")

    # Test fixed-size decoder
    print("\n[3/7] Testing fixed-size decoder in PyTorch...")
    fixed_decoder = FixedSizeDecoder(model)
    fixed_decoder.eval()

    # Pad tokens to MAX_SEQ_LEN
    padded_tokens = prompt + [pad_token] * (MAX_SEQ_LEN - len(prompt))
    actual_len = len(prompt)

    fixed_tokens = prompt.copy()
    with torch.no_grad():
        for step in range(20):
            # Pad current tokens
            padded = fixed_tokens + [pad_token] * (MAX_SEQ_LEN - len(fixed_tokens))
            ids = torch.tensor([padded], dtype=torch.long)

            logits = fixed_decoder(ids, enc)

            # Get next token from the last ACTUAL position (not padded position)
            pos = len(fixed_tokens) - 1
            next_tok = int(torch.argmax(logits[0, pos, :50364]))

            if next_tok == eot:
                break
            fixed_tokens.append(next_tok)

    fixed_text = processor.decode(fixed_tokens[4:], skip_special_tokens=True)
    print(f"   Fixed-size decoder: '{fixed_text}'")

    if fixed_text == text:
        print("   ✓ Fixed-size decoder matches original!")
    else:
        print(f"   ✗ WARNING: Output differs!")
        print(f"      Original: '{text}'")
        print(f"      Fixed:    '{fixed_text}'")

    # Export encoder
    print("\n[4/7] Exporting encoder...")

    class EncoderWrapper(nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(self, mel):
            return self.encoder(mel).last_hidden_state

    encoder_wrapper = EncoderWrapper(model.model.encoder)
    encoder_wrapper.eval()

    traced_encoder = torch.jit.trace(encoder_wrapper, torch.randn(1, 80, 3000))

    encoder_coreml = ct.convert(
        traced_encoder,
        inputs=[ct.TensorType(name="mel", shape=(1, 80, 3000), dtype=np.float32)],
        outputs=[ct.TensorType(name="encoder_output", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    encoder_path = f"{OUTPUT_DIR}/TarteelEncoder.mlpackage"
    encoder_coreml.save(encoder_path)
    print(f"   ✓ Saved {encoder_path}")

    # Export fixed-size decoder
    print("\n[5/7] Exporting fixed-size decoder...")

    # Trace with fixed-size inputs
    example_ids = torch.tensor([padded_tokens], dtype=torch.long)
    example_enc = torch.randn(1, 1500, 384)

    with torch.no_grad():
        traced_decoder = torch.jit.trace(fixed_decoder, (example_ids, example_enc))

    decoder_coreml = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="encoder_output", shape=(1, 1500, 384), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    decoder_path = f"{OUTPUT_DIR}/TarteelDecoder.mlpackage"
    decoder_coreml.save(decoder_path)
    print(f"   ✓ Saved {decoder_path}")

    # Verify CoreML
    print("\n[6/7] Verifying CoreML models...")

    # Test encoder
    mel_np = mel.numpy()
    enc_cml = encoder_coreml.predict({"mel": mel_np})["encoder_output"]

    with torch.no_grad():
        enc_pt = model.model.encoder(mel).last_hidden_state.numpy()
    enc_diff = np.abs(enc_cml - enc_pt).mean()
    print(f"   Encoder diff: {enc_diff:.6f}")

    # Test decoder
    padded = prompt + [pad_token] * (MAX_SEQ_LEN - len(prompt))
    ids_np = np.array([padded], dtype=np.int32)

    dec_cml = decoder_coreml.predict({"input_ids": ids_np, "encoder_output": enc_cml})["logits"]

    with torch.no_grad():
        dec_pt = fixed_decoder(
            torch.tensor([padded], dtype=torch.long),
            torch.tensor(enc_pt)
        ).numpy()

    dec_diff = np.abs(dec_cml - dec_pt).mean()
    print(f"   Decoder diff: {dec_diff:.6f}")

    # Check first generated token
    token_cml = int(np.argmax(dec_cml[0, len(prompt)-1, :50364]))
    token_pt = int(np.argmax(dec_pt[0, len(prompt)-1, :50364]))
    print(f"   First token - CoreML: {token_cml}, PyTorch: {token_pt}")

    if token_cml == token_pt:
        print("   ✓ CoreML matches PyTorch!")
    else:
        print("   ✗ WARNING: Tokens differ!")

    # Save resources
    print("\n[7/7] Saving resources and compiling...")

    # Mel filters
    from transformers import WhisperFeatureExtractor
    fe = WhisperFeatureExtractor()
    mel_filters = fe.mel_filters.T.astype(np.float32)
    mel_filters.tofile(f"{OUTPUT_DIR}/mel_filters.bin")

    # Vocab
    vocab = processor.tokenizer.get_vocab()
    with open(f"{OUTPUT_DIR}/tarteel_vocab.json", "w") as f:
        json.dump(vocab, f, ensure_ascii=False)

    # Compile for iOS
    for name in ["TarteelEncoder", "TarteelDecoder"]:
        pkg_path = f"{OUTPUT_DIR}/{name}.mlpackage"
        compiled_path = f"{OUTPUT_DIR}/{name}.mlmodelc"
        if os.path.exists(compiled_path):
            shutil.rmtree(compiled_path)
        result = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", pkg_path, OUTPUT_DIR],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"   ✗ Failed to compile {name}: {result.stderr}")
        else:
            shutil.rmtree(pkg_path)
            print(f"   ✓ Compiled {compiled_path}")

    print("\n" + "=" * 60)
    print("EXPORT COMPLETE")
    print(f"Decoder uses fixed input size: {MAX_SEQ_LEN}")
    print("Works on iOS 17+")
    print("=" * 60)


if __name__ == "__main__":
    main()
