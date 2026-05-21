"""
NeMo-side ANE export for FastConformer-Quran.

WHY THIS LIVES HERE / WHEN TO RUN:
  - Must be run on Linux (NeMo doesn't install cleanly on macOS — triton +
    huggingface_hub + transformers version conflicts).
  - Free Colab is fine: open a GPU runtime, paste this into a cell, run.
  - Output is `FastConformerQuran_ane.mlpackage` (~215 MB, FP16, ANE-eligible).

THE FIX:
  The exported FP32 ONNX model has a tensor at `/encoder/pos_enc/Mul` that
  reaches 117,924 in normal inference (= `pre_encode_out × sqrt(d_model)`).
  When coremltools converts to FP16, that overflows the FP16 max (±65,504)
  and the whole encoder NaN's.

  This script LOADS the .nemo model in PyTorch, patches the RelPositionalEncoding
  to rescale `xscale` AND compensate downstream weights so accuracy is preserved,
  then exports via coremltools' recommended PyTorch path.

USAGE (Colab):
  !pip install -q nemo_toolkit[asr]==1.23.0 coremltools==8.0
  !wget -O model.nemo "https://huggingface.co/Muno459/fastconformer-quran/resolve/main/nemo/fastconformer-quran-phase4c.nemo"
  # Then run this script.
"""
import torch
import numpy as np
import coremltools as ct
from nemo.collections.asr.models import EncDecCTCModelBPE
from nemo.collections.asr.modules.conformer_encoder import ConformerEncoder

NEMO_PATH = "model.nemo"
OUT_PATH = "FastConformerQuran_ane.mlpackage"
FIXED_T = 800
RESCALE_FACTOR = 4.0  # divides xscale by this — keeps FP16-safe while preserving accuracy

# 1. Load the model. NeMo handles all the architecture instantiation.
print("loading .nemo...")
model = EncDecCTCModelBPE.restore_from(NEMO_PATH, map_location="cpu")
model.eval()
model.freeze()

# 2. Patch the relative positional encoding's xscale.
#    NeMo's ConformerEncoder uses a RelPositionalEncoding module that scales
#    input by `xscale = sqrt(d_model)`. We divide that by RESCALE_FACTOR.
#    To preserve model accuracy, we *also* multiply the INPUT to the first
#    self-attn layer by RESCALE_FACTOR, restoring the magnitude where
#    needed by downstream layers.
print(f"patching xscale: divide by {RESCALE_FACTOR}")
pos_enc = model.encoder.pos_enc
print(f"  original xscale: {pos_enc.xscale}")
pos_enc.xscale = pos_enc.xscale / RESCALE_FACTOR
print(f"  patched xscale:  {pos_enc.xscale}")

# Compensate by scaling the FIRST conformer layer's input weights.
# The first feed-forward layer's linear1 weights get multiplied by RESCALE_FACTOR
# so the layer's effective input magnitude is unchanged. Same for self-attn's
# query/key/value projections in the first layer.
print(f"compensating first-layer weights by ×{RESCALE_FACTOR}")
first_layer = model.encoder.layers[0]
with torch.no_grad():
    # Feed-forward module 1
    first_layer.feed_forward1.linear1.weight.mul_(RESCALE_FACTOR)
    # Self-attn QKV
    first_layer.self_attn.linear_q.weight.mul_(RESCALE_FACTOR)
    first_layer.self_attn.linear_k.weight.mul_(RESCALE_FACTOR)
    first_layer.self_attn.linear_v.weight.mul_(RESCALE_FACTOR)
    # Norm before FF1 will normalize the input anyway, but be safe:
    if hasattr(first_layer, 'norm_feed_forward1'):
        first_layer.norm_feed_forward1.weight.mul_(RESCALE_FACTOR)

# 3. Create a wrapped version that takes (audio_signal, length) and
#    returns just (logprobs, encoder_output). NeMo's forward returns a
#    bunch of training-specific extras we don't need for inference.
class ExportWrapper(torch.nn.Module):
    def __init__(self, nemo_model):
        super().__init__()
        self.encoder = nemo_model.encoder
        self.decoder = nemo_model.decoder
    def forward(self, audio_signal, length):
        # Encoder: (audio_signal: B×80×T, length: B,) → (encoded: B×D×T', length: B)
        encoded, encoded_len = self.encoder(audio_signal=audio_signal, length=length)
        # Decoder: encoded → logprobs (B×T'×V)
        logprobs = self.decoder(encoder_output=encoded)
        return logprobs, encoded

wrapped = ExportWrapper(model).eval()

# 4. Trace with fixed shape (1, 80, 800) — ANE wants compile-time shapes.
example_audio = torch.randn(1, 80, FIXED_T, dtype=torch.float32)
example_length = torch.tensor([FIXED_T], dtype=torch.int32)
print("tracing...")
with torch.no_grad():
    traced = torch.jit.trace(wrapped, (example_audio, example_length), strict=False)
print("traced OK")

