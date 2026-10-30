#!/usr/bin/env python3
"""Synthesizes Screening/Resources/LiquidRipple.wav to go with the capture ripple animation.

An original sound aiming for the restraint of a system sound: a few soft, warm tones in an open
chord, rising like a ripple spreading. Each note glides up into pitch the way a water drop does,
which keeps it liquid. There's no noise or sparkle up high, and everything is rolled off well
below where a sound starts to feel bright, then held in a soft, dark room.
"""
import math, os, struct, wave

RATE = 44100
LENGTH = 1.05
size = int(RATE * LENGTH)
left = [0.0] * size
right = [0.0] * size


def add_tone(at, freq, decay, gain, pan):
    """A rounded tone: slow attack, a quick glide up into pitch, and a little warmth above it."""
    start = int(at * RATE)
    left_gain = gain * math.cos((pan + 1) * math.pi / 4)
    right_gain = gain * math.sin((pan + 1) * math.pi / 4)
    phase_l = phase_r = 0.0
    for i in range(int(decay * 6 * RATE)):
        if start + i >= size:
            break
        t = i / RATE
        glide = 1 - 0.13 * math.exp(-t / 0.022)
        # A hair of detune between the ears gives width without any obvious effect.
        phase_l += 2 * math.pi * freq * glide * 0.9994 / RATE
        phase_r += 2 * math.pi * freq * glide * 1.0006 / RATE
        attack = 1 - math.exp(-t / 0.007)
        body = attack * math.exp(-t / decay)
        upper = 0.2 * math.exp(-t / (decay * 0.35))
        left[start + i] += left_gain * body * (math.sin(phase_l) + upper * math.sin(2 * phase_l))
        right[start + i] += right_gain * body * (math.sin(phase_r) + upper * math.sin(2 * phase_r))


# An open Dsus2 chord: leaving out the third keeps it calm rather than sweet.
add_tone(0.000, 146.83, 0.26, 0.55, 0.0)    # D3, the weight underneath.
add_tone(0.004, 293.66, 0.24, 0.80, -0.08)  # D4
add_tone(0.082, 440.00, 0.23, 0.55, 0.14)   # A4
add_tone(0.165, 587.33, 0.25, 0.38, -0.20)  # D5
add_tone(0.255, 659.25, 0.28, 0.24, 0.28)   # E5, the open note it comes to rest on.


def lowpass(samples, cutoff):
    coefficient = 1 - math.exp(-2 * math.pi * cutoff / RATE)
    state, result = 0.0, []
    for s in samples:
        state += coefficient * (s - state)
        result.append(state)
    return result


def room(dry, delays):
    """A soft room: combs damped hard, so the tail is dark and never rings."""
    wet = [0.0] * len(dry)
    for delay, feedback in delays:
        line = [0.0] * delay
        index = 0
        damp = 0.0
        for i, sample in enumerate(dry):
            value = line[index]
            damp += 0.22 * (value - damp)
            line[index] = sample + damp * feedback
            index = (index + 1) % delay
            wet[i] += value / len(delays)
    return wet


wet_left = room(left, [(1487, 0.80), (1789, 0.78), (2111, 0.76), (2467, 0.74)])
wet_right = room(right, [(1559, 0.80), (1867, 0.78), (2203, 0.76), (2531, 0.74)])
mixed_left = lowpass([d + 0.42 * w for d, w in zip(left, wet_left)], 2600)
mixed_right = lowpass([d + 0.42 * w for d, w in zip(right, wet_right)], 2600)

peak = max(max(abs(s) for s in mixed_left), max(abs(s) for s in mixed_right))
fade = int(0.12 * RATE)
frames = bytearray()
for i in range(size):
    scale = min(1.0, (size - 1 - i) / fade)
    for sample in (mixed_left[i], mixed_right[i]):
        value = math.tanh(1.1 * sample / peak) * 0.6 * scale
        frames += struct.pack("<h", int(value * 32767))

path = os.path.join(os.path.dirname(__file__), "..", "Screening", "Resources", "LiquidRipple.wav")
with wave.open(path, "wb") as file:
    file.setnchannels(2)
    file.setsampwidth(2)
    file.setframerate(RATE)
    file.writeframes(bytes(frames))
