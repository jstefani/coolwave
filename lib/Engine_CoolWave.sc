// Engine_CoolWave
// NES / C64 / FM / formant wavetable synth (PD Wavy.pd / main.pd port)
// Wavetables: audio/0100..0103, 0105..0128 (1024 frames, skip 0104 grain buffer)

Engine_CoolWave : CroneEngine {
  classvar <polyMax = 6;
  classvar <waveCount = 28;
  classvar <tableFrames = 1024;

  var <bufs;
  var <voices;
  var <voiceOrder;
  var <monoId;
  var <monoSynth;
  var <fxSynth;
  var <clearSynth;
  var <voiceBus;
  var <clearGrp;
  var <ctlGrp;
  var <grp;
  var <fxGrp;

  var <waveIndex;
  var <monoMode;
  var <monoLegato;

  var <busAmp, <busPorta, <busPhase, <busPhaseLfoRate, <busPhaseLfoAmt;
  var <busAttack, <busDecay, <busSustain, <busRelease;
  var <busCutoff, <busRes, <busDelayTime, <busDelayFb, <busDelayVol, <busDelayPanRate;

  var <ctlAmp, <ctlPorta, <ctlPhase, <ctlPhaseLfoRate, <ctlPhaseLfoAmt;
  var <ctlAttack, <ctlDecay, <ctlSustain, <ctlRelease;
  var <ctlCutoff, <ctlRes, <ctlDelayTime, <ctlDelayFb, <ctlDelayVol, <ctlDelayPanRate;

  *new { arg context, doneCallback;
    ^super.new(context, doneCallback);
  }

  alloc {
    var s = context.server;

    voices = Dictionary.new;
    voiceOrder = List.new;
    monoId = nil;
    monoSynth = nil;
    waveIndex = 0;
    monoMode = false;
    monoLegato = false;
    bufs = Array.newClear(waveCount);

    // node order matters: clear the private voice bus, THEN sum voices into
    // it, THEN read it in the fx synth. without the clear, whatever was on the
    // bus last block persists once voices free and gets fed back through the
    // delay's LocalIn.
    clearGrp = Group.new(context.xg);
    ctlGrp = Group.after(clearGrp);
    grp = Group.after(ctlGrp);
    fxGrp = Group.after(grp);
    voiceBus = Bus.audio(s, 2);

    busAmp = Bus.control(s, 1); busAmp.set(0.55);
    busPorta = Bus.control(s, 1); busPorta.set(0.0);
    busPhase = Bus.control(s, 1); busPhase.set(0.0);
    busPhaseLfoRate = Bus.control(s, 1); busPhaseLfoRate.set(0.0);
    busPhaseLfoAmt = Bus.control(s, 1); busPhaseLfoAmt.set(0.0);
    busAttack = Bus.control(s, 1); busAttack.set(0.01);
    busDecay = Bus.control(s, 1); busDecay.set(0.2);
    busSustain = Bus.control(s, 1); busSustain.set(0.7);
    busRelease = Bus.control(s, 1); busRelease.set(0.25);
    busCutoff = Bus.control(s, 1); busCutoff.set(3500);
    busRes = Bus.control(s, 1); busRes.set(0.15);
    busDelayTime = Bus.control(s, 1); busDelayTime.set(0.25);
    busDelayFb = Bus.control(s, 1); busDelayFb.set(0.2);
    busDelayVol = Bus.control(s, 1); busDelayVol.set(0.15);
    busDelayPanRate = Bus.control(s, 1); busDelayPanRate.set(0.4);

    ctlAmp = { Out.kr(busAmp, Lag.kr(\val.kr(0.55), 0.05)) }.play(ctlGrp);
    ctlPorta = { Out.kr(busPorta, Lag.kr(\val.kr(0.0), 0.05)) }.play(ctlGrp);
    ctlPhase = { Out.kr(busPhase, Lag.kr(\val.kr(0.0), 0.08)) }.play(ctlGrp);
    ctlPhaseLfoRate = { Out.kr(busPhaseLfoRate, Lag.kr(\val.kr(0.0), 0.08)) }.play(ctlGrp);
    ctlPhaseLfoAmt = { Out.kr(busPhaseLfoAmt, Lag.kr(\val.kr(0.0), 0.08)) }.play(ctlGrp);
    ctlAttack = { Out.kr(busAttack, \val.kr(0.01)) }.play(ctlGrp);
    ctlDecay = { Out.kr(busDecay, \val.kr(0.2)) }.play(ctlGrp);
    ctlSustain = { Out.kr(busSustain, \val.kr(0.7)) }.play(ctlGrp);
    ctlRelease = { Out.kr(busRelease, \val.kr(0.25)) }.play(ctlGrp);
    ctlCutoff = { Out.kr(busCutoff, Lag.kr(\val.kr(3500), 0.08)) }.play(ctlGrp);
    ctlRes = { Out.kr(busRes, Lag.kr(\val.kr(0.15), 0.05)) }.play(ctlGrp);
    ctlDelayTime = { Out.kr(busDelayTime, Lag.kr(\val.kr(0.25), 0.1)) }.play(ctlGrp);
    ctlDelayFb = { Out.kr(busDelayFb, Lag.kr(\val.kr(0.2), 0.08)) }.play(ctlGrp);
    ctlDelayVol = { Out.kr(busDelayVol, Lag.kr(\val.kr(0.15), 0.05)) }.play(ctlGrp);
    ctlDelayPanRate = { Out.kr(busDelayPanRate, Lag.kr(\val.kr(0.4), 0.08)) }.play(ctlGrp);

    // buffers filled by loadDir from Lua (norns.state.dust path)
    SynthDef(\coolWaveVoice, {
      arg out = 0, bufnum = 0, hz = 440, vel = 0.8, gate = 1, t_retrig = 0,
        portaBus, phaseBus, phaseLfoRateBus, phaseLfoAmtBus,
        attackBus, decayBus, sustainBus, releaseBus,
        cutoffBus, resBus;

      var porta, phase, phaseLfoRate, phaseLfoAmt;
      var attack, decay, sustain, release, cutoff, res;
      var freq, ampEnv, envGate, phaseLfo, phasor, phasePos, osc, filtered, sig;
      var frames;

      porta = In.kr(portaBus).max(0);
      phase = In.kr(phaseBus).clip(0, 1);
      phaseLfoRate = In.kr(phaseLfoRateBus).max(0);
      phaseLfoAmt = In.kr(phaseLfoAmtBus).clip(0, 1);
      attack = In.kr(attackBus).max(0.001);
      decay = In.kr(decayBus).max(0.001);
      sustain = In.kr(sustainBus).clip(0, 1);
      release = In.kr(releaseBus).max(0.001);
      cutoff = In.kr(cutoffBus).clip(40, 16000);
      res = In.kr(resBus).clip(0, 0.95);

      // portamento via Lag (0 = instant). Especially useful in mono.
      freq = Lag.kr(hz, porta);

      // t_retrig must pull the env gate to 0 for a control cycle so EnvGen
      // sees a real 0→1 edge. `gate + t_retrig` does not: 1+1=2 stays on.
      // doneAction:2 would also free the synth if a 1-cycle blank finished a
      // tiny release; free only when the real gate is closed and env is done.
      envGate = gate * (1 - Trig1.kr(t_retrig, ControlDur.ir));
      ampEnv = EnvGen.kr(
        Env.adsr(attack, decay, sustain, release, curve: -3),
        envGate,
        doneAction: 0
      );
      FreeSelf.kr(Done.kr(ampEnv) * (1 - gate));

      frames = BufFrames.kr(bufnum);
      phaseLfo = SinOsc.kr(phaseLfoRate) * phaseLfoAmt * 0.5;
      // phase 0..1 offset into cycle (wrap). Not all waves speak across full range.
      phasor = Phasor.ar(0, freq * frames / SampleRate.ir, 0, frames);
      phasePos = (phasor + ((phase + phaseLfo) * frames)).wrap(0, frames);
      osc = BufRd.ar(1, bufnum, phasePos, loop: 1, interpolation: 4);

      // Moog-ish LPF (RLPF); do NOT load moog~.pd_linux
      filtered = RLPF.ar(osc, cutoff, (1 - res).clip(0.05, 1));
      sig = filtered * ampEnv * vel * 0.45;
      Out.ar(out, Pan2.ar(sig, 0));
    }).add;

    SynthDef(\coolWaveClear, {
      arg bus = 0;
      ReplaceOut.ar(bus, Silent.ar(2));
    }).add;

    SynthDef(\coolWaveFx, {
      arg out = 0, inBus = 0,
        delayTimeBus, delayFbBus, delayVolBus, delayPanRateBus, ampBus;

      var delayTime, delayFb, delayVol, delayPanRate, amp;
      var dry, mono, fb, delayed, pan, wet, mixed, limited;

      delayTime = In.kr(delayTimeBus).clip(0.01, 1.4);
      delayFb = In.kr(delayFbBus).clip(0, 0.95);
      delayVol = In.kr(delayVolBus).clip(0, 1);
      delayPanRate = In.kr(delayPanRateBus).max(0);
      amp = In.kr(ampBus);

      dry = In.ar(inBus, 2);
      mono = dry.sum * 0.5;
      fb = LocalIn.ar(1);
      delayed = DelayC.ar(mono + (fb * delayFb), 1.5, Lag.kr(delayTime, 0.15));
      delayed = LPF.ar(delayed, 6000);
      LocalOut.ar(delayed);

      // leslie-ish autopan on delay only
      pan = SinOsc.kr(delayPanRate);
      wet = Pan2.ar(delayed * delayVol, pan);
      mixed = (dry + wet) * amp;
      limited = tanh(mixed * 1.2) * 0.9;
      Out.ar(out, limited);
    }).add;

    s.sync;

    clearSynth = Synth(\coolWaveClear, [\bus, voiceBus.index], clearGrp);

    fxSynth = Synth(\coolWaveFx, [
      \out, context.out_b.index,
      \inBus, voiceBus.index,
      \delayTimeBus, busDelayTime.index,
      \delayFbBus, busDelayFb.index,
      \delayVolBus, busDelayVol.index,
      \delayPanRateBus, busDelayPanRate.index,
      \ampBus, busAmp.index
    ], fxGrp);

    this.addCommand(\amp, "f", { |msg| ctlAmp.set(\val, msg[1]) });
    this.addCommand(\wave, "i", { |msg|
      var idx = msg[1].asInteger.clip(0, waveCount - 1);
      waveIndex = idx;
      voices.keysValuesDo({ |id, synth|
        synth.set(\bufnum, bufs[idx].bufnum);
      });
      if (monoSynth.notNil, {
        monoSynth.set(\bufnum, bufs[idx].bufnum);
      });
    });
    this.addCommand(\porta, "f", { |msg| ctlPorta.set(\val, msg[1].max(0)) });
    this.addCommand(\phase, "f", { |msg| ctlPhase.set(\val, msg[1].clip(0, 1)) });
    this.addCommand(\phaseLfoRate, "f", { |msg| ctlPhaseLfoRate.set(\val, msg[1].max(0)) });
    this.addCommand(\phaseLfoAmt, "f", { |msg| ctlPhaseLfoAmt.set(\val, msg[1].clip(0, 1)) });
    this.addCommand(\attack, "f", { |msg| ctlAttack.set(\val, msg[1]) });
    this.addCommand(\decay, "f", { |msg| ctlDecay.set(\val, msg[1]) });
    this.addCommand(\sustain, "f", { |msg| ctlSustain.set(\val, msg[1]) });
    this.addCommand(\release, "f", { |msg| ctlRelease.set(\val, msg[1]) });
    this.addCommand(\cutoff, "f", { |msg| ctlCutoff.set(\val, msg[1]) });
    this.addCommand(\res, "f", { |msg| ctlRes.set(\val, msg[1]) });
    this.addCommand(\delayTime, "f", { |msg| ctlDelayTime.set(\val, msg[1]) });
    this.addCommand(\delayFb, "f", { |msg| ctlDelayFb.set(\val, msg[1]) });
    this.addCommand(\delayVol, "f", { |msg| ctlDelayVol.set(\val, msg[1]) });
    this.addCommand(\delayPanRate, "f", { |msg| ctlDelayPanRate.set(\val, msg[1]) });
    this.addCommand(\mono, "i", { |msg|
      monoMode = msg[1].asInteger > 0;
      this.prAllOff;
    });
    this.addCommand(\monoLegato, "i", { |msg| monoLegato = msg[1].asInteger > 0 });
    this.addCommand(\loadDir, "s", { |msg|
      var dir = msg[1].asString;
      var fileList = [
        "0100.wav", "0101.wav", "0102.wav", "0103.wav",
        "0105.wav", "0106.wav", "0107.wav", "0108.wav",
        "0109.wav", "0110.wav", "0111.wav", "0112.wav",
        "0113.wav", "0114.wav", "0115.wav", "0116.wav",
        "0117.wav", "0118.wav", "0119.wav", "0120.wav",
        "0121.wav", "0122.wav", "0123.wav", "0124.wav",
        "0125.wav", "0126.wav", "0127.wav", "0128.wav"
      ];
      waveCount.do({ |idx|
        var p = dir +/+ fileList[idx];
        if (bufs[idx].notNil, { bufs[idx].free });
        bufs[idx] = Buffer.read(s, p);
      });
    });

    this.addCommand(\noteOn, "ffi", { |msg|
      this.prNoteOn(msg[1], msg[2], msg[3].asInteger);
    });
    this.addCommand(\noteOff, "i", { |msg|
      this.prNoteOff(msg[1].asInteger);
    });
    this.addCommand(\allOff, "", { this.prAllOff });
    this.addCommand(\allNotesOff, "", { this.prAllOff });
  }

  prVoiceArgs { |hz, vel, buf|
    ^[
      \out, voiceBus.index,
      \bufnum, buf.bufnum,
      \hz, hz,
      \vel, vel.clip(0, 1),
      \gate, 1,
      \portaBus, busPorta.index,
      \phaseBus, busPhase.index,
      \phaseLfoRateBus, busPhaseLfoRate.index,
      \phaseLfoAmtBus, busPhaseLfoAmt.index,
      \attackBus, busAttack.index,
      \decayBus, busDecay.index,
      \sustainBus, busSustain.index,
      \releaseBus, busRelease.index,
      \cutoffBus, busCutoff.index,
      \resBus, busRes.index
    ];
  }

  prStealOldest {
    var oldId, oldSynth;
    if (voiceOrder.size > 0, {
      oldId = voiceOrder.removeAt(0);
      oldSynth = voices[oldId];
      if (oldSynth.notNil, {
        oldSynth.set(\gate, 0);
        voices.removeAt(oldId);
      });
    });
  }

  prNoteOn { |hz, vel, id|
    var synth, buf;
    buf = bufs[waveIndex];
    if (buf.isNil, { ^nil });

    if (monoMode, {
      if (monoSynth.notNil, {
        // reuse the node so Lag.kr porta continues. reopen gate in case a
        // noteOff just arrived; t_retrig re-attacks unless legato is on.
        monoSynth.set(
          \hz, hz,
          \vel, vel.clip(0, 1),
          \bufnum, buf.bufnum,
          \gate, 1,
          \t_retrig, if(monoLegato, 0, 1)
        );
        monoId = id;
      }, {
        synth = Synth(\coolWaveVoice, this.prVoiceArgs(hz, vel, buf), grp);
        monoSynth = synth;
        monoId = id;
        synth.onFree({
          if (monoSynth === synth, {
            monoSynth = nil;
            monoId = nil;
          });
        });
      });
      ^nil;
    });

    if (voices[id].notNil, {
      voices[id].set(\gate, 0);
      voices.removeAt(id);
      voiceOrder.remove(id);
    });
    if (voices.size >= polyMax, {
      this.prStealOldest;
    });
    synth = Synth(\coolWaveVoice, this.prVoiceArgs(hz, vel, buf), grp);
    voices[id] = synth;
    voiceOrder.add(id);
    synth.onFree({
      if (voices[id] === synth, {
        voices.removeAt(id);
        voiceOrder.remove(id);
      });
    });
  }

  prNoteOff { |id|
    var synth;
    if (monoMode, {
      if ((monoId == id) && monoSynth.notNil, {
        monoSynth.set(\gate, 0);
        monoId = nil;
      });
      ^nil;
    });
    synth = voices[id];
    if (synth.notNil, {
      synth.set(\gate, 0);
    });
  }

  prAllOff {
    voices.keysValuesDo({ |id, synth|
      synth.set(\gate, 0);
    });
    voices.clear;
    voiceOrder.clear;
    if (monoSynth.notNil, {
      monoSynth.set(\gate, 0);
      monoSynth = nil;
    });
    monoId = nil;
  }

  free {
    this.prAllOff;
    if (fxSynth.notNil, { fxSynth.free });
    if (clearSynth.notNil, { clearSynth.free });
    [ctlAmp, ctlPorta, ctlPhase, ctlPhaseLfoRate, ctlPhaseLfoAmt,
      ctlAttack, ctlDecay, ctlSustain, ctlRelease,
      ctlCutoff, ctlRes, ctlDelayTime, ctlDelayFb, ctlDelayVol, ctlDelayPanRate
    ].do({ |c| if (c.notNil, { c.free }) });
    [busAmp, busPorta, busPhase, busPhaseLfoRate, busPhaseLfoAmt,
      busAttack, busDecay, busSustain, busRelease,
      busCutoff, busRes, busDelayTime, busDelayFb, busDelayVol, busDelayPanRate,
      voiceBus
    ].do({ |b| if (b.notNil, { b.free }) });
    bufs.do({ |b| if (b.notNil, { b.free }) });
    if (fxGrp.notNil, { fxGrp.free });
    if (grp.notNil, { grp.free });
    if (ctlGrp.notNil, { ctlGrp.free });
    if (clearGrp.notNil, { clearGrp.free });
  }
}
