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

Wavetables are 1024-sample cycles resampled from the PD `wavs/` (original 600-sample loops). **`0104.wav` is omitted** — that file is the 5 s grain buffer used by grainfreeze, not an oscillator cycle.

## Controls

| Control | Action |
|--------|--------|
| **E1** | Page: `WAVE` → `ENV` → `PHASE` → `DELAY` → `ARP` (stops at ends) |
| **E2 / E3** | Edit the two params on the current page |
| **K1 + E2/E3** | Extra params (page-dependent; on WAVE: porta / octave) |
| **K2** | **MONO / POLY** toggle |
| **K3** | Randomize patch (NES-leaning ranges) |
| **MIDI notes** | Play voices (poly 6 with steal, or mono with portamento) |

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
4. **Arp decay** presets map like PD `arpdecay` into decay/sustain

Portamento is especially useful in mono (WAVE page, K1+E2).

### Phase note

Phase is a **0–1** offset into the wavetable cycle (plus optional LFO). **Not all waves speak across the full phase range** — if a wave goes thin or silent, nudge phase toward 0.

## Params (menu)

- wave, amp, portamento, octave  
- attack / decay / sustain / release  
- phase, phase LFO rate/amt  
- cutoff, resonance  
- delay time / fb / vol / pan rate  
- arp on, speed, type, decay  
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
| `octave` | i | applied in Lua to MIDI→hz |
| `arpOn` `arpSpeed` `arpType` `arpDecay` | — | API parity; **arp runs in Lua clock** |

Architecture: Phasor + BufRd wavetable voices (max 6, steal), RLPF filter, shared delay with leslie-ish autopan. Does **not** load `moog~.pd_linux`.

## Waves (28)

| UI | File | Label |
|----|------|--------|
| 1–4 | 0100–0103 | NES TRI / PUL1 / PUL2 / NOIZ |
| 5–12 | 0105–0112 | C64 … |
| 13–20 | 0113–0120 | FM … |
| 21–28 | 0121–0128 | FORM … |

## Credit

Original Pure Data: Organelle-style **Wavy** / **main** wavetable synth (NES waves + C64 / FM / formant tables). CoolWave norns port. Grainular page lives in the separate **grainfreeze** script.
