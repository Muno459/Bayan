#!/usr/bin/env python3
"""
Test the pipeline with REAL Quran audio from the CDN.
This verifies the model works with actual recitation.
"""

import torch
import numpy as np
import subprocess
import tempfile
import os
from transformers import WhisperProcessor, WhisperForConditionalGeneration, WhisperFeatureExtractor

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"
CDN_BASE = "https://audio.qurancdn.com/wbw"

# Test words with their expected Arabic text
TEST_WORDS = [
    # Al-Fatiha (Surah 1)
    ("001_001_001", "بِسْمِ"),       # bismillah - "In the name"
    ("001_001_002", "اللَّهِ"),      # Allah
    ("001_001_003", "الرَّحْمَٰنِ"),  # Ar-Rahman
    ("001_001_004", "الرَّحِيمِ"),   # Ar-Raheem
    ("001_002_001", "الْحَمْدُ"),    # Al-hamdu - "Praise"
    ("001_002_002", "لِلَّهِ"),      # lillahi - "to Allah"

    # Al-Baqarah (Surah 2) - some common words
    ("002_001_001", "الم"),          # Alif Lam Meem
    ("002_002_001", "ذَٰلِكَ"),      # Dhalika - "That"
    ("002_002_002", "الْكِتَابُ"),   # Al-kitab - "The Book"
    ("002_002_003", "لَا"),          # La - "No" (THE WORD USER IS TESTING!)
    ("002_002_004", "رَيْبَ"),       # Rayba - "doubt"
]


def download_audio(word_id: str) -> str:
    """Download audio from CDN and return local path."""
    url = f"{CDN_BASE}/{word_id}.mp3"
    temp_path = tempfile.mktemp(suffix=".mp3")

    result = subprocess.run(
        ["curl", "-sL", "-o", temp_path, url],
        capture_output=True
    )

    if result.returncode != 0 or not os.path.exists(temp_path):
        raise Exception(f"Failed to download {url}")

    return temp_path


def load_audio(path: str, sr: int = 16000) -> np.ndarray:
    """Load audio file and convert to 16kHz mono."""
    wav_path = tempfile.mktemp(suffix=".wav")

    # Convert to WAV using ffmpeg
    subprocess.run([
        "ffmpeg", "-y", "-i", path,
        "-ar", str(sr), "-ac", "1", "-f", "wav", wav_path
    ], capture_output=True)

    # Read WAV
    import wave
    with wave.open(wav_path, 'rb') as wav:
        frames = wav.readframes(wav.getnframes())
        audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    os.unlink(wav_path)
    return audio


def test_with_real_audio():
    print("=" * 70)
    print("TESTING WITH REAL QURAN AUDIO FROM CDN")
    print("=" * 70)

    print("\nLoading model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    fe = WhisperFeatureExtractor()

    # Our mel extractor (matching the CoreML export)
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

    our_mel = OurMelExtractor()
    our_mel.eval()

    forced = processor.get_decoder_prompt_ids(language="ar", task="transcribe")

    print("\nDownloading and testing words...")
    print("-" * 70)

    correct = 0
    total = 0

    for word_id, expected in TEST_WORDS:
        try:
            # Download
            mp3_path = download_audio(word_id)

            # Load audio
            audio = load_audio(mp3_path)
            os.unlink(mp3_path)

            duration = len(audio) / 16000
            max_amp = np.abs(audio).max()

            # Pad to 30s
            audio_padded = np.pad(audio, (0, 480000 - len(audio)))
            audio_tensor = torch.tensor(audio_padded).unsqueeze(0)

            # Test with OFFICIAL mel extractor
            official_inputs = processor(audio, sampling_rate=16000, return_tensors="pt")
            with torch.no_grad():
                official_gen = model.generate(
                    official_inputs["input_features"],
                    forced_decoder_ids=forced,
                    max_new_tokens=10,
                )
                official_text = processor.decode(official_gen[0], skip_special_tokens=True)

            # Test with OUR mel extractor
            with torch.no_grad():
                our_mel_output = our_mel(audio_tensor)[:, :, :3000]
                our_gen = model.generate(
                    our_mel_output,
                    forced_decoder_ids=forced,
                    max_new_tokens=10,
                )
                our_text = processor.decode(our_gen[0], skip_special_tokens=True)

            # Check if expected word is in transcription
            # Strip diacritics for comparison
            def strip_diacritics(s):
                return ''.join(c for c in s if not (0x064B <= ord(c) <= 0x065F))

            expected_clean = strip_diacritics(expected)
            official_clean = strip_diacritics(official_text)
            our_clean = strip_diacritics(our_text)

            official_match = expected_clean in official_clean or official_clean in expected_clean
            our_match = expected_clean in our_clean or our_clean in expected_clean

            status = "✓" if our_match else "✗"
            match_status = "MATCH" if our_match else "MISS"

            if our_match:
                correct += 1
            total += 1

            print(f"{status} {word_id} | Expected: {expected:15} | Official: {official_text:15} | Ours: {our_text:15} | {match_status}")

            if official_text != our_text:
                print(f"  ⚠️  Official vs Ours DIFFER!")

        except Exception as e:
            print(f"✗ {word_id} | ERROR: {e}")

    print("-" * 70)
    print(f"\nResults: {correct}/{total} correct ({100*correct/total:.0f}%)")

    if correct == total:
        print("\n✓ ALL WORDS RECOGNIZED CORRECTLY!")
        print("The pipeline works perfectly with real Quran audio.")
    elif correct > total * 0.7:
        print("\n⚠️ Most words recognized. Some failures may be due to short audio or model limitations.")
    else:
        print("\n✗ Many failures. There may be an issue with the pipeline.")


if __name__ == "__main__":
    test_with_real_audio()
