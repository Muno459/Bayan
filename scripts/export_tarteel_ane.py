#!/usr/bin/env python3
"""
Export Tarteel Whisper using whisper.cpp's ANE-optimized approach.

Based on: https://github.com/ggml-org/whisper.cpp/blob/master/models/convert-whisper-to-coreml.py
"""

import torch
import torch.nn.functional as F
import coremltools as ct
import numpy as np
from torch import Tensor, nn
from typing import Optional
import subprocess
import tempfile
import wave
import os
import shutil
import json

# Import whisper and ANE components
from whisper.model import ModelDimensions
from whisper import load_model
from ane_transformers.reference.layer_norm import LayerNormANE as LayerNormANEBase

OUTPUT_DIR = "Bayan/Resources/Data"


def correct_for_bias_scale_order_inversion(state_dict, prefix, local_metadata,
                                           strict, missing_keys,
                                           unexpected_keys, error_msgs):
    state_dict[prefix + 'bias'] = state_dict[prefix + 'bias'] / state_dict[prefix + 'weight']
    return state_dict


class LayerNormANE(LayerNormANEBase):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._register_load_state_dict_pre_hook(correct_for_bias_scale_order_inversion)


class MultiHeadAttentionANE(nn.Module):
    def __init__(self, n_state: int, n_head: int):
        super().__init__()
        self.n_head = n_head
        self.query = nn.Conv2d(n_state, n_state, kernel_size=1)
        self.key = nn.Conv2d(n_state, n_state, kernel_size=1, bias=False)
        self.value = nn.Conv2d(n_state, n_state, kernel_size=1)
        self.out = nn.Conv2d(n_state, n_state, kernel_size=1)

    def forward(self, x: Tensor, xa: Optional[Tensor] = None, mask: Optional[Tensor] = None):
        q = self.query(x)
        k = self.key(x if xa is None else xa)
        v = self.value(x if xa is None else xa)

        _, dim, _, seqlen = q.size()
        dim_per_head = dim // self.n_head
        scale = float(dim_per_head) ** -0.5
        q = q * scale

        mh_q = q.split(dim_per_head, dim=1)
        mh_k = k.transpose(1, 3).split(dim_per_head, dim=3)
        mh_v = v.split(dim_per_head, dim=1)

        mh_qk = [torch.einsum('bchq,bkhc->bkhq', [qi, ki]) for qi, ki in zip(mh_q, mh_k)]

        if mask is not None:
            for head_idx in range(self.n_head):
                mh_qk[head_idx] = mh_qk[head_idx] + mask[:, :seqlen, :, :seqlen]

        attn_weights = [aw.softmax(dim=1) for aw in mh_qk]
        attn = [torch.einsum('bkhq,bchk->bchq', wi, vi) for wi, vi in zip(attn_weights, mh_v)]
        attn = torch.cat(attn, dim=1)

        return self.out(attn)


class ResidualAttentionBlockANE(nn.Module):
    def __init__(self, n_state: int, n_head: int, cross_attention: bool = False):
        super().__init__()
        self.attn = MultiHeadAttentionANE(n_state, n_head)
        self.attn_ln = LayerNormANE(n_state)

        self.cross_attn = MultiHeadAttentionANE(n_state, n_head) if cross_attention else None
        self.cross_attn_ln = LayerNormANE(n_state) if cross_attention else None

        n_mlp = n_state * 4
        self.mlp = nn.Sequential(
            nn.Conv2d(n_state, n_mlp, kernel_size=1),
            nn.GELU(),
            nn.Conv2d(n_mlp, n_state, kernel_size=1)
        )
        self.mlp_ln = LayerNormANE(n_state)

    def forward(self, x: Tensor, xa: Optional[Tensor] = None, mask: Optional[Tensor] = None):
        x = x + self.attn(self.attn_ln(x), mask=mask)
        if self.cross_attn is not None:
            x = x + self.cross_attn(self.cross_attn_ln(x), xa)
        x = x + self.mlp(self.mlp_ln(x))
        return x


