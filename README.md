# coolwave

**NES / C64 / FM / formant wavetable synth** for [monome norns](https://monome.org/docs/norns/).

Port of the Organelle / Pure Data patch (`Wavy.pd` + `main.pd`). This is **separate from [grainfreeze](../grainfreeze)** (the granular delay / freezer page).

## Install

```sh
scp -r coolwave we@norns.local:~/dust/code/
```

Or place at `~/dust/code/coolwave`:

```
coolwave/
  coolwave.lua
  lib/Engine_CoolWave.sc
  audio/0100.wav … 0103.wav, 0105.wav … 0128.wav
  README.md
```

**Restart SuperCollider** (SYSTEM → RESTART) after installing so the engine compiles. Then launch **coolwave** from SELECT.

On launch a short splash draws the real wavetables morphing into each other while the engine reads the 28 buffers. It clears itself after ~2.6 s, or immediately on any key or encoder — that first press is swallowed by the dismiss, so it will not also randomize.

Wavetables are 1024-sample cycles resampled from the PD `wavs/` (original 600-sample loops). **`0104.wav` is omitted** — that file is the 5 s grain buffer used by grainfreeze, not an oscillator cycle.

## Controls

| Control | Action |
|--------|--------|
| **E1** | Page: `WAVE` → `ENV` → `PHASE` → `DELAY` → `ARP` (stops at ends) |
| **E2 / E3** | Edit the two params on the current page |
| **K1 + E2/E3** | Extra params (page-dependent; on WAVE: porta / octave) |
| **K2** | **MONO / POLY** toggle (also a saved param: `voicing`) |
| **K3** | Randomize — patch on most pages, **arp only** on the ARP page |
| **MIDI notes** | Play voices (poly 6 with steal, or mono with portamento) |
| **MIDI CC** | 1 phase · 74 cutoff · 71 res · 73 attack · 72 release · 91 delay vol · 93 delay fb |

### Page map

| Page | E2 | E3 | K1+E2 / K1+E3 |
|------|----|----|----------------|
| WAVE | wave | cutoff | porta / octave |
| ENV | attack | release | decay / sustain |
| PHASE | phase (0–1) | phase LFO amt | LFO rate / res |
| DELAY | delay time | delay fb | delay vol / pan rate |
| ARP | arp on/off | type (up/down/updown/order) | speed / decay preset |

### Arp (favorite in mono)

1. Press **K2** for **MONO**
2. ARP page → turn arp **ON**
3. Hold a note (expands to a Maj chord + octave, PD-style) or hold a chord; notes arpeggiate at **speed** with **type**
4. **Arp decay** presets map like PD `arpdecay` into decay/sustain — applied only when you turn that control, so loading a pset keeps its saved envelope

Adding or releasing a key mid-pattern resumes near the current position rather than restarting. `updown` bounces on two held notes instead of collapsing to `up`.

**K3 on the ARP page** randomizes speed, type and decay without touching the tone, and applies the decay preset to the envelope. K3 on any other page randomizes the patch and leaves the arp alone. Neither one toggles arp on/off or poly/mono — those stay where you put them.

Portamento is especially useful in mono (WAVE page, K1+E2).

### Phase note

Phase is a **0–1** offset into the wavetable cycle (plus optional LFO). **Not all waves speak across the full phase range** — if a wave goes thin or silent, nudge phase toward 0.

## Params (menu)

- wave, amp, portamento, octave, **voicing** (poly/mono), **mono legato**  
- attack / decay / sustain / release  
- phase, phase LFO rate/amt  
- cutoff, resonance  
- delay time / fb / vol / pan rate  
- arp on, speed, type, decay  
- **midi channel** (all, or 1–16)  
- **all notes off** (trigger)

## Engine commands

`engine.name = 'CoolWave'`

| Command | Args | Notes |
|---------|------|--------|
| `noteOn` | f f i | hz, vel, id |
| `noteOff` | i | id |
| `allOff` / `allNotesOff` | — | panic |
| `wave` | i | 0..27 (UI wave 1 = file 0100) |
| `porta` | f | seconds |
| `phase` | f | 0..1 |
| `phaseLfoRate` | f | Hz |
| `phaseLfoAmt` | f | 0..1 |
| `attack` `decay` `sustain` `release` | f | ADSR |
| `cutoff` | f | Hz |
| `res` | f | 0..0.95 |
| `delayTime` `delayFb` `delayVol` `delayPanRate` | f | shared FX |
| `amp` | f | master |
| `mono` | i | 0/1 |
| `monoLegato` | i | 0/1; when on, a new mono note glides without re-striking the envelope |

Octave is applied in Lua (`note_hz`) before the hz reaches the engine, and the arp runs on a Lua clock — neither has an engine command.

Architecture: Phasor + BufRd wavetable voices (max 6, steal), RLPF filter, shared delay with leslie-ish autopan. Does **not** load `moog~.pd_linux`.

Node order is `clear → controls → voices → fx`: a `coolWaveClear` synth `ReplaceOut`s silence onto the private voice bus each block before voices sum into it, so stale audio can't leak into the delay's feedback loop. Control synths sit in their own group ahead of the voices so a voice reads current-block control values.

## Waves (28)

| UI | File | Label |
|----|------|--------|
| 1–4 | 0100–0103 | NES TRI / PUL1 / PUL2 / NOIZ |
| 5–12 | 0105–0112 | C64 … |
| 13–20 | 0113–0120 | FM … |
| 21–28 | 0121–0128 | FORM … |

## Credit

Original Pure Data: Organelle-style **Wavy** / **main** wavetable synth (NES waves + C64 / FM / formant tables). CoolWave norns port. Grainular page lives in the separate **grainfreeze** script.
