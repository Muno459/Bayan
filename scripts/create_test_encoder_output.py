#!/usr/bin/env python3
"""
Create a fixed encoder output that produces "لَا" and save it.
This can be loaded in iOS to verify the CoreML decoder.
"""

import torch
import numpy as np
import subprocess
import tempfile
import os
from transformers import WhisperForConditionalGeneration, WhisperProcessor, WhisperFeatureExtractor

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

# Download CDN audio
url = "https://audio.qurancdn.com/wbw/002_002_003.mp3"
mp3_path = tempfile.mktemp(suffix=".mp3")
wav_path = tempfile.mktemp(suffix=".wav")

subprocess.run(["curl", "-sL", "-o", mp3_path, url], capture_output=True)
subprocess.run(["ffmpeg", "-y", "-i", mp3_path, "-ar", "16000", "-ac", "1", "-f", "wav", wav_path], capture_output=True)

import wave
with wave.open(wav_path, "rb") as wav:
    frames = wav.readframes(wav.getnframes())
    audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

os.unlink(mp3_path)
os.unlink(wav_path)

print(f"Audio: {len(audio)} samples, max={np.abs(audio).max():.3f}")

# Load model
processor = WhisperProcessor.from_pretrained(MODEL_NAME)
model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
model.eval()

fe = WhisperFeatureExtractor()

# Our mel extractor
class OurMelExtractor(torch.nn.Module):
    def __init__(self):
        super().__init__()
        self.n_fft = 400
        self.hop_length = 160
        self.register_buffer("mel_filters", torch.tensor(fe.mel_filters.T, dtype=torch.float32))

    def forward(self, audio):
        pad = self.n_fft // 2
        audio_padded = torch.nn.functional.pad(audio, (pad, pad), mode="reflect")
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

mel_extractor = OurMelExtractor()
mel_extractor.eval()

# Process audio
audio_padded = np.pad(audio, (0, 480000 - len(audio)))
audio_tensor = torch.tensor(audio_padded).unsqueeze(0)

with torch.no_grad():
    mel = mel_extractor(audio_tensor)[:, :, :3000]
    mel_f16 = mel.half()  # Convert to Float16 like CoreML

    print(f"Mel shape: {mel_f16.shape}")
    print(f"Mel (F16) first 10 values: {mel_f16.flatten()[:10].float().tolist()}")
    print(f"Mel (F16) sum (first 1000): {mel_f16.flatten()[:1000].float().sum().item():.2f}")

    # Run encoder
    enc_out = model.model.encoder(mel_f16.float())[0]
    enc_f16 = enc_out.half()

    print(f"Encoder shape: {enc_f16.shape}")
    print(f"Encoder (F16) first 10 values: {enc_f16.flatten()[:10].float().tolist()}")
    print(f"Encoder (F16) sum (first 1000): {enc_f16.flatten()[:1000].float().sum().item():.2f}")
    print(f"Encoder[0,0,0]: {enc_f16[0,0,0].float().item():.6f}")

    # Run decoder
    SOT, LANG, TASK, NOTIMESTAMPS = 50258, 50272, 50359, 50363
    prompt = torch.tensor([[SOT, LANG, TASK, NOTIMESTAMPS]])

    dec_out = model.model.decoder(input_ids=prompt, encoder_hidden_states=enc_f16.float(), use_cache=False)
    logits = model.proj_out(dec_out.last_hidden_state)

    print()
    print("Decoder output:")
    for step in range(8):
        if step > 0:
            prompt = torch.tensor([tokens])
            dec_out = model.model.decoder(input_ids=prompt, encoder_hidden_states=enc_f16.float(), use_cache=False)
            logits = model.proj_out(dec_out.last_hidden_state)

        next_token = logits[0, -1, :51865].argmax().item()
        next_logit = logits[0, -1, next_token].item()
        print(f"  Step {step}: token={next_token}, logit={next_logit:.2f}")

        if step == 0:
            tokens = [SOT, LANG, TASK, NOTIMESTAMPS, next_token]
        else:
            if next_token == 50257:
                break
            tokens.append(next_token)

    # Full transcription
    forced = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
    gen = model.generate(mel_f16.float(), forced_decoder_ids=forced, max_new_tokens=10)
    text = processor.decode(gen[0], skip_special_tokens=True)
    print(f"\nFull transcription: '{text}'")

    # Save the encoder output for iOS testing
    # Save as raw Float16 binary
    enc_np = enc_f16.numpy().flatten().astype(np.float16)
    enc_np.tofile("test_encoder_output.bin")
    print(f"\nSaved encoder output to test_encoder_output.bin ({enc_np.nbytes} bytes)")
    print("Load this in iOS and run decoder to verify it produces 'لَا'")
