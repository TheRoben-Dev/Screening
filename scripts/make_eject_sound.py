#!/usr/bin/env python3
"""Synthesizes Screening/Resources/PhotoEject.wav: an instant camera feeding out a photo.

Built like the physical event, with no oscillators: every gear tooth and roller catch is a tiny
random impact, and those impacts ring a small hollow plastic body. The card sliding out is
friction noise that stutters. The rate of impacts is what you hear as the motor, so its pitch
stays rough instead of turning into a clean digital tone.
"""
import math, os, random, struct, wave

RATE = 44100
LENGTH = 0.40
TEETH_START, TEETH_END = 0.012, 0.300
SLIDE_START, SLIDE_END = 0.050, 0.315
random.seed(600)

size = int(RATE * LENGTH)
impacts = [0.0] * size  # Everything that strikes the housing.
slide = [0.0] * size    # Friction from the card, mostly heard directly.


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


def strike(at, length, gain):
    """A short grain of noise: hard contact has no pitch of its own."""
    start = int(at * RATE)
    count = max(int(length * RATE), 2)
    for i in range(count):
        if start + i < size:
            impacts[start + i] += gain * random.uniform(-1, 1) * (1 - i / count)


# Gear teeth: fast, uneven, and heavier once per rotation, with the odd missed contact.
t = TEETH_START
tooth = 0
while t < TEETH_END:
    speed = 240 + 300 * smooth((t - TEETH_START) / 0.035)
    speed -= 70 * smooth((t - 0.06) / 0.05)  # The rollers take up the load.
    envelope = smooth((t - TEETH_START) / 0.012) * (1 - 0.7 * smooth((t - (TEETH_END - 0.035)) / 0.035))
    rotation = 0.72 + 0.28 * math.sin(tooth * 2 * math.pi / 11)
    if random.random() > 0.07:
        strike(t, 0.0007, envelope * rotation * random.uniform(0.45, 1.0))
    t += (1 / speed) * random.uniform(0.82, 1.18)
    tooth += 1

strike(0.0, 0.0018, 1.6)                      # Drive engaging.
strike(0.052, 0.002, 1.5)                     # Rollers bite the card.
strike(SLIDE_END - 0.002, 0.0012, 1.3)        # Tail of the card flicks free.
strike(SLIDE_END + 0.012, 0.0035, 2.0)        # Drive stops against the housing.

# The card: band-limited noise whose level jitters, the way paper drags and releases.
fast = slow = grip = 0.0
for i in range(size):
    t = i / RATE
    noise = random.uniform(-1, 1)
    fast += 0.55 * (noise - fast)
    slow += 0.10 * (noise - slow)
    grip += 0.012 * (abs(random.uniform(-1, 1)) - grip)
    swell = smooth((t - SLIDE_START) / 0.11) * (1 - smooth((t - (SLIDE_END - 0.018)) / 0.018))
    slide[i] = (fast - slow) * swell * (0.25 + 2.2 * grip)

# The housing: a few irregular, heavily damped modes plus a short rattle of diffuse noise.
MODES = [(287, 0.0060, 1.0), (523, 0.0050, 0.9), (911, 0.0040, 0.8), (1483, 0.0028, 0.7),
         (2270, 0.0018, 0.55), (3390, 0.0011, 0.4)]
body_size = int(0.022 * RATE)
body = [0.0] * body_size
for freq, decay, gain in MODES:
    for i in range(body_size):
        n = i / RATE
        body[i] += gain * math.exp(-n / decay) * math.sin(2 * math.pi * freq * n)
for i in range(body_size):
    body[i] += 0.5 * random.uniform(-1, 1) * math.exp(-(i / RATE) / 0.004)

ringing = [0.0] * size
for i, value in enumerate(impacts):
    if value:
        for j in range(min(body_size, size - i)):
            ringing[i + j] += value * body[j]

ringing_peak = max(abs(s) for s in ringing)
slide_peak = max(abs(s) for s in slide)
out = [0.85 * r / ringing_peak + 0.55 * s / slide_peak + 0.12 * imp for r, s, imp in zip(ringing, slide, impacts)]


def lowpass(samples, cutoff):
    coefficient = 1 - math.exp(-2 * math.pi * cutoff / RATE)
    state, result = 0.0, []
    for s in samples:
        state += coefficient * (s - state)
        result.append(state)
    return result


low = lowpass(out, 130)
shaped = lowpass([s - l for s, l in zip(out, low)], 8500)
peak = max(abs(s) for s in shaped)
shaped = [math.tanh(1.5 * s / peak) for s in shaped]
peak = max(abs(s) for s in shaped)
samples = [s / peak * 0.66 for s in shaped]
fade = int(0.006 * RATE)
for i in range(fade):
    samples[-1 - i] *= i / fade

path = os.path.join(os.path.dirname(__file__), "..", "Screening", "Resources", "PhotoEject.wav")
with wave.open(path, "wb") as file:
    file.setnchannels(1)
    file.setsampwidth(2)
    file.setframerate(RATE)
    file.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))
