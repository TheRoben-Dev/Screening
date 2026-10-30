#!/usr/bin/env python3
"""Synthesizes Screening/Resources/ScannerSweep.wav, so the sound is original and tweakable.

Modelled on a 90s flatbed rather than a modern one: a relay clunk, a slow and uneven stepper
you can hear individual teeth in, a loose carriage rattling along, and a two-part "ka-chunk"
at the end of travel. The output stage rolls off the highs and saturates, like the sound
coming through a small speaker or old tape, which is most of what makes it read as retro.
"""
import math, os, random, struct, wave

RATE = 44100
LENGTH = 0.48
random.seed(1994)
out = [0.0] * int(RATE * LENGTH)


def add_ring(at, freq, decay, gain):
    """A single decaying resonance, the building block of every tooth and clunk."""
    start = int(at * RATE)
    for i in range(int(decay * 6 * RATE)):
        if start + i >= len(out):
            break
        t = i / RATE
        out[start + i] += gain * math.exp(-t / decay) * math.sin(2 * math.pi * freq * t)


def add_noise_burst(at, length, gain):
    start = int(at * RATE)
    count = int(length * RATE)
    for i in range(count):
        if start + i >= len(out):
            break
        out[start + i] += gain * random.uniform(-1, 1) * (1 - i / count) ** 2


def add_clunk(at, gain):
    """Heavy plastic and steel: mostly low body, with a short bite on the front."""
    add_ring(at, 105, 0.030, gain)
    add_ring(at, 340, 0.014, gain * 0.7)
    add_ring(at, 980, 0.005, gain * 0.45)
    add_noise_burst(at, 0.010, gain * 0.5)


def smooth(x):
    x = max(0.0, min(1.0, x))
    return x * x * (3 - 2 * x)


MOTOR_START, MOTOR_END = 0.045, 0.385
LOW, HIGH = 150.0, 330.0
RAMP = 0.075

add_ring(0.0, 2100, 0.002, 0.25)  # Relay tick just ahead of the clunk.
add_clunk(0.004, 0.75)

t = MOTOR_START
step = 0
while t < MOTOR_END:
    ramp = smooth((t - MOTOR_START) / RAMP) * smooth((MOTOR_END - t) / (RAMP * 0.8))
    rate = LOW + (HIGH - LOW) * ramp
    # A worn stepper isn't even: alternate phases land harder and the timing wanders.
    accent = (1.0, 0.62, 0.85, 0.55)[step % 4]
    level = (0.10 + 0.20 * ramp) * accent * random.uniform(0.88, 1.12)
    add_ring(t, 190, 0.0065, level)
    add_ring(t, 640, 0.0032, level * 0.9)
    add_ring(t, 1420, 0.0014, level * 0.5)
    t += (1 / rate) * random.uniform(0.95, 1.05)
    step += 1

# The loose carriage: band-limited noise, chattering at a low rate.
slow = fast = 0.0
for i in range(len(out)):
    t = i / RATE
    noise = random.uniform(-1, 1)
    fast += 0.28 * (noise - fast)
    slow += 0.04 * (noise - slow)
    if MOTOR_START < t < MOTOR_END:
        chatter = 0.55 + 0.45 * math.sin(2 * math.pi * 37 * t) * math.sin(2 * math.pi * 11 * t)
        out[i] += 0.11 * (fast - slow) * chatter * smooth((t - MOTOR_START) / RAMP) * smooth((MOTOR_END - t) / RAMP)

add_clunk(0.392, 0.35)  # Ka-
add_clunk(0.424, 0.85)  # -chunk

# Output stage: remove rumble, roll off the top twice, then saturate.
def lowpass(samples, cutoff):
    coefficient = 1 - math.exp(-2 * math.pi * cutoff / RATE)
    state, result = 0.0, []
    for s in samples:
        state += coefficient * (s - state)
        result.append(state)
    return result


low = lowpass(out, 70)
shaped = [s - l for s, l in zip(out, low)]
shaped = lowpass(lowpass(shaped, 3800), 5200)
peak = max(abs(s) for s in shaped)
shaped = [math.tanh(2.4 * s / peak) for s in shaped]

peak = max(abs(s) for s in shaped)
samples = [s / peak * 0.7 for s in shaped]  # Headroom: capture sounds shouldn't startle.
fade = int(0.008 * RATE)
for i in range(fade):
    samples[-1 - i] *= i / fade

path = os.path.join(os.path.dirname(__file__), "..", "Screening", "Resources", "ScannerSweep.wav")
with wave.open(path, "wb") as file:
    file.setnchannels(1)
    file.setsampwidth(2)
    file.setframerate(RATE)
    file.writeframes(b"".join(struct.pack("<h", int(s * 32767)) for s in samples))
