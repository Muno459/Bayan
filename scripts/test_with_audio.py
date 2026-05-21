#!/usr/bin/env python3
"""
Test Whisper model with actual audio files.
"""

import torch
import numpy as np
from pathlib import Path
import sys

# Add the parent to path so we can import test_model
sys.path.insert(0, str(Path(__file__).parent))
from test_model import Encoder, Decoder, load_weights, load_vocab, transcribe

def load_audio(path, sr=16000):
    """Load audio file and resample to 16kHz."""
    import subprocess
    import tempfile

    # Use ffmpeg to convert to raw PCM
    with tempfile.NamedTemporaryFile(suffix='.wav') as f:
        subprocess.run([
            'ffmpeg', '-y', '-i', str(path),
            '-ar', str(sr), '-ac', '1', '-f', 'wav', f.name
        ], capture_output=True)

        import wave
        with wave.open(f.name, 'rb') as wav:
            frames = wav.readframes(wav.getnframes())
            audio = np.frombuffer(frames, dtype=np.int16).astype(np.float32) / 32768.0

    return audio

def compute_mel(audio, sr=16000, n_mels=80, n_fft=400, hop_length=160):
    """Compute log-mel spectrogram like Whisper."""
    # Pad or trim to 30 seconds
    target_length = sr * 30
    if len(audio) > target_length:
        audio = audio[:target_length]
    else:
        audio = np.pad(audio, (0, target_length - len(audio)))

    # Compute STFT
    window = np.hanning(n_fft)
    stft = np.array([
        np.fft.rfft(window * audio[i:i+n_fft])
        for i in range(0, len(audio) - n_fft + 1, hop_length)
    ])
    magnitudes = np.abs(stft) ** 2

    # Mel filterbank
    from huggingface_hub import hf_hub_download
    import json

    # Use transformers mel filters
    try:
        from transformers.models.whisper.feature_extraction_whisper import WhisperFeatureExtractor
        fe = WhisperFeatureExtractor()
        mel_filters = fe.mel_filters
    except:
        # Fallback: compute mel filters manually
        mel_filters = librosa_mel(sr, n_fft, n_mels)

    mel_spec = np.dot(mel_filters, magnitudes.T)

    # Log scale with clipping
    log_mel = np.log10(np.maximum(mel_spec, 1e-10))
    log_mel = np.maximum(log_mel, log_mel.max() - 8.0)
    log_mel = (log_mel + 4.0) / 4.0

    return torch.tensor(log_mel, dtype=torch.float32).unsqueeze(0)

def librosa_mel(sr, n_fft, n_mels, fmin=0, fmax=8000):
    """Create mel filterbank (simplified, for fallback)."""
    # Linear to mel
    def hz_to_mel(hz):
        return 2595.0 * np.log10(1.0 + hz / 700.0)
    def mel_to_hz(mel):
        return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)

    mel_min = hz_to_mel(fmin)
    mel_max = hz_to_mel(fmax)
    mel_points = np.linspace(mel_min, mel_max, n_mels + 2)
    hz_points = mel_to_hz(mel_points)

    bin_points = np.floor((n_fft + 1) * hz_points / sr).astype(int)

    filters = np.zeros((n_mels, n_fft // 2 + 1))
    for i in range(n_mels):
        for j in range(bin_points[i], bin_points[i + 1]):
            filters[i, j] = (j - bin_points[i]) / (bin_points[i + 1] - bin_points[i])
        for j in range(bin_points[i + 1], bin_points[i + 2]):
            filters[i, j] = (bin_points[i + 2] - j) / (bin_points[i + 2] - bin_points[i + 1])

    return filters

def test_with_transformers():
    """Test using HuggingFace transformers pipeline."""
    print("=== Testing with HuggingFace Transformers ===")

    from transformers import WhisperProcessor, WhisperForConditionalGeneration

    MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Find audio files
    audio_dir = Path("Bayan/Resources/Data/audio")
    if not audio_dir.exists():
        print(f"Audio directory not found: {audio_dir}")
        return

    audio_files = list(audio_dir.glob("*.m4a")) + list(audio_dir.glob("*.mp3"))
    print(f"Found {len(audio_files)} audio files")

    for audio_file in audio_files[:5]:  # Test first 5
        print(f"\nFile: {audio_file.name}")

        try:
            audio = load_audio(audio_file)
            print(f"  Audio length: {len(audio)/16000:.2f}s, max: {np.abs(audio).max():.3f}")

            # Process with HuggingFace
            inputs = processor(audio, sampling_rate=16000, return_tensors="pt")

            with torch.no_grad():
                # Use forced_decoder_ids for language
                forced_decoder_ids = processor.get_decoder_prompt_ids(language="ar", task="transcribe")
                generated = model.generate(
                    inputs["input_features"],
                    forced_decoder_ids=forced_decoder_ids,
                    max_new_tokens=20,
                )
                text = processor.decode(generated[0], skip_special_tokens=True)
                print(f"  Transcription: '{text}'")
        except Exception as e:
            print(f"  Error: {e}")

def test_with_custom_model():
    """Test using our custom model implementation."""
    print("\n=== Testing with Custom Model ===")

    encoder = Encoder()
    decoder = Decoder()
    load_weights(encoder, decoder)
    encoder.eval()
    decoder.eval()

    vocab, reverse_vocab = load_vocab()

    # Find audio files
    audio_dir = Path("Bayan/Resources/Data/audio")
    if not audio_dir.exists():
        print(f"Audio directory not found: {audio_dir}")
        return

    audio_files = list(audio_dir.glob("*.m4a")) + list(audio_dir.glob("*.mp3"))

    for audio_file in audio_files[:5]:
        print(f"\nFile: {audio_file.name}")

        try:
            audio = load_audio(audio_file)
            print(f"  Audio length: {len(audio)/16000:.2f}s, max: {np.abs(audio).max():.3f}")

            mel = compute_mel(audio)
            print(f"  Mel shape: {mel.shape}")

            text = transcribe(encoder, decoder, mel, reverse_vocab, max_tokens=10)
            print(f"  Transcription: '{text}'")
        except Exception as e:
            print(f"  Error: {e}")

if __name__ == "__main__":
    # First test with transformers (ground truth)
    test_with_transformers()

    # Then test with custom model
    test_with_custom_model()
