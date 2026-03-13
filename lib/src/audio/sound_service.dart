import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import '../logging.dart';
import '../platform/windows/win32_audio.dart';

/// Available ring tone styles
enum RingTone {
  chime,       // Ascending three-note chime (C5->E5->G5)
  classic,     // Traditional phone ring
  soft,        // Gentle two-note
  alert,       // Urgent fast beeps
  melody,      // Short musical phrase
}

/// Generates and plays ringing, ringback, DTMF, and voice audio.
///
/// Uses a SINGLE persistent WinAudioPlayer for ALL output.
/// This avoids issues where closing one waveOut handle breaks others.
class SoundService {
  static final SoundService instance = SoundService._internal();
  SoundService._internal();

  static const int _sampleRate = 16000;
  static const int _bufSize = 3200; // 100ms at 16kHz mono 16-bit
  static const int _numBufs = 20;

  // Pre-generated audio buffers
  final Map<RingTone, Uint8List> _ringTones = {};
  late final Uint8List _endTone;
  late final Uint8List _dtmfTick;
  late final Uint8List _ringbackTone; // just the 1s tone portion
  late final Uint8List _voiceStartTone; // diagnostic beep on voice start
  bool _initialized = false;

  int _outputDeviceId = 0xFFFFFFFF;
  RingTone _selectedRingTone = RingTone.chime;

  // ── Single persistent player ──
  WinAudioPlayer? _player;

  // Ring state (incoming call)
  Timer? _ringTimer;
  bool _isRinging = false;

  // Ringback state (outgoing call waiting)
  Timer? _ringbackTimer;
  bool _isPlayingRingback = false;

  // Voice state
  bool _voicePlaying = false;
  int _voiceWriteCount = 0;
  final List<Uint8List> _voiceAccum = [];
  int _voiceAccumBytes = 0;

  // Output gain (1.0 = normal, up to 10.0 = 1000%)
  double _outputGain = 5.0;
  double get outputGain => _outputGain;
  void setOutputGain(double gain) {
    _outputGain = gain.clamp(0.0, 20.0);
  }

  RingTone get selectedRingTone => _selectedRingTone;
  bool get isVoicePlaying => _voicePlaying;
  bool get isRinging => _isRinging;

  void setRingTone(RingTone tone) {
    _selectedRingTone = tone;
  }

  /// Pre-generate all tone buffers and open the persistent player.
  void initialize() {
    if (_initialized) return;

    // Log available output devices for debugging
    try {
      final devices = WinAudioDevices.getOutputDevices();
      sipLog('[SipSound] ═══ Output devices ═══');
      for (int i = 0; i < devices.length; i++) {
        sipLog('[SipSound]   [$i] ${devices[i]}');
      }
      sipLog('[SipSound]   Selected: $_outputDeviceId (${_outputDeviceId == 0xFFFFFFFF ? "WAVE_MAPPER" : _outputDeviceId.toString()})');
    } catch (_) {}

    _ringTones[RingTone.chime] = _buildChimeRing();
    _ringTones[RingTone.classic] = _buildClassicRing();
    _ringTones[RingTone.soft] = _buildSoftRing();
    _ringTones[RingTone.alert] = _buildAlertRing();
    _ringTones[RingTone.melody] = _buildMelodyRing();
    _endTone = _buildEndTone();
    _dtmfTick = _buildDtmfTick();
    _ringbackTone = _note(425, 1000, amplitude: 0.25); // 1s tone only
    _voiceStartTone = _note(880, 60, amplitude: 0.5); // short diagnostic beep
    _openPlayer();
    _initialized = true;
  }

  void _openPlayer() {
    _player?.close();
    _player = WinAudioPlayer(
      numBuffers: _numBufs,
      bufferSize: _bufSize,
      sampleRate: _sampleRate,
      deviceId: _outputDeviceId,
    );
    if (!_player!.open()) {
      sipLog('[SipSound] FAILED to open player on device $_outputDeviceId');
      _player = null;
      return;
    }
    _player!.setMaxVolume();
    // Log device name for debugging
    String deviceName = 'WAVE_MAPPER (system default)';
    if (_outputDeviceId != 0xFFFFFFFF) {
      final devices = WinAudioDevices.getOutputDevices();
      if (_outputDeviceId < devices.length) {
        deviceName = devices[_outputDeviceId];
      } else {
        deviceName = 'UNKNOWN (index $_outputDeviceId)';
      }
    }
    sipLog('[SipSound] Player opened: $_numBufs x $_bufSize bytes, device=$_outputDeviceId ($deviceName)');
  }

