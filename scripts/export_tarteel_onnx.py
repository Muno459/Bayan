#!/usr/bin/env python3
"""
Export Tarteel Whisper via ONNX to CoreML.

ONNX often handles dynamic operations better than direct tracing.
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

MAX_SEQ_LEN = 24


def download_test_audio():
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


class EncoderWrapper(nn.Module):
    def __init__(self, encoder):
        super().__init__()
        self.encoder = encoder

    def forward(self, mel):
        return self.encoder(mel).last_hidden_state


class DecoderWrapper(nn.Module):
    """Wrapper that takes fixed-size input and returns logits."""
    def __init__(self, decoder, proj_out):
        super().__init__()
        self.decoder = decoder
        self.proj_out = proj_out

    def forward(self, input_ids, encoder_output):
        # Use the decoder directly without cache
        hidden = self.decoder(
            input_ids=input_ids,
            encoder_hidden_states=encoder_output,
            use_cache=False,
            return_dict=False
        )[0]
        return self.proj_out(hidden)


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("=" * 60)
    print("TARTEEL WHISPER ONNX->COREML EXPORT")
    print("=" * 60)

    # Load model
    print("\n[1/8] Loading HuggingFace model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    pad_token = 50257
    sot, eot = 50258, 50257
    lang, task, no_ts = 50272, 50359, 50363
    prompt = [sot, lang, task, no_ts]

    # Test HuggingFace
    print("\n[2/8] Testing HuggingFace model...")
    audio = download_test_audio()
    mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

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

    # Export encoder to ONNX
    print("\n[3/8] Exporting encoder to ONNX...")
    encoder_wrapper = EncoderWrapper(model.model.encoder)
    encoder_wrapper.eval()

    encoder_onnx_path = f"{OUTPUT_DIR}/TarteelEncoder.onnx"
    dummy_mel = torch.randn(1, 80, 3000)

    torch.onnx.export(
        encoder_wrapper,
        dummy_mel,
        encoder_onnx_path,
        input_names=["mel"],
        output_names=["encoder_output"],
        opset_version=17,
        dynamic_axes=None,  # Fixed shapes
    )
    print(f"   ✓ Saved {encoder_onnx_path}")

    # Export decoder to ONNX
    print("\n[4/8] Exporting decoder to ONNX...")
    decoder_wrapper = DecoderWrapper(model.model.decoder, model.proj_out)
    decoder_wrapper.eval()

    decoder_onnx_path = f"{OUTPUT_DIR}/TarteelDecoder.onnx"
    dummy_ids = torch.tensor([[sot, lang, task, no_ts] + [pad_token] * (MAX_SEQ_LEN - 4)], dtype=torch.long)
    dummy_enc = torch.randn(1, 1500, 384)

    torch.onnx.export(
        decoder_wrapper,
        (dummy_ids, dummy_enc),
        decoder_onnx_path,
        input_names=["input_ids", "encoder_output"],
        output_names=["logits"],
        opset_version=17,
        dynamic_axes=None,  # Fixed shapes
    )
    print(f"   ✓ Saved {decoder_onnx_path}")

    # Verify ONNX models
    print("\n[5/8] Verifying ONNX models...")
    import onnxruntime as ort

    # Test encoder
    enc_session = ort.InferenceSession(encoder_onnx_path)
    enc_onnx = enc_session.run(None, {"mel": mel.numpy()})[0]

    with torch.no_grad():
        enc_pt = model.model.encoder(mel).last_hidden_state.numpy()
    enc_diff = np.abs(enc_onnx - enc_pt).mean()
    print(f"   Encoder diff: {enc_diff:.6f}")

    # Test decoder
    dec_session = ort.InferenceSession(decoder_onnx_path)
    padded = prompt + [pad_token] * (MAX_SEQ_LEN - len(prompt))
    dec_onnx = dec_session.run(None, {
        "input_ids": np.array([padded], dtype=np.int64),
        "encoder_output": enc_pt
    })[0]

    with torch.no_grad():
        dec_pt = decoder_wrapper(
            torch.tensor([padded], dtype=torch.long),
            torch.tensor(enc_pt)
        ).numpy()

    dec_diff = np.abs(dec_onnx - dec_pt).mean()
    print(f"   Decoder diff: {dec_diff:.6f}")

    # Convert ONNX to CoreML
    print("\n[6/8] Converting ONNX to CoreML...")
    from onnx_coreml import convert as onnx_to_coreml
    import onnx

    # Encoder
    encoder_onnx = onnx.load(encoder_onnx_path)
    encoder_coreml = onnx_to_coreml(encoder_onnx, minimum_ios_deployment_target='13')
    encoder_path = f"{OUTPUT_DIR}/TarteelEncoder.mlmodel"
    encoder_coreml.save(encoder_path)
    print(f"   ✓ Encoder -> {encoder_path}")

    # Decoder
    decoder_onnx = onnx.load(decoder_onnx_path)
    decoder_coreml = onnx_to_coreml(decoder_onnx, minimum_ios_deployment_target='13')
    decoder_path = f"{OUTPUT_DIR}/TarteelDecoder.mlmodel"
    decoder_coreml.save(decoder_path)
    print(f"   ✓ Decoder -> {decoder_path}")

    # Verify CoreML
    print("\n[7/8] Verifying CoreML models...")
    print("   (Skipping verification - onnx-coreml produces old-style mlmodel)")

    # Save resources and compile
    print("\n[8/8] Saving resources and compiling...")

    # Mel filters
    from transformers import WhisperFeatureExtractor
    fe = WhisperFeatureExtractor()
    mel_filters = fe.mel_filters.T.astype(np.float32)
    mel_filters.tofile(f"{OUTPUT_DIR}/mel_filters.bin")

    # Vocab
    vocab = processor.tokenizer.get_vocab()
    with open(f"{OUTPUT_DIR}/tarteel_vocab.json", "w") as f:
        json.dump(vocab, f, ensure_ascii=False)

    # Clean up ONNX files
    os.unlink(encoder_onnx_path)
    os.unlink(decoder_onnx_path)

    # Compile for iOS
    for name in ["TarteelEncoder", "TarteelDecoder"]:
        model_path = f"{OUTPUT_DIR}/{name}.mlmodel"
        compiled_path = f"{OUTPUT_DIR}/{name}.mlmodelc"
        if os.path.exists(compiled_path):
            shutil.rmtree(compiled_path)
        result = subprocess.run(
            ["xcrun", "coremlcompiler", "compile", model_path, OUTPUT_DIR],
            capture_output=True, text=True
        )
        if result.returncode != 0:
            print(f"   ✗ Failed to compile {name}: {result.stderr}")
        else:
            os.unlink(model_path)
            print(f"   ✓ Compiled {compiled_path}")

    print("\n" + "=" * 60)
    print("EXPORT COMPLETE")
    print("=" * 60)


if __name__ == "__main__":
    main()
