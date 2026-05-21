#!/usr/bin/env python3
"""
Export Tarteel Whisper with STATEFUL KV-cache decoder.

Uses a simpler approach:
- Fixed-size pre-allocated cache
- Position passed as input
- Attention mask handles variable sequence length

Requires iOS 18+ / macOS 15+ for stateful model support.
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

# Whisper-tiny config
NUM_LAYERS = 4
NUM_HEADS = 6
HEAD_DIM = 64
HIDDEN_DIM = 384
MAX_SEQ_LEN = 32  # Padded to power of 2
ENCODER_SEQ_LEN = 1500


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


class WhisperDecoderWithCache(nn.Module):
    """
    Whisper decoder that takes KV-cache as explicit I/O.

    This approach is simpler and works reliably with tracing.
    Cache is passed in and out rather than stored as state.
    """

    def __init__(self, whisper_model):
        super().__init__()
        self.decoder = whisper_model.model.decoder
        self.proj_out = whisper_model.proj_out

    def forward(
        self,
        input_id: torch.Tensor,          # (1, 1)
        position: torch.Tensor,           # (1,) - current position
        encoder_output: torch.Tensor,     # (1, 1500, 384)
        self_attn_k_cache: torch.Tensor,  # (num_layers, 1, num_heads, max_seq, head_dim)
        self_attn_v_cache: torch.Tensor,  # (num_layers, 1, num_heads, max_seq, head_dim)
        cross_attn_k_cache: torch.Tensor, # (num_layers, 1, num_heads, 1500, head_dim)
        cross_attn_v_cache: torch.Tensor, # (num_layers, 1, num_heads, 1500, head_dim)
    ):
        """
        Single-step decoder with KV-cache.

        Returns:
            logits: (1, 1, vocab_size)
            updated_self_k: (num_layers, 1, num_heads, max_seq, head_dim)
            updated_self_v: (num_layers, 1, num_heads, max_seq, head_dim)
            cross_k: (num_layers, 1, num_heads, 1500, head_dim) - unchanged after first call
            cross_v: (num_layers, 1, num_heads, 1500, head_dim) - unchanged after first call
        """
        batch_size = 1
        pos = position[0]  # Keep as tensor for tracing

        # Token + positional embedding
        hidden = self.decoder.embed_tokens(input_id)
        # Create position tensor for embedding lookup
        pos_tensor = position.unsqueeze(0)  # (1, 1)
        hidden = hidden + self.decoder.embed_positions(pos_tensor, past_key_values_length=0)

        # Clone caches for output (will be updated)
        new_self_k = self_attn_k_cache.clone()
        new_self_v = self_attn_v_cache.clone()
        new_cross_k = cross_attn_k_cache.clone()
        new_cross_v = cross_attn_v_cache.clone()

        # Check if cross-attention needs initialization (first call when position=0)
        # We'll compute it unconditionally and let the Swift side handle caching
        compute_cross_attn = True  # Always compute, Swift caches result

        scale = HEAD_DIM ** -0.5

        for layer_idx, layer in enumerate(self.decoder.layers):
            # === Self-Attention ===
            residual = hidden
            hidden = layer.self_attn_layer_norm(hidden)

            # Compute Q, K, V for current position
            q = layer.self_attn.q_proj(hidden)  # (1, 1, 384)
            k = layer.self_attn.k_proj(hidden)
            v = layer.self_attn.v_proj(hidden)

            # Reshape: (1, 1, 384) -> (1, 6, 1, 64) -> for attention
            q = q.view(batch_size, 1, NUM_HEADS, HEAD_DIM).transpose(1, 2)  # (1, 6, 1, 64)
            k = k.view(batch_size, 1, NUM_HEADS, HEAD_DIM).transpose(1, 2)
            v = v.view(batch_size, 1, NUM_HEADS, HEAD_DIM).transpose(1, 2)

            # Get cached K, V - shape: (1, 6, max_seq, 64)
            cached_k = self_attn_k_cache[layer_idx]  # (1, 6, 32, 64)
            cached_v = self_attn_v_cache[layer_idx]

            # Update cache at current position using scatter
            # This works with tracing since we're using tensor operations
            pos_idx = pos.long()

            # Create index tensor for scatter
            # k shape: (1, 6, 1, 64), cache shape: (1, 6, 32, 64)
            # We want to write k at position pos in dimension 2
            indices = pos_idx.view(1, 1, 1, 1).expand(1, NUM_HEADS, 1, HEAD_DIM)
            new_self_k[layer_idx] = cached_k.scatter(2, indices, k)
            new_self_v[layer_idx] = cached_v.scatter(2, indices, v)

            # For attention, concatenate current K,V with cache up to current position
            # Since we can't do dynamic slicing, we attend to full cache with mask
            full_k = new_self_k[layer_idx]  # (1, 6, 32, 64)
            full_v = new_self_v[layer_idx]

            # Compute attention scores
            attn_weights = torch.matmul(q, full_k.transpose(-2, -1)) * scale  # (1, 6, 1, 32)

            # Create causal mask: only attend to positions <= current
            # Shape: (1, 1, 1, 32)
            positions = torch.arange(MAX_SEQ_LEN, device=input_id.device, dtype=torch.float32)
            mask = (positions <= pos.float()).view(1, 1, 1, MAX_SEQ_LEN)
            attn_weights = attn_weights.masked_fill(~mask, float('-inf'))

            attn_weights = torch.softmax(attn_weights, dim=-1)
            attn_output = torch.matmul(attn_weights, full_v)  # (1, 6, 1, 64)

            attn_output = attn_output.transpose(1, 2).reshape(batch_size, 1, HIDDEN_DIM)
            attn_output = layer.self_attn.out_proj(attn_output)
            hidden = residual + attn_output

            # === Cross-Attention ===
            residual = hidden
            hidden = layer.encoder_attn_layer_norm(hidden)

            # Compute cross-attention K, V from encoder output
            cross_k = layer.encoder_attn.k_proj(encoder_output)  # (1, 1500, 384)
            cross_v = layer.encoder_attn.v_proj(encoder_output)
            cross_k = cross_k.view(batch_size, ENCODER_SEQ_LEN, NUM_HEADS, HEAD_DIM).transpose(1, 2)
            cross_v = cross_v.view(batch_size, ENCODER_SEQ_LEN, NUM_HEADS, HEAD_DIM).transpose(1, 2)

            # Store in output cache
            new_cross_k[layer_idx] = cross_k
            new_cross_v[layer_idx] = cross_v

            # Query for cross-attention
            cross_q = layer.encoder_attn.q_proj(hidden)
            cross_q = cross_q.view(batch_size, 1, NUM_HEADS, HEAD_DIM).transpose(1, 2)

            # Cross-attention (no mask needed - attend to all encoder positions)
            cross_attn_weights = torch.matmul(cross_q, cross_k.transpose(-2, -1)) * scale
            cross_attn_weights = torch.softmax(cross_attn_weights, dim=-1)
            cross_attn_output = torch.matmul(cross_attn_weights, cross_v)

            cross_attn_output = cross_attn_output.transpose(1, 2).reshape(batch_size, 1, HIDDEN_DIM)
            cross_attn_output = layer.encoder_attn.out_proj(cross_attn_output)
            hidden = residual + cross_attn_output

            # === FFN ===
            residual = hidden
            hidden = layer.final_layer_norm(hidden)
            hidden = layer.fc1(hidden)
            hidden = torch.nn.functional.gelu(hidden)
            hidden = layer.fc2(hidden)
            hidden = residual + hidden

        # Final layer norm and projection
        hidden = self.decoder.layer_norm(hidden)
        logits = self.proj_out(hidden)

        return logits, new_self_k, new_self_v, new_cross_k, new_cross_v


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("=" * 60)
    print("TARTEEL WHISPER KV-CACHE EXPORT")
    print("=" * 60)

    # Load model
    print("\n[1/6] Loading HuggingFace model...")
    processor = WhisperProcessor.from_pretrained(MODEL_NAME)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
    model.eval()

    # Verify HuggingFace works
    print("\n[2/6] Testing HuggingFace model...")
    audio = download_test_audio()
    mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

    sot, eot = 50258, 50257
    lang, task, no_ts = 50272, 50359, 50363
    tokens = [sot, lang, task, no_ts]

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

    # Test our KV-cache decoder in PyTorch first
    print("\n[3/6] Testing KV-cache decoder in PyTorch...")
    kv_decoder = WhisperDecoderWithCache(model)
    kv_decoder.eval()

    # Initialize caches
    self_k = torch.zeros(NUM_LAYERS, 1, NUM_HEADS, MAX_SEQ_LEN, HEAD_DIM)
    self_v = torch.zeros(NUM_LAYERS, 1, NUM_HEADS, MAX_SEQ_LEN, HEAD_DIM)
    cross_k = torch.zeros(NUM_LAYERS, 1, NUM_HEADS, ENCODER_SEQ_LEN, HEAD_DIM)
    cross_v = torch.zeros(NUM_LAYERS, 1, NUM_HEADS, ENCODER_SEQ_LEN, HEAD_DIM)

    kv_tokens = [sot, lang, task, no_ts]
    with torch.no_grad():
        for pos, tok in enumerate(kv_tokens):
            input_id = torch.tensor([[tok]], dtype=torch.long)
            position = torch.tensor([pos], dtype=torch.long)
            logits, self_k, self_v, cross_k, cross_v = kv_decoder(
                input_id, position, enc, self_k, self_v, cross_k, cross_v
            )

        # Generate
        for pos in range(len(kv_tokens), MAX_SEQ_LEN):
            next_tok = int(torch.argmax(logits[0, -1, :50364]))
            if next_tok == eot:
                break
            kv_tokens.append(next_tok)

            input_id = torch.tensor([[next_tok]], dtype=torch.long)
            position = torch.tensor([pos], dtype=torch.long)
            logits, self_k, self_v, cross_k, cross_v = kv_decoder(
                input_id, position, enc, self_k, self_v, cross_k, cross_v
            )

    kv_text = processor.decode(kv_tokens[4:], skip_special_tokens=True)
    print(f"   KV-cache decoder: '{kv_text}'")

    if kv_text == text:
        print("   ✓ KV-cache matches original!")
    else:
        print("   ✗ WARNING: KV-cache output differs!")

    # Export encoder
    print("\n[4/6] Exporting encoder...")

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

    # Export decoder with KV-cache
    print("\n[5/6] Exporting decoder with KV-cache...")

    # Trace
    example_inputs = (
        torch.tensor([[50258]], dtype=torch.long),  # input_id
        torch.tensor([0], dtype=torch.long),         # position
        torch.randn(1, 1500, 384),                   # encoder_output
        torch.zeros(NUM_LAYERS, 1, NUM_HEADS, MAX_SEQ_LEN, HEAD_DIM),   # self_k
        torch.zeros(NUM_LAYERS, 1, NUM_HEADS, MAX_SEQ_LEN, HEAD_DIM),   # self_v
        torch.zeros(NUM_LAYERS, 1, NUM_HEADS, ENCODER_SEQ_LEN, HEAD_DIM),  # cross_k
        torch.zeros(NUM_LAYERS, 1, NUM_HEADS, ENCODER_SEQ_LEN, HEAD_DIM),  # cross_v
    )

    with torch.no_grad():
        traced_decoder = torch.jit.trace(kv_decoder, example_inputs)

    # Convert to CoreML
    decoder_coreml = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="input_id", shape=(1, 1), dtype=np.int32),
            ct.TensorType(name="position", shape=(1,), dtype=np.int32),
            ct.TensorType(name="encoder_output", shape=(1, 1500, 384), dtype=np.float32),
            ct.TensorType(name="self_attn_k_cache", shape=(NUM_LAYERS, 1, NUM_HEADS, MAX_SEQ_LEN, HEAD_DIM), dtype=np.float32),
            ct.TensorType(name="self_attn_v_cache", shape=(NUM_LAYERS, 1, NUM_HEADS, MAX_SEQ_LEN, HEAD_DIM), dtype=np.float32),
            ct.TensorType(name="cross_attn_k_cache", shape=(NUM_LAYERS, 1, NUM_HEADS, ENCODER_SEQ_LEN, HEAD_DIM), dtype=np.float32),
            ct.TensorType(name="cross_attn_v_cache", shape=(NUM_LAYERS, 1, NUM_HEADS, ENCODER_SEQ_LEN, HEAD_DIM), dtype=np.float32),
        ],
        outputs=[
            ct.TensorType(name="logits", dtype=np.float32),
            ct.TensorType(name="new_self_attn_k_cache", dtype=np.float32),
            ct.TensorType(name="new_self_attn_v_cache", dtype=np.float32),
            ct.TensorType(name="new_cross_attn_k_cache", dtype=np.float32),
            ct.TensorType(name="new_cross_attn_v_cache", dtype=np.float32),
        ],
        minimum_deployment_target=ct.target.iOS17,
    )
    decoder_path = f"{OUTPUT_DIR}/TarteelDecoderKV.mlpackage"
    decoder_coreml.save(decoder_path)
    print(f"   ✓ Saved {decoder_path}")

    # Save mel filters and vocab
    print("\n[6/6] Saving resources...")
    from transformers import WhisperFeatureExtractor
    fe = WhisperFeatureExtractor()
    mel_filters = fe.mel_filters.T.astype(np.float32)
    mel_filters.tofile(f"{OUTPUT_DIR}/mel_filters.bin")
    print(f"   ✓ Saved mel_filters.bin")

    vocab = processor.tokenizer.get_vocab()
    with open(f"{OUTPUT_DIR}/tarteel_vocab.json", "w") as f:
        json.dump(vocab, f, ensure_ascii=False)
    print(f"   ✓ Saved tarteel_vocab.json")

    # Compile for iOS
    print("\n[7/7] Compiling for iOS...")

    for name in ["TarteelEncoder", "TarteelDecoderKV"]:
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
    print("Decoder uses I/O KV-cache (works on iOS 17+)")
    print("=" * 60)


if __name__ == "__main__":
    main()