  void setOutputDevice(int deviceId) {
    if (_outputDeviceId == deviceId) return;
    final oldId = _outputDeviceId;
    _outputDeviceId = deviceId;
    sipLog('[SipSound] Output device changed: $oldId → $deviceId');
    if (_initialized) {
      final wasVoicePlaying = _voicePlaying;
      _openPlayer();
      // Restore voice state if it was active
      if (wasVoicePlaying) {
        _voicePlaying = true;
        sipLog('[SipSound] Voice playback restored after device change');
      }
    }
  }

  // ── Ring tone preview ──

  void previewRingTone(RingTone tone) {
    if (_player == null) return;
    final toneData = _ringTones[tone];
    if (toneData == null) return;
    _player!.reset();
    _player!.write(toneData);
  }

  // ── Ringing (incoming call) ──

  void startRinging() {
    if (_player == null || _isRinging) return;
    _isRinging = true;
    final toneData = _ringTones[_selectedRingTone] ?? _ringTones[RingTone.chime]!;
    _player!.write(toneData);
    _ringTimer = Timer.periodic(const Duration(milliseconds: 3000), (_) {
      if (_isRinging && _player != null) {
        _player!.write(toneData);
      }
    });
  }

  void stopRinging({bool transferToVoice = false}) {
    if (!_isRinging) return;
    _isRinging = false;
    _ringTimer?.cancel();
    _ringTimer = null;
    if (transferToVoice) {
      // Reopen player (Bluetooth may have switched A2DP→HFP when mic started)
      _reopenPlayerForVoice();
      _voiceAccum.clear();
      _voiceAccumBytes = 0;
      _voicePlaying = true;
      _voiceWriteCount = 0;
      _player?.write(_voiceStartTone);
      sipLog('[SipSound] Ring→Voice, device=$_outputDeviceId');
    } else {
      _player?.reset();
    }
  }

  // ── Ringback (outgoing call ringing) ──

  void startRingback() {
    if (_player == null || _isPlayingRingback) return;
    _isPlayingRingback = true;
    _player!.write(_ringbackTone);
    sipLog('[SipSound] Ringback started (1s/4s cycle)');
    _ringbackTimer = Timer.periodic(const Duration(milliseconds: 4000), (_) {
      if (_isPlayingRingback && _player != null) {
        _player!.write(_ringbackTone);
      }
    });
  }

  void stopRingback({bool transferToVoice = false}) {
    if (!_isPlayingRingback) return;
    _isPlayingRingback = false;
    _ringbackTimer?.cancel();
    _ringbackTimer = null;
    if (transferToVoice) {
      // Reopen player (Bluetooth may have switched A2DP→HFP when mic started)
      _reopenPlayerForVoice();
      _voiceAccum.clear();
      _voiceAccumBytes = 0;
      _voicePlaying = true;
      _voiceWriteCount = 0;
      _player?.write(_voiceStartTone);
      sipLog('[SipSound] Ringback→Voice, device=$_outputDeviceId');
    } else {
      _player?.reset();
    }
  }

  // ── DTMF tick ──

  void playDtmfTick() {
    if (_player == null) return;
    _player!.write(_dtmfTick);
  }

  // ── Call end tone ──

  void playCallEnd() {
    if (_player == null) return;
    _player!.write(_endTone);
  }

  // ── Voice playback ──

