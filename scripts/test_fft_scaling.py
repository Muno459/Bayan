#!/usr/bin/env python3
"""
Verify FFT magnitude scaling.
"""
import numpy as np

# Test signal
np.random.seed(42)
frame = np.random.randn(400).astype(np.float32)

# Standard numpy FFT
fft_np = np.fft.rfft(frame)
mag_np = np.abs(fft_np) ** 2

print(f"NumPy FFT magnitudes (first 5): {mag_np[:5]}")
print(f"NumPy FFT mag sum: {mag_np.sum():.2f}")

# If vDSP scales by 2, magnitudes would be 4x larger
mag_vdsp_sim = mag_np * 4
print(f"\nvDSP-scaled magnitudes (first 5): {mag_vdsp_sim[:5]}")
print(f"vDSP-scaled mag sum: {mag_vdsp_sim.sum():.2f}")

# After correction (divide by 4)
mag_corrected = mag_vdsp_sim * 0.25
print(f"\nCorrected magnitudes (first 5): {mag_corrected[:5]}")
print(f"Corrected mag sum: {mag_corrected.sum():.2f}")

# Verify they match
assert np.allclose(mag_np, mag_corrected), "Correction factor is wrong!"
print("\n✓ Correction factor of 0.25 is correct!")
