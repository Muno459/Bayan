#!/usr/bin/env python3
"""
End-to-end test of the Whisper model using Python.
This tests the model before CoreML conversion.
"""

import torch
import torch.nn as nn
import numpy as np
from huggingface_hub import hf_hub_download
import json

MODEL_NAME = "tarteel-ai/whisper-tiny-ar-quran"

# Load vocab
def load_vocab():
    vocab_path = hf_hub_download(repo_id=MODEL_NAME, filename="vocab.json")
    with open(vocab_path) as f:
        vocab = json.load(f)
    reverse_vocab = {v: k for k, v in vocab.items()}
    return vocab, reverse_vocab

# Whisper tiny config
n_mels = 80
n_audio_ctx = 1500
n_audio_state = 384
n_audio_head = 6
n_audio_layer = 4
n_text_state = 384
n_text_head = 6
n_text_layer = 4
n_vocab = 51865
n_text_ctx = 448

class MultiHeadAttention(nn.Module):
    def __init__(self, n_state, n_head):
        super().__init__()
        self.n_head = n_head
        self.head_dim = n_state // n_head
        self.scale = self.head_dim ** -0.5
        self.query = nn.Linear(n_state, n_state)
        self.key = nn.Linear(n_state, n_state, bias=False)
        self.value = nn.Linear(n_state, n_state)
        self.out = nn.Linear(n_state, n_state)

    def forward(self, x, xa=None):
        if xa is None:
            xa = x
        batch = x.shape[0]
        q = self.query(x).view(batch, -1, self.n_head, self.head_dim).permute(0, 2, 1, 3)
        k = self.key(xa).view(batch, -1, self.n_head, self.head_dim).permute(0, 2, 1, 3)
        v = self.value(xa).view(batch, -1, self.n_head, self.head_dim).permute(0, 2, 1, 3)
        attn = torch.matmul(q, k.transpose(-2, -1)) * self.scale
        attn = torch.softmax(attn, dim=-1)
        out = torch.matmul(attn, v)
        out = out.permute(0, 2, 1, 3).contiguous().view(batch, -1, self.n_head * self.head_dim)
        return self.out(out)

class EncoderLayer(nn.Module):
    def __init__(self, n_state, n_head):
        super().__init__()
        self.attn_ln = nn.LayerNorm(n_state)
        self.attn = MultiHeadAttention(n_state, n_head)
        self.mlp_ln = nn.LayerNorm(n_state)
        self.mlp = nn.Sequential(nn.Linear(n_state, n_state * 4), nn.GELU(), nn.Linear(n_state * 4, n_state))

    def forward(self, x):
        x = x + self.attn(self.attn_ln(x))
        x = x + self.mlp(self.mlp_ln(x))
        return x

class DecoderLayer(nn.Module):
    def __init__(self, n_state, n_head):
        super().__init__()
        self.attn_ln = nn.LayerNorm(n_state)
        self.attn = MultiHeadAttention(n_state, n_head)
        self.cross_attn_ln = nn.LayerNorm(n_state)
        self.cross_attn = MultiHeadAttention(n_state, n_head)
        self.mlp_ln = nn.LayerNorm(n_state)
        self.mlp = nn.Sequential(nn.Linear(n_state, n_state * 4), nn.GELU(), nn.Linear(n_state * 4, n_state))

    def forward(self, x, encoder_output):
        x = x + self.attn(self.attn_ln(x))
        x = x + self.cross_attn(self.cross_attn_ln(x), encoder_output)
        x = x + self.mlp(self.mlp_ln(x))
        return x

class Encoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.conv1 = nn.Conv1d(n_mels, n_audio_state, kernel_size=3, padding=1)
        self.conv2 = nn.Conv1d(n_audio_state, n_audio_state, kernel_size=3, stride=2, padding=1)
        self.positional_embedding = nn.Parameter(torch.zeros(n_audio_ctx, n_audio_state))
        self.layers = nn.ModuleList([EncoderLayer(n_audio_state, n_audio_head) for _ in range(n_audio_layer)])
        self.ln_post = nn.LayerNorm(n_audio_state)

    def forward(self, mel):
        x = nn.functional.gelu(self.conv1(mel))
        x = nn.functional.gelu(self.conv2(x))
        x = x.permute(0, 2, 1)
        x = x + self.positional_embedding
        for layer in self.layers:
            x = layer(x)
        return self.ln_post(x)