  void startVoicePlayback() {
    if (_voicePlaying) {
      sipLog('[SipSound] startVoicePlayback: already active');
      return;
    }
    if (_player == null) {
      sipLog('[SipSound] startVoicePlayback: no player!');
      return;
    }

    // Re-enumerate devices (Bluetooth may have switched A2DP→HFP)
    try {
      final devices = WinAudioDevices.getOutputDevices();
      sipLog('[SipSound] Voice start — re-enumerating output devices:');
      for (int i = 0; i < devices.length; i++) {
        sipLog('[SipSound]   [$i] ${devices[i]}');
      }
    } catch (_) {}

    // CRITICAL: Reopen the player to pick up Bluetooth profile changes.
    // When mic starts on a BT headset, Windows switches A2DP→HFP.
    // The old waveOut handle on A2DP becomes dead. Must reopen.
    _reopenPlayerForVoice();

    // Clear any stale voice accumulation
    _voiceAccum.clear();
    _voiceAccumBytes = 0;
    _voicePlaying = true;
    _voiceWriteCount = 0;
    // Play a short diagnostic beep to confirm player works
    _player?.write(_voiceStartTone);
    sipLog('[SipSound] Voice started, device=$_outputDeviceId, freeBufs=${_player?.freeBufferCount ?? 0}/$_numBufs');
  }

  /// Reopen the player for voice, handling Bluetooth A2DP→HFP profile switch.
  /// When a mic starts on a Bluetooth headset, Windows switches from A2DP (stereo)
  /// to HFP (hands-free). The A2DP waveOut device becomes silently dead.
  /// We detect this and switch to the HFP output device automatically.
  void _reopenPlayerForVoice() {
    _player?.close();
    _player = null;

    final devices = WinAudioDevices.getOutputDevices();

    // Check if selected device is a Bluetooth A2DP (Stereo) device
    // If so, find and use the corresponding Hands-Free device instead
    if (_outputDeviceId != 0xFFFFFFFF && _outputDeviceId < devices.length) {
      final selectedName = devices[_outputDeviceId].toLowerCase();
      if (selectedName.contains('stereo')) {
        // Find the Hands-Free variant of the same device
        for (int i = 0; i < devices.length; i++) {
          final name = devices[i].toLowerCase();
          if (i != _outputDeviceId && name.contains('hands-free') &&
              _sharesBluetoothDevice(selectedName, name)) {
            sipLog('[SipSound] BT A2DP→HFP switch: using device $i (${devices[i]}) instead of $_outputDeviceId (${devices[_outputDeviceId]})');
            _player = WinAudioPlayer(
              numBuffers: _numBufs,
              bufferSize: _bufSize,
              sampleRate: _sampleRate,
              deviceId: i,
            );
            if (_player!.open()) {
              _player!.setMaxVolume();
              sipLog('[SipSound] Voice player opened on HFP device=$i');
              return;
            }
            sipLog('[SipSound] HFP device $i failed to open');
          }
        }
      }
    }

    // Try WAVE_MAPPER (system default) — Windows may route correctly
    _player = WinAudioPlayer(
      numBuffers: _numBufs,
      bufferSize: _bufSize,
      sampleRate: _sampleRate,
      deviceId: 0xFFFFFFFF,
    );
    if (_player!.open()) {
      _player!.setMaxVolume();
      sipLog('[SipSound] Voice player opened on WAVE_MAPPER');
      return;
    }

    // Try the user-selected device as last resort
    if (_outputDeviceId != 0xFFFFFFFF) {
      _player = WinAudioPlayer(
        numBuffers: _numBufs,
        bufferSize: _bufSize,
        sampleRate: _sampleRate,
        deviceId: _outputDeviceId,
      );
      if (_player!.open()) {
        _player!.setMaxVolume();
        sipLog('[SipSound] Voice player opened on selected device=$_outputDeviceId');
        return;
      }
    }

    sipLog('[SipSound] CRITICAL: Cannot open any output device for voice!');
    _player = null;
  }

  /// Check if two device names refer to the same Bluetooth device
  /// (e.g., "WH-CH520 Stereo" and "WH-CH520 Hands-Free")
  bool _sharesBluetoothDevice(String name1, String name2) {
    // Extract the common device identifier (e.g., "wh-ch520")
    // by finding shared words that look like a device model
    final words1 = name1.split(RegExp(r'[\s\(\)\-]+'));
    final words2 = name2.split(RegExp(r'[\s\(\)\-]+'));
    int shared = 0;
    for (final w in words1) {
      if (w.length >= 3 && w != 'stereo' && w != 'hands' && w != 'free' &&
          words2.contains(w)) {
        shared++;
      }
    }
    return shared >= 1;
  }