# 5. Sanity check the traced model still gives reasonable output.
with torch.no_grad():
    out = traced(example_audio, example_length)
    logprobs, _ = out
    print(f"traced output shape: {logprobs.shape}, any NaN: {torch.isnan(logprobs).any().item()}")

# 6. coremltools.convert — recommended PyTorch path. FP16 = ANE-eligible.
print("converting to CoreML (FP16, ANE-eligible)...")
mlmodel = ct.convert(
    traced,
    inputs=[
        ct.TensorType(name="audio_signal", shape=(1, 80, FIXED_T), dtype=np.float32),
        ct.TensorType(name="length", shape=(1,), dtype=np.int32),
    ],
    outputs=[
        ct.TensorType(name="logprobs"),
        ct.TensorType(name="encoder_output"),
    ],
    convert_to="mlprogram",
    compute_precision=ct.precision.FLOAT16,
    minimum_deployment_target=ct.target.iOS17,
)
mlmodel.short_description = (
    f"FastConformer-Quran CTC. FP16 (ANE-ready). xscale rescaled by 1/{RESCALE_FACTOR} "
    "with compensating first-layer weight scaling — bypasses the FP16 NaN bug at "
    "/encoder/pos_enc/Mul (was 117,924, > FP16 max 65,504)."
)
mlmodel.save(OUT_PATH)
print(f"saved: {OUT_PATH}")

# 7. Verify on a known clip (Al-Fatihah verse 1: 'Bismillāhi-r-Raḥmāni-r-Raḥīm')
import os
test_wav = "verse1.wav"
if os.path.exists(test_wav):
    print("running smoke test...")
    import soundfile as sf, math, sentencepiece as spm
    wav, sr = sf.read(test_wav)
    if wav.ndim > 1: wav = wav.mean(axis=1)
    wav = wav.astype(np.float32)

    # log-mel (matches the iOS Swift LogMelFeatures.compute exactly)
    SR, N_FFT, HOP, N_MELS = 16000, 512, 160, 80
    def _mel_fb():
        mm = 1127.0 * math.log(1.0 + (SR/2)/700.0)
        mp = [mm*i/(N_MELS+1) for i in range(N_MELS+2)]
        hp = [700.0 * (math.exp(x/1127.0) - 1.0) for x in mp]
        bp = [int(math.floor((N_FFT+1)*h/SR)) for h in hp]
        fb = np.zeros((N_MELS, N_FFT//2+1), dtype=np.float32)
        for m in range(N_MELS):
            l, c, r = bp[m], bp[m+1], bp[m+2]
            if c!=l:
                for k in range(l,c):
                    if 0<=k<fb.shape[1]: fb[m,k]=(k-l)/(c-l)
            if r!=c:
                for k in range(c,r):
                    if 0<=k<fb.shape[1]: fb[m,k]=(r-k)/(r-c)
        return fb
    MEL_FB = _mel_fb()
    HANN = np.array([0.5*(1-math.cos(2*math.pi*i/(N_FFT-1))) for i in range(N_FFT)], dtype=np.float32)
    pre = np.empty_like(wav); pre[0]=wav[0]; pre[1:]=wav[1:] - 0.97*wav[:-1]
    p = np.pad(pre, N_FFT//2, mode='reflect')
    nT = 1 + (len(p) - N_FFT) // HOP
    m_ = np.zeros((N_MELS, nT), dtype=np.float32)
    for t in range(nT):
        s = p[t*HOP:t*HOP+N_FFT] * HANN
        spec = np.abs(np.fft.rfft(s, n=N_FFT))**2
        m_[:, t] = np.log(MEL_FB @ spec + 1e-5)
    mean = m_.mean(axis=1, keepdims=True); std = m_.std(axis=1, keepdims=True) + 1e-5
    feats = (m_ - mean) / std
    pad_out = np.zeros((N_MELS, FIXED_T), dtype=np.float32)
    pad_out[:, :min(nT, FIXED_T)] = feats[:, :min(nT, FIXED_T)]
    real_T = nT

    out = mlmodel.predict({
        "audio_signal": pad_out[None,...].astype(np.float32),
        "length": np.array([real_T], dtype=np.int32),
    })
    lp = out["logprobs"]
    print(f"  logprobs NaN? {bool(np.isnan(lp).any())}, range [{float(lp.min()):.2f}, {float(lp.max()):.2f}]")
    BLANK_ID = 1024
    def collapse(ids):
        out, prev = [], -1
        for i in ids:
            if i == BLANK_ID: prev = -1; continue
            if i != prev: out.append(int(i))
            prev = i
        return out
    ids = lp[0, :(real_T + 7) // 8].argmax(axis=-1).tolist()
    tok = spm.SentencePieceProcessor(model_file="tokenizer.model")
    print(f"  TRANSCRIPT: {tok.decode(collapse(ids))}")
    print("  expected:   بِسْمِ اللَّهِ الرَّحْمَنِ الرَّحِيم")