class Decoder(nn.Module):
    def __init__(self):
        super().__init__()
        self.token_embedding = nn.Embedding(n_vocab, n_text_state)
        self.positional_embedding = nn.Parameter(torch.zeros(n_text_ctx, n_text_state))
        self.layers = nn.ModuleList([DecoderLayer(n_text_state, n_text_head) for _ in range(n_text_layer)])
        self.ln = nn.LayerNorm(n_text_state)

    def forward(self, tokens, encoder_output):
        x = self.token_embedding(tokens) + self.positional_embedding[:tokens.shape[1]]
        for layer in self.layers:
            x = layer(x, encoder_output)
        x = self.ln(x)
        return x @ self.token_embedding.weight.T

def load_weights(encoder, decoder):
    print(f"Downloading {MODEL_NAME}...")
    weights_path = hf_hub_download(repo_id=MODEL_NAME, filename="pytorch_model.bin")
    state_dict = torch.load(weights_path, map_location="cpu", weights_only=True)

    # Encoder
    encoder.conv1.weight.data = state_dict['model.encoder.conv1.weight']
    encoder.conv1.bias.data = state_dict['model.encoder.conv1.bias']
    encoder.conv2.weight.data = state_dict['model.encoder.conv2.weight']
    encoder.conv2.bias.data = state_dict['model.encoder.conv2.bias']
    encoder.positional_embedding.data = state_dict['model.encoder.embed_positions.weight']
    encoder.ln_post.weight.data = state_dict['model.encoder.layer_norm.weight']
    encoder.ln_post.bias.data = state_dict['model.encoder.layer_norm.bias']

    for i in range(n_audio_layer):
        prefix = f'model.encoder.layers.{i}'
        layer = encoder.layers[i]
        layer.attn_ln.weight.data = state_dict[f'{prefix}.self_attn_layer_norm.weight']
        layer.attn_ln.bias.data = state_dict[f'{prefix}.self_attn_layer_norm.bias']
        layer.attn.query.weight.data = state_dict[f'{prefix}.self_attn.q_proj.weight']
        layer.attn.query.bias.data = state_dict[f'{prefix}.self_attn.q_proj.bias']
        layer.attn.key.weight.data = state_dict[f'{prefix}.self_attn.k_proj.weight']
        layer.attn.value.weight.data = state_dict[f'{prefix}.self_attn.v_proj.weight']
        layer.attn.value.bias.data = state_dict[f'{prefix}.self_attn.v_proj.bias']
        layer.attn.out.weight.data = state_dict[f'{prefix}.self_attn.out_proj.weight']
        layer.attn.out.bias.data = state_dict[f'{prefix}.self_attn.out_proj.bias']
        layer.mlp_ln.weight.data = state_dict[f'{prefix}.final_layer_norm.weight']
        layer.mlp_ln.bias.data = state_dict[f'{prefix}.final_layer_norm.bias']
        layer.mlp[0].weight.data = state_dict[f'{prefix}.fc1.weight']
        layer.mlp[0].bias.data = state_dict[f'{prefix}.fc1.bias']
        layer.mlp[2].weight.data = state_dict[f'{prefix}.fc2.weight']
        layer.mlp[2].bias.data = state_dict[f'{prefix}.fc2.bias']

    # Decoder
    decoder.token_embedding.weight.data = state_dict['model.decoder.embed_tokens.weight']
    decoder.positional_embedding.data = state_dict['model.decoder.embed_positions.weight']

    for i in range(n_text_layer):
        prefix = f'model.decoder.layers.{i}'
        layer = decoder.layers[i]
        layer.attn_ln.weight.data = state_dict[f'{prefix}.self_attn_layer_norm.weight']
        layer.attn_ln.bias.data = state_dict[f'{prefix}.self_attn_layer_norm.bias']
        layer.attn.query.weight.data = state_dict[f'{prefix}.self_attn.q_proj.weight']
        layer.attn.query.bias.data = state_dict[f'{prefix}.self_attn.q_proj.bias']
        layer.attn.key.weight.data = state_dict[f'{prefix}.self_attn.k_proj.weight']
        layer.attn.value.weight.data = state_dict[f'{prefix}.self_attn.v_proj.weight']
        layer.attn.value.bias.data = state_dict[f'{prefix}.self_attn.v_proj.bias']
        layer.attn.out.weight.data = state_dict[f'{prefix}.self_attn.out_proj.weight']
        layer.attn.out.bias.data = state_dict[f'{prefix}.self_attn.out_proj.bias']
        layer.cross_attn_ln.weight.data = state_dict[f'{prefix}.encoder_attn_layer_norm.weight']
        layer.cross_attn_ln.bias.data = state_dict[f'{prefix}.encoder_attn_layer_norm.bias']
        layer.cross_attn.query.weight.data = state_dict[f'{prefix}.encoder_attn.q_proj.weight']
        layer.cross_attn.query.bias.data = state_dict[f'{prefix}.encoder_attn.q_proj.bias']
        layer.cross_attn.key.weight.data = state_dict[f'{prefix}.encoder_attn.k_proj.weight']
        layer.cross_attn.value.weight.data = state_dict[f'{prefix}.encoder_attn.v_proj.weight']
        layer.cross_attn.value.bias.data = state_dict[f'{prefix}.encoder_attn.v_proj.bias']
        layer.cross_attn.out.weight.data = state_dict[f'{prefix}.encoder_attn.out_proj.weight']
        layer.cross_attn.out.bias.data = state_dict[f'{prefix}.encoder_attn.out_proj.bias']
        layer.mlp_ln.weight.data = state_dict[f'{prefix}.final_layer_norm.weight']
        layer.mlp_ln.bias.data = state_dict[f'{prefix}.final_layer_norm.bias']
        layer.mlp[0].weight.data = state_dict[f'{prefix}.fc1.weight']
        layer.mlp[0].bias.data = state_dict[f'{prefix}.fc1.bias']
        layer.mlp[2].weight.data = state_dict[f'{prefix}.fc2.weight']
        layer.mlp[2].bias.data = state_dict[f'{prefix}.fc2.bias']

    decoder.ln.weight.data = state_dict['model.decoder.layer_norm.weight']
    decoder.ln.bias.data = state_dict['model.decoder.layer_norm.bias']