  void writeVoiceAudio(Uint8List pcm16kData) {
    if (!_voicePlaying || _player == null) return;

    _voiceAccum.add(pcm16kData);
    _voiceAccumBytes += pcm16kData.length;

    // Accumulate ~100ms (5 packets × 640 bytes = 3200) before writing
    if (_voiceAccumBytes >= _bufSize) {
      final merged = Uint8List(_voiceAccumBytes);
      int offset = 0;
      for (final pkt in _voiceAccum) {
        merged.setRange(offset, offset + pkt.length, pkt);
        offset += pkt.length;
      }
      _voiceAccum.clear();
      _voiceAccumBytes = 0;

      // Apply output gain
      if (_outputGain != 1.0) {
        _applyGain(merged, _outputGain);
      }

      _voiceWriteCount++;
      final freeBefore = _player!.freeBufferCount;
      final wrote = _player!.writeWithStatus(merged);
      if (_voiceWriteCount <= 30 || _voiceWriteCount % 50 == 0) {
        // Log max amplitude and buffer status
        final bd = ByteData.sublistView(merged);
        int maxAbs = 0;
        for (int i = 0; i < merged.length - 1; i += 2) {
          final s = bd.getInt16(i, Endian.little).abs();
          if (s > maxAbs) maxAbs = s;
        }
        sipLog('[SipSound] Voice #$_voiceWriteCount, ${merged.length}B, maxAmp=$maxAbs/32768, gain=${_outputGain.toStringAsFixed(1)}x, wrote=$wrote, freeBufs=$freeBefore→${_player!.freeBufferCount}/$_numBufs, dev=$_outputDeviceId');
      }
    }
  }

  /// Apply gain to PCM16 samples in-place.
  static void _applyGain(Uint8List pcm, double gain) {
    final bd = ByteData.sublistView(pcm);
    for (int i = 0; i < pcm.length - 1; i += 2) {
      final sample = bd.getInt16(i, Endian.little);
      final amplified = (sample * gain).round().clamp(-32768, 32767);
      bd.setInt16(i, amplified, Endian.little);
    }
  }

  void stopVoicePlayback() {
    if (!_voicePlaying) return;
    _voicePlaying = false;
    _voiceAccum.clear();
    _voiceAccumBytes = 0;
    sipLog('[SipSound] Voice stopped after $_voiceWriteCount writes');
    _voiceWriteCount = 0;
    // Reopen player on original device (Bluetooth may switch back to A2DP)
    _openPlayer();
  }

  // ── Ring Tone Builders ──────────────────────────────────────────

  Uint8List _buildChimeRing() {
    final buf = BytesBuilder();
    buf.add(_note(523, 110));
    buf.add(_silence(40));
    buf.add(_note(659, 110));
    buf.add(_silence(40));
    buf.add(_note(784, 160));
    buf.add(_silence(200));
    buf.add(_note(523, 110));
    buf.add(_silence(40));
    buf.add(_note(659, 110));
    buf.add(_silence(40));
    buf.add(_note(784, 160));
    return buf.toBytes();
  }

  Uint8List _buildClassicRing() {
    final buf = BytesBuilder();
    buf.add(_dualTone(400, 450, 400, amplitude: 0.3));
    buf.add(_silence(200));
    buf.add(_dualTone(400, 450, 400, amplitude: 0.3));
    return buf.toBytes();
  }

  Uint8List _buildSoftRing() {
    final buf = BytesBuilder();
    buf.add(_note(880, 150, amplitude: 0.2));
    buf.add(_silence(100));
    buf.add(_note(1047, 200, amplitude: 0.2));
    buf.add(_silence(300));
    buf.add(_note(880, 150, amplitude: 0.2));
    buf.add(_silence(100));
    buf.add(_note(1047, 200, amplitude: 0.2));
    return buf.toBytes();
  }

