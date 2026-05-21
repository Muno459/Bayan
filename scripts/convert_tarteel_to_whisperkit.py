#!/usr/bin/env python3
"""
Convert Tarteel Whisper model to WhisperKit CoreML format.
Uses the original tarteel-ai/whisper-base-ar-quran model.
"""

import os
import sys
import shutil
from pathlib import Path

# Add whisperkittools to path
sys.path.insert(0, '/tmp/whisperkittools')

import torch
import coremltools as ct
from transformers import WhisperForConditionalGeneration, WhisperProcessor

MODEL_ID = "tarteel-ai/whisper-base-ar-quran"
OUTPUT_DIR = Path("/tmp/tarteel-coreml")

def main():
    print(f"Converting {MODEL_ID} to CoreML...")

    # Clean output directory
    if OUTPUT_DIR.exists():
        shutil.rmtree(OUTPUT_DIR)
    OUTPUT_DIR.mkdir(parents=True)

    # Load model and processor
    print("Loading model from HuggingFace...")
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_ID)
    processor = WhisperProcessor.from_pretrained(MODEL_ID)
    model.eval()

    print(f"Model config: {model.config}")

    # Export encoder
    print("\nExporting AudioEncoder...")
    encoder = model.get_encoder()

    # Create a wrapper that returns only the tensor
    class EncoderWrapper(torch.nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(self, mel):
            output = self.encoder(mel)
            return output.last_hidden_state

    encoder_wrapper = EncoderWrapper(encoder)
    encoder_wrapper.eval()

    # Whisper base: 80 mel bins, 3000 frames (30 sec at 100 fps)
    mel_input = torch.randn(1, 80, 3000)

    traced_encoder = torch.jit.trace(encoder_wrapper, mel_input)

    encoder_mlmodel = ct.convert(
        traced_encoder,
        inputs=[ct.TensorType(name="mel", shape=(1, 80, 3000))],
        outputs=[ct.TensorType(name="encoder_output")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS16,
    )

    encoder_path = OUTPUT_DIR / "AudioEncoder.mlpackage"
    encoder_mlmodel.save(str(encoder_path))
    print(f"Saved encoder to {encoder_path}")

    # Compile to mlmodelc for faster loading
    import subprocess
    compiled_encoder_path = OUTPUT_DIR / "AudioEncoder.mlmodelc"
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(encoder_path), str(OUTPUT_DIR)], check=True)
    print(f"Compiled encoder to {compiled_encoder_path}")

    # Export decoder
    print("\nExporting TextDecoder...")
    decoder = model.get_decoder()

    # Decoder inputs: input_ids + encoder_hidden_states
    # Whisper base: d_model=512, encoder sequence length=1500
    batch_size = 1
    seq_len = 448  # Max decoder length
    d_model = model.config.d_model
    encoder_seq_len = 1500

    input_ids = torch.ones(batch_size, seq_len, dtype=torch.long)
    encoder_output = torch.randn(batch_size, encoder_seq_len, d_model)

    # Create wrapper for decoder that handles the full forward pass
    class DecoderWrapper(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model
            self.lm_head = model.proj_out if hasattr(model, 'proj_out') else None

        def forward(self, input_ids, encoder_output):
            decoder_output = self.model(
                input_ids=input_ids,
                encoder_hidden_states=encoder_output,
            )
            hidden_states = decoder_output.last_hidden_state
            # Apply lm_head if available
            if self.lm_head is not None:
                logits = self.lm_head(hidden_states)
            else:
                logits = hidden_states
            return logits

    # Use the full model for logits
    class FullDecoderWrapper(torch.nn.Module):
        def __init__(self, full_model):
            super().__init__()
            self.full_model = full_model

        def forward(self, input_ids, encoder_output):
            outputs = self.full_model(
                decoder_input_ids=input_ids,
                encoder_outputs=(encoder_output,),
                return_dict=True
            )
            return outputs.logits

    decoder_wrapper = FullDecoderWrapper(model)
    decoder_wrapper.eval()

    traced_decoder = torch.jit.trace(decoder_wrapper, (input_ids, encoder_output))

    decoder_mlmodel = ct.convert(
        traced_decoder,
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, seq_len), dtype=int),
            ct.TensorType(name="encoder_output", shape=(1, encoder_seq_len, d_model)),
        ],
        outputs=[ct.TensorType(name="logits")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS16,
    )

    decoder_path = OUTPUT_DIR / "TextDecoder.mlpackage"
    decoder_mlmodel.save(str(decoder_path))
    print(f"Saved decoder to {decoder_path}")

    # Compile to mlmodelc for faster loading
    compiled_decoder_path = OUTPUT_DIR / "TextDecoder.mlmodelc"
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(decoder_path), str(OUTPUT_DIR)], check=True)
    print(f"Compiled decoder to {compiled_decoder_path}")

    # Export MelSpectrogram model (from whisperkit)
    print("\nExporting MelSpectrogram...")
    # WhisperKit handles mel spectrogram in a specific way
    # For simplicity, we'll copy from the existing model or use the Swift implementation

    # Copy tokenizer files
    print("\nCopying tokenizer files...")
    processor.tokenizer.save_pretrained(str(OUTPUT_DIR))

    # Also save config
    model.config.save_pretrained(str(OUTPUT_DIR))

    print(f"\nConversion complete! Output in {OUTPUT_DIR}")
    print("Files created:")
    for f in OUTPUT_DIR.iterdir():
        print(f"  - {f.name}")

if __name__ == "__main__":
    main()