def decode_token(token, reverse_vocab):
    if token not in reverse_vocab:
        return ""
    word = reverse_vocab[token]
    if word.startswith("<|") and word.endswith("|>"):
        return ""
    return word.replace("Ġ", " ")

def transcribe(encoder, decoder, mel, reverse_vocab, max_tokens=10):
    """Run inference."""
    SOT = 50258
    EOT = 50257
    LANG = 50272  # Arabic
    TASK = 50359  # Transcribe
    NOTIMESTAMPS = 50363

    with torch.no_grad():
        encoder_output = encoder(mel)
        print(f"Encoder output: {encoder_output.shape}, sum={encoder_output.sum().item():.2f}")

        tokens = [SOT, LANG, TASK, NOTIMESTAMPS]
        for _ in range(max_tokens):
            input_ids = torch.tensor([tokens], dtype=torch.long)
            logits = decoder(input_ids, encoder_output)
            next_token = logits[0, -1, :51865].argmax().item()  # Skip timestamp tokens
            print(f"  Token {len(tokens)-4}: {next_token} ({decode_token(next_token, reverse_vocab)!r})")
            if next_token == EOT:
                break
            tokens.append(next_token)

    text = "".join(decode_token(t, reverse_vocab) for t in tokens[4:])
    return text.strip()

def main():
    print("Loading models...")
    encoder = Encoder()
    decoder = Decoder()
    load_weights(encoder, decoder)
    encoder.eval()
    decoder.eval()

    vocab, reverse_vocab = load_vocab()

    # Test with random mel (simulating silence/noise)
    print("\n=== Test 1: Random noise ===")
    mel = torch.randn(1, 80, 3000) * 0.1
    text = transcribe(encoder, decoder, mel, reverse_vocab)
    print(f"Transcription: '{text}'")

    # Test with different random
    print("\n=== Test 2: Different random ===")
    mel = torch.randn(1, 80, 3000) * 0.2
    text = transcribe(encoder, decoder, mel, reverse_vocab)
    print(f"Transcription: '{text}'")

    # Test with silence
    print("\n=== Test 3: Silence ===")
    mel = torch.zeros(1, 80, 3000)
    text = transcribe(encoder, decoder, mel, reverse_vocab)
    print(f"Transcription: '{text}'")

    # Test with using transformers for comparison
    print("\n=== Test 4: Using HuggingFace transformers ===")
    try:
        from transformers import WhisperProcessor, WhisperForConditionalGeneration
        model = WhisperForConditionalGeneration.from_pretrained(MODEL_NAME)
        processor = WhisperProcessor.from_pretrained(MODEL_NAME)
        model.eval()

        # Generate from random mel
        mel_hf = torch.randn(1, 80, 3000)
        with torch.no_grad():
            generated = model.generate(mel_hf, language="ar", task="transcribe", max_new_tokens=10)
            text_hf = processor.decode(generated[0], skip_special_tokens=True)
            print(f"HuggingFace transcription: '{text_hf}'")
    except Exception as e:
        print(f"HuggingFace test failed: {e}")

if __name__ == "__main__":
    main()