  Uint8List _buildAlertRing() {
    final buf = BytesBuilder();
    for (int i = 0; i < 4; i++) {
      buf.add(_note(1000, 80, amplitude: 0.4));
      buf.add(_silence(60));
    }
    buf.add(_silence(200));
    for (int i = 0; i < 4; i++) {
      buf.add(_note(1000, 80, amplitude: 0.4));
      buf.add(_silence(60));
    }
    return buf.toBytes();
  }

  Uint8List _buildMelodyRing() {
    final buf = BytesBuilder();
    buf.add(_note(523, 100, amplitude: 0.3));
    buf.add(_silence(30));
    buf.add(_note(587, 100, amplitude: 0.3));
    buf.add(_silence(30));
    buf.add(_note(659, 100, amplitude: 0.3));
    buf.add(_silence(30));
    buf.add(_note(784, 180, amplitude: 0.35));
    buf.add(_silence(250));
    buf.add(_note(523, 100, amplitude: 0.3));
    buf.add(_silence(30));
    buf.add(_note(587, 100, amplitude: 0.3));
    buf.add(_silence(30));
    buf.add(_note(659, 100, amplitude: 0.3));
    buf.add(_silence(30));
    buf.add(_note(784, 180, amplitude: 0.35));
    return buf.toBytes();
  }

  Uint8List _buildDtmfTick() {
    final buf = BytesBuilder();
    buf.add(_note(1000, 50, amplitude: 0.35));
    buf.add(_silence(10));
    return buf.toBytes();
  }

  Uint8List _buildEndTone() {
    final buf = BytesBuilder();
    buf.add(_note(587, 120));
    buf.add(_silence(40));
    buf.add(_note(440, 200));
    return buf.toBytes();
  }

  Uint8List _note(double freq, double durationMs, {double amplitude = 0.35}) {
    final numSamples = (_sampleRate * durationMs / 1000).round();
    final data = Uint8List(numSamples * 2);
    final bd = ByteData.sublistView(data);

    final attackSamples = (_sampleRate * 0.008).round();
    final releaseSamples = (_sampleRate * 0.015).round();

    for (int i = 0; i < numSamples; i++) {
      final t = i / _sampleRate;

      double env = amplitude;
      if (i < attackSamples) {
        env *= i / attackSamples;
      } else if (i > numSamples - releaseSamples) {
        env *= (numSamples - i) / releaseSamples;
      }

      final sample =
          (sin(2 * pi * freq * t) * 0.8 + sin(2 * pi * freq * 2 * t) * 0.2) *
              env;
      final pcm = (sample * 32767).round().clamp(-32768, 32767);
      bd.setInt16(i * 2, pcm, Endian.little);
    }

    return data;
  }

  Uint8List _dualTone(double freq1, double freq2, double durationMs,
      {double amplitude = 0.35}) {
    final numSamples = (_sampleRate * durationMs / 1000).round();
    final data = Uint8List(numSamples * 2);
    final bd = ByteData.sublistView(data);

    final attackSamples = (_sampleRate * 0.005).round();
    final releaseSamples = (_sampleRate * 0.010).round();

    for (int i = 0; i < numSamples; i++) {
      final t = i / _sampleRate;

      double env = amplitude;
      if (i < attackSamples) {
        env *= i / attackSamples;
      } else if (i > numSamples - releaseSamples) {
        env *= (numSamples - i) / releaseSamples;
      }

      final sample = (sin(2 * pi * freq1 * t) * 0.5 +
              sin(2 * pi * freq2 * t) * 0.5) *
          env;
      final pcm = (sample * 32767).round().clamp(-32768, 32767);
      bd.setInt16(i * 2, pcm, Endian.little);
    }

    return data;
  }

  Uint8List _silence(double durationMs) {
    final numSamples = (_sampleRate * durationMs / 1000).round();
    return Uint8List(numSamples * 2);
  }

  static String ringToneName(RingTone tone) {
    switch (tone) {
      case RingTone.chime:
        return 'Chime';
      case RingTone.classic:
        return 'Classic';
      case RingTone.soft:
        return 'Soft';
      case RingTone.alert:
        return 'Alert';
      case RingTone.melody:
        return 'Melody';
    }
  }
}