class AudioEncoderANE(nn.Module):
    def __init__(self, n_mels: int, n_ctx: int, n_state: int, n_head: int, n_layer: int):
        super().__init__()
        self.conv1 = nn.Conv1d(n_mels, n_state, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(n_state, n_state, kernel_size=3, stride=2, padding=1)
        self.register_buffer("positional_embedding", torch.empty(n_ctx, n_state))
        self.blocks = nn.ModuleList([ResidualAttentionBlockANE(n_state, n_head) for _ in range(n_layer)])
        self.ln_post = LayerNormANE(n_state)

    def forward(self, x: Tensor):
        x = F.gelu(self.conv1(x))
        x = F.gelu(self.conv2(x))
        x = (x + self.positional_embedding.transpose(0, 1)).to(x.dtype).unsqueeze(2)
        for block in self.blocks:
            x = block(x)
        x = self.ln_post(x)
        x = x.squeeze(2).transpose(1, 2)
        return x


class TextDecoderANE(nn.Module):
    def __init__(self, n_vocab: int, n_ctx: int, n_state: int, n_head: int, n_layer: int, fixed_seq_len: int = 24):
        super().__init__()
        self.token_embedding = nn.Embedding(n_vocab, n_state)
        # Use fixed-size positional embedding for the sequence length we'll use
        self.positional_embedding = nn.Parameter(torch.empty(fixed_seq_len, n_state))
        self.blocks = nn.ModuleList([ResidualAttentionBlockANE(n_state, n_head, cross_attention=True) for _ in range(n_layer)])
        self.ln = LayerNormANE(n_state)
        # Fixed-size mask for the sequence length
        self.register_buffer("mask", torch.empty(fixed_seq_len, fixed_seq_len))
        self.n_state = n_state
        self.fixed_seq_len = fixed_seq_len

    def forward(self, x: Tensor, xa: Tensor):
        # x is always (batch, fixed_seq_len)
        x = self.token_embedding(x) + self.positional_embedding
        x = x.to(xa.dtype)

        mask = self.mask[None, None, :, :].permute(0, 3, 1, 2)
        x = x.transpose(1, 2).unsqueeze(2)
        xa = xa.transpose(1, 2).unsqueeze(2)

        for block in self.blocks:
            x = block(x, xa, mask=mask)

        x = self.ln(x)
        x = x.permute(0, 2, 3, 1).squeeze(1)

        # Compute logits
        logits = (x @ self.token_embedding.weight.T).float()
        return logits


def linear_to_conv2d_map(state_dict, prefix, local_metadata, strict, missing_keys, unexpected_keys, error_msgs):
    """Unsqueeze twice to map nn.Linear weights to nn.Conv2d weights"""
    for k in state_dict:
        is_attention = all(substr in k for substr in ['attn', '.weight'])
        is_mlp = any(k.endswith(s) for s in ['mlp.0.weight', 'mlp.2.weight'])
        if (is_attention or is_mlp) and len(state_dict[k].shape) == 2:
            state_dict[k] = state_dict[k][:, :, None, None]


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


def main():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    print("=" * 60)
    print("TARTEEL WHISPER ANE EXPORT")
    print("=" * 60)

    # Load original whisper tiny model first to get dimensions
    print("\n[1/6] Loading whisper-tiny model structure...")

    # Whisper tiny dimensions
    dims = ModelDimensions(
        n_mels=80,
        n_audio_ctx=1500,
        n_audio_state=384,
        n_audio_head=6,
        n_audio_layer=4,
        n_vocab=51865,
        n_text_ctx=448,
        n_text_state=384,
        n_text_head=6,
        n_text_layer=4,
    )

    # Load Tarteel model weights from HuggingFace
    print("\n[2/6] Loading Tarteel weights...")
    from transformers import WhisperForConditionalGeneration, WhisperProcessor

    processor = WhisperProcessor.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    hf_model = WhisperForConditionalGeneration.from_pretrained("tarteel-ai/whisper-tiny-ar-quran")
    hf_model.eval()

    # Create ANE encoder
    print("\n[3/6] Creating ANE-optimized encoder...")
    encoder = AudioEncoderANE(
        n_mels=dims.n_mels,
        n_ctx=dims.n_audio_ctx,
        n_state=dims.n_audio_state,
        n_head=dims.n_audio_head,
        n_layer=dims.n_audio_layer,
    )
    encoder._register_load_state_dict_pre_hook(linear_to_conv2d_map)

    # Map HuggingFace encoder weights to ANE encoder
    hf_enc = hf_model.model.encoder.state_dict()
    ane_enc_dict = {}

    # Direct mappings
    ane_enc_dict['conv1.weight'] = hf_enc['conv1.weight']
    ane_enc_dict['conv1.bias'] = hf_enc['conv1.bias']
    ane_enc_dict['conv2.weight'] = hf_enc['conv2.weight']
    ane_enc_dict['conv2.bias'] = hf_enc['conv2.bias']
    ane_enc_dict['positional_embedding'] = hf_enc['embed_positions.weight']
    ane_enc_dict['ln_post.weight'] = hf_enc['layer_norm.weight']
    ane_enc_dict['ln_post.bias'] = hf_enc['layer_norm.bias']

    # Block mappings
    for i in range(dims.n_audio_layer):
        hf_prefix = f'layers.{i}.'
        ane_prefix = f'blocks.{i}.'

        # Self-attention
        ane_enc_dict[ane_prefix + 'attn.query.weight'] = hf_enc[hf_prefix + 'self_attn.q_proj.weight'][:, :, None, None]
        ane_enc_dict[ane_prefix + 'attn.query.bias'] = hf_enc[hf_prefix + 'self_attn.q_proj.bias']
        ane_enc_dict[ane_prefix + 'attn.key.weight'] = hf_enc[hf_prefix + 'self_attn.k_proj.weight'][:, :, None, None]
        ane_enc_dict[ane_prefix + 'attn.value.weight'] = hf_enc[hf_prefix + 'self_attn.v_proj.weight'][:, :, None, None]
        ane_enc_dict[ane_prefix + 'attn.value.bias'] = hf_enc[hf_prefix + 'self_attn.v_proj.bias']
        ane_enc_dict[ane_prefix + 'attn.out.weight'] = hf_enc[hf_prefix + 'self_attn.out_proj.weight'][:, :, None, None]
        ane_enc_dict[ane_prefix + 'attn.out.bias'] = hf_enc[hf_prefix + 'self_attn.out_proj.bias']

        # Layer norms
        ane_enc_dict[ane_prefix + 'attn_ln.weight'] = hf_enc[hf_prefix + 'self_attn_layer_norm.weight']
        ane_enc_dict[ane_prefix + 'attn_ln.bias'] = hf_enc[hf_prefix + 'self_attn_layer_norm.bias']
        ane_enc_dict[ane_prefix + 'mlp_ln.weight'] = hf_enc[hf_prefix + 'final_layer_norm.weight']
        ane_enc_dict[ane_prefix + 'mlp_ln.bias'] = hf_enc[hf_prefix + 'final_layer_norm.bias']

        # MLP
        ane_enc_dict[ane_prefix + 'mlp.0.weight'] = hf_enc[hf_prefix + 'fc1.weight'][:, :, None, None]
        ane_enc_dict[ane_prefix + 'mlp.0.bias'] = hf_enc[hf_prefix + 'fc1.bias']
        ane_enc_dict[ane_prefix + 'mlp.2.weight'] = hf_enc[hf_prefix + 'fc2.weight'][:, :, None, None]
        ane_enc_dict[ane_prefix + 'mlp.2.bias'] = hf_enc[hf_prefix + 'fc2.bias']

    encoder.load_state_dict(ane_enc_dict)
    encoder.eval()

    # Test encoder
    print("\n[4/6] Testing and exporting encoder...")
    audio = download_test_audio()
    mel = processor(audio, sampling_rate=16000, return_tensors="pt")["input_features"]

    with torch.no_grad():
        hf_enc_out = hf_model.model.encoder(mel).last_hidden_state
        ane_enc_out = encoder(mel)

    enc_diff = (hf_enc_out - ane_enc_out).abs().mean().item()
    print(f"   Encoder diff: {enc_diff:.6f}")

    # Export encoder
    traced_encoder = torch.jit.trace(encoder, mel)
    encoder_coreml = ct.convert(
        traced_encoder,
        inputs=[ct.TensorType(name="mel", shape=(1, 80, 3000), dtype=np.float32)],
        outputs=[ct.TensorType(name="encoder_output", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    encoder_path = f"{OUTPUT_DIR}/TarteelEncoder.mlpackage"
    encoder_coreml.save(encoder_path)
    print(f"   ✓ Saved {encoder_path}")

    # Create ANE decoder (fixed input size)
    print("\n[5/6] Creating ANE-optimized decoder...")
    MAX_SEQ = 24  # Fixed sequence length

    decoder = TextDecoderANE(
        n_vocab=dims.n_vocab,
        n_ctx=dims.n_text_ctx,
        n_state=dims.n_text_state,
        n_head=dims.n_text_head,
        n_layer=dims.n_text_layer,
        fixed_seq_len=MAX_SEQ,
    )

    # Map HuggingFace decoder weights
    hf_dec = hf_model.model.decoder.state_dict()
    ane_dec_dict = {}

    ane_dec_dict['token_embedding.weight'] = hf_dec['embed_tokens.weight']
    # Only use first MAX_SEQ positions
    ane_dec_dict['positional_embedding'] = hf_dec['embed_positions.weight'][:MAX_SEQ]
    ane_dec_dict['ln.weight'] = hf_dec['layer_norm.weight']
    ane_dec_dict['ln.bias'] = hf_dec['layer_norm.bias']

    # Create causal mask for fixed sequence length
    mask = torch.empty(MAX_SEQ, MAX_SEQ).fill_(-float('inf')).triu_(1)
    ane_dec_dict['mask'] = mask

    for i in range(dims.n_text_layer):
        hf_prefix = f'layers.{i}.'
        ane_prefix = f'blocks.{i}.'

        # Self-attention
        ane_dec_dict[ane_prefix + 'attn.query.weight'] = hf_dec[hf_prefix + 'self_attn.q_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'attn.query.bias'] = hf_dec[hf_prefix + 'self_attn.q_proj.bias']
        ane_dec_dict[ane_prefix + 'attn.key.weight'] = hf_dec[hf_prefix + 'self_attn.k_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'attn.value.weight'] = hf_dec[hf_prefix + 'self_attn.v_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'attn.value.bias'] = hf_dec[hf_prefix + 'self_attn.v_proj.bias']
        ane_dec_dict[ane_prefix + 'attn.out.weight'] = hf_dec[hf_prefix + 'self_attn.out_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'attn.out.bias'] = hf_dec[hf_prefix + 'self_attn.out_proj.bias']

        # Cross-attention
        ane_dec_dict[ane_prefix + 'cross_attn.query.weight'] = hf_dec[hf_prefix + 'encoder_attn.q_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'cross_attn.query.bias'] = hf_dec[hf_prefix + 'encoder_attn.q_proj.bias']
        ane_dec_dict[ane_prefix + 'cross_attn.key.weight'] = hf_dec[hf_prefix + 'encoder_attn.k_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'cross_attn.value.weight'] = hf_dec[hf_prefix + 'encoder_attn.v_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'cross_attn.value.bias'] = hf_dec[hf_prefix + 'encoder_attn.v_proj.bias']
        ane_dec_dict[ane_prefix + 'cross_attn.out.weight'] = hf_dec[hf_prefix + 'encoder_attn.out_proj.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'cross_attn.out.bias'] = hf_dec[hf_prefix + 'encoder_attn.out_proj.bias']

        # Layer norms
        ane_dec_dict[ane_prefix + 'attn_ln.weight'] = hf_dec[hf_prefix + 'self_attn_layer_norm.weight']
        ane_dec_dict[ane_prefix + 'attn_ln.bias'] = hf_dec[hf_prefix + 'self_attn_layer_norm.bias']
        ane_dec_dict[ane_prefix + 'cross_attn_ln.weight'] = hf_dec[hf_prefix + 'encoder_attn_layer_norm.weight']
        ane_dec_dict[ane_prefix + 'cross_attn_ln.bias'] = hf_dec[hf_prefix + 'encoder_attn_layer_norm.bias']
        ane_dec_dict[ane_prefix + 'mlp_ln.weight'] = hf_dec[hf_prefix + 'final_layer_norm.weight']
        ane_dec_dict[ane_prefix + 'mlp_ln.bias'] = hf_dec[hf_prefix + 'final_layer_norm.bias']

        # MLP
        ane_dec_dict[ane_prefix + 'mlp.0.weight'] = hf_dec[hf_prefix + 'fc1.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'mlp.0.bias'] = hf_dec[hf_prefix + 'fc1.bias']
        ane_dec_dict[ane_prefix + 'mlp.2.weight'] = hf_dec[hf_prefix + 'fc2.weight'][:, :, None, None]
        ane_dec_dict[ane_prefix + 'mlp.2.bias'] = hf_dec[hf_prefix + 'fc2.bias']

    decoder.load_state_dict(ane_dec_dict)
    decoder.eval()

    # Test decoder
    prompt = [50258, 50272, 50359, 50363]  # SOT, lang, task, no_timestamps
    pad_token = 50257
    padded = prompt + [pad_token] * (MAX_SEQ - len(prompt))

    with torch.no_grad():
        ids = torch.tensor([padded], dtype=torch.long)
        ane_logits = decoder(ids, ane_enc_out)

        # Compare with HuggingFace
        hf_dec_out = hf_model.model.decoder(
            input_ids=ids,
            encoder_hidden_states=hf_enc_out,
            use_cache=False
        )
        hf_logits = hf_model.proj_out(hf_dec_out.last_hidden_state)

    dec_diff = (hf_logits - ane_logits).abs().mean().item()
    print(f"   Decoder diff: {dec_diff:.6f}")

    hf_token = int(torch.argmax(hf_logits[0, len(prompt)-1, :51865]))
    ane_token = int(torch.argmax(ane_logits[0, len(prompt)-1, :51865]))
    print(f"   First token - HF: {hf_token}, ANE: {ane_token}")

    # Export decoder
    traced_decoder = torch.jit.trace(decoder, (ids, ane_enc_out))
    decoder_coreml = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, MAX_SEQ), dtype=np.int32),
            ct.TensorType(name="encoder_output", shape=(1, 1500, 384), dtype=np.float32),
        ],
        outputs=[ct.TensorType(name="logits", dtype=np.float32)],
        minimum_deployment_target=ct.target.iOS17,
    )
    decoder_path = f"{OUTPUT_DIR}/TarteelDecoder.mlpackage"
    decoder_coreml.save(decoder_path)
    print(f"   ✓ Saved {decoder_path}")

    # Save resources
    print("\n[6/6] Saving resources and compiling...")
    from transformers import WhisperFeatureExtractor
    fe = WhisperFeatureExtractor()
    mel_filters = fe.mel_filters.T.astype(np.float32)
    mel_filters.tofile(f"{OUTPUT_DIR}/mel_filters.bin")

    vocab = processor.tokenizer.get_vocab()
    with open(f"{OUTPUT_DIR}/tarteel_vocab.json", "w") as f:
        json.dump(vocab, f, ensure_ascii=False)

    # Verify CoreML models before compiling
    print("\n   Verifying CoreML models...")
    enc_cml = ct.models.MLModel(f"{OUTPUT_DIR}/TarteelEncoder.mlpackage")
    dec_cml = ct.models.MLModel(f"{OUTPUT_DIR}/TarteelDecoder.mlpackage")

    enc_cml_out = enc_cml.predict({"mel": mel.numpy()})["encoder_output"]
    print(f"   CoreML encoder: shape={enc_cml_out.shape}, range=[{enc_cml_out.min():.3f}, {enc_cml_out.max():.3f}]")

    # Test decoder with CoreML
    cml_tokens = prompt.copy()
    for _ in range(20):
        cml_padded = cml_tokens + [pad_token] * (MAX_SEQ - len(cml_tokens))
        cml_ids = np.array([cml_padded], dtype=np.int32)
        cml_logits = dec_cml.predict({"input_ids": cml_ids, "encoder_output": enc_cml_out})["logits"]
        cml_pos = len(cml_tokens) - 1
        cml_next = int(np.argmax(cml_logits[0, cml_pos, :50364]))
        if cml_next == eot:
            break
        cml_tokens.append(cml_next)

    cml_text = processor.decode(cml_tokens[4:], skip_special_tokens=True)
    print(f"   CoreML output: '{cml_text}' (tokens: {cml_tokens[4:]})")

    if cml_tokens[4:] == [1211, 6808, 995]:
        print("   ✓ CoreML matches expected output!")
    else:
        print("   ✗ CoreML output differs!")

    # Compile
    for name in ["TarteelEncoder", "TarteelDecoder"]:
        pkg = f"{OUTPUT_DIR}/{name}.mlpackage"
        compiled = f"{OUTPUT_DIR}/{name}.mlmodelc"
        if os.path.exists(compiled):
            shutil.rmtree(compiled)
        result = subprocess.run(["xcrun", "coremlcompiler", "compile", pkg, OUTPUT_DIR], capture_output=True, text=True)
        if result.returncode != 0:
            print(f"   ✗ Failed: {result.stderr}")
        else:
            shutil.rmtree(pkg)
            print(f"   ✓ Compiled {compiled}")

    print("\n" + "=" * 60)
    print("EXPORT COMPLETE - ANE optimized")
    print("=" * 60)


if __name__ == "__main__":
    main()
