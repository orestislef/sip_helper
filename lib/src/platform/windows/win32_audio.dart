import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../../logging.dart';

// ── WinMM Constants ────────────────────────────────────────────────────

const int _waveFormatPcm = 1;
const int _callbackNull = 0x00000000;
const int _waveMapper = 0xFFFFFFFF; // (UINT)-1
const int _whdrDone = 0x00000001;
const int _whdrPrepared = 0x00000002;
const int _mmsyserrNoerror = 0;

// ── WinMM Structs ──────────────────────────────────────────────────────

final class WAVEFORMATEX extends Struct {
  @Uint16()
  external int wFormatTag;
  @Uint16()
  external int nChannels;
  @Uint32()
  external int nSamplesPerSec;
  @Uint32()
  external int nAvgBytesPerSec;
  @Uint16()
  external int nBlockAlign;
  @Uint16()
  external int wBitsPerSample;
  @Uint16()
  external int cbSize;
}

final class WAVEHDR extends Struct {
  external Pointer<Uint8> lpData;
  @Uint32()
  external int dwBufferLength;
  @Uint32()
  external int dwBytesRecorded;
  @IntPtr()
  external int dwUser;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int dwLoops;
  external Pointer<WAVEHDR> lpNext;
  @IntPtr()
  external int reserved;
}

// ── WinMM function bindings (lazily initialized) ───────────────────────

final DynamicLibrary _winmm = DynamicLibrary.open('winmm.dll');

// waveOut
final _waveOutOpen = _winmm.lookupFunction<
    Uint32 Function(Pointer<IntPtr>, Uint32, Pointer<WAVEFORMATEX>, IntPtr,
        IntPtr, Uint32),
    int Function(Pointer<IntPtr>, int, Pointer<WAVEFORMATEX>, int, int,
        int)>('waveOutOpen');

final _waveOutClose = _winmm
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveOutClose');

final _waveOutReset = _winmm
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveOutReset');

final _waveOutPrepareHeader = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int Function(int, Pointer<WAVEHDR>, int)>('waveOutPrepareHeader');

final _waveOutUnprepareHeader = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int Function(int, Pointer<WAVEHDR>, int)>('waveOutUnprepareHeader');

final _waveOutWrite = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int Function(int, Pointer<WAVEHDR>, int)>('waveOutWrite');

final _waveOutGetVolume = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<Uint32>),
    int Function(int, Pointer<Uint32>)>('waveOutGetVolume');

final _waveOutSetVolume = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Uint32),
    int Function(int, int)>('waveOutSetVolume');

// waveIn
final _waveInOpen = _winmm.lookupFunction<
    Uint32 Function(Pointer<IntPtr>, Uint32, Pointer<WAVEFORMATEX>, IntPtr,
        IntPtr, Uint32),
    int Function(Pointer<IntPtr>, int, Pointer<WAVEFORMATEX>, int, int,
        int)>('waveInOpen');

final _waveInClose = _winmm
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInClose');

final _waveInReset = _winmm
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInReset');

final _waveInStart = _winmm
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInStart');

final _waveInStop = _winmm
    .lookupFunction<Uint32 Function(IntPtr), int Function(int)>('waveInStop');

final _waveInPrepareHeader = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int Function(int, Pointer<WAVEHDR>, int)>('waveInPrepareHeader');

final _waveInUnprepareHeader = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int Function(int, Pointer<WAVEHDR>, int)>('waveInUnprepareHeader');

final _waveInAddBuffer = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int Function(int, Pointer<WAVEHDR>, int)>('waveInAddBuffer');

// Device enumeration
final _waveOutGetNumDevs = _winmm
    .lookupFunction<Uint32 Function(), int Function()>('waveOutGetNumDevs');

final _waveOutGetDevCapsW = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<Uint8>, Uint32),
    int Function(int, Pointer<Uint8>, int)>('waveOutGetDevCapsW');

final _waveInGetNumDevs = _winmm
    .lookupFunction<Uint32 Function(), int Function()>('waveInGetNumDevs');

final _waveInGetDevCapsW = _winmm.lookupFunction<
    Uint32 Function(IntPtr, Pointer<Uint8>, Uint32),
    int Function(int, Pointer<Uint8>, int)>('waveInGetDevCapsW');

// ── Device Enumeration Helper ─────────────────────────────────────────

class WinAudioDevices {
  static const int _capsNameOffset = 8;
  static const int _waveOutCapsSize = 84;
  static const int _waveInCapsSize = 80;

  static List<String> getOutputDevices() {
    final count = _waveOutGetNumDevs();
    final devices = <String>[];
    for (int i = 0; i < count; i++) {
      final caps = calloc<Uint8>(_waveOutCapsSize);
      try {
        final result = _waveOutGetDevCapsW(i, caps, _waveOutCapsSize);
        if (result == _mmsyserrNoerror) {
          final namePtr =
              Pointer<Utf16>.fromAddress(caps.address + _capsNameOffset);
          devices.add(namePtr.toDartString());
        }
      } finally {
        calloc.free(caps);
      }
    }
    return devices;
  }

  static List<String> getInputDevices() {
    final count = _waveInGetNumDevs();
    final devices = <String>[];
    for (int i = 0; i < count; i++) {
      final caps = calloc<Uint8>(_waveInCapsSize);
      try {
        final result = _waveInGetDevCapsW(i, caps, _waveInCapsSize);
        if (result == _mmsyserrNoerror) {
          final namePtr =
              Pointer<Utf16>.fromAddress(caps.address + _capsNameOffset);
          devices.add(namePtr.toDartString());
        }
      } finally {
        calloc.free(caps);
      }
    }
    return devices;
  }
}

// ── Helper: allocate WAVEFORMATEX for 8kHz 16-bit mono PCM ─────────────

Pointer<WAVEFORMATEX> _allocFormat({int sampleRate = 8000}) {
  final fmt = calloc<WAVEFORMATEX>();
  fmt.ref.wFormatTag = _waveFormatPcm;
  fmt.ref.nChannels = 1;
  fmt.ref.nSamplesPerSec = sampleRate;
  fmt.ref.wBitsPerSample = 16;
  fmt.ref.nBlockAlign = 2;
  fmt.ref.nAvgBytesPerSec = sampleRate * 2;
  fmt.ref.cbSize = 0;
  return fmt;
}

// ════════════════════════════════════════════════════════════════════════
// WinAudioPlayer — real-time PCM16 playback via waveOut
// ════════════════════════════════════════════════════════════════════════

class WinAudioPlayer {
  final int _numBuffers;
  final int _bufferSize;
  final int _sampleRate;
  final int _deviceId;

  WinAudioPlayer({
    int numBuffers = 16,
    int bufferSize = 320,
    int sampleRate = 8000,
    int deviceId = _waveMapper,
  })  : _numBuffers = numBuffers,
        _bufferSize = bufferSize,
        _sampleRate = sampleRate,
        _deviceId = deviceId;

  int _hWaveOut = 0;
  bool _isOpen = false;

  Pointer<WAVEFORMATEX>? _format;
  Pointer<IntPtr>? _handlePtr;
  final List<Pointer<WAVEHDR>> _headers = [];
  final List<Pointer<Uint8>> _dataPtrs = [];

  bool get isPlayerOpen => _isOpen;

  /// Count of buffers currently available for writing.
  int get freeBufferCount {
    int count = 0;
    for (final hdr in _headers) {
      if (hdr.ref.dwFlags & _whdrDone != 0) count++;
    }
    return count;
  }

  bool open() {
    if (_isOpen) return true;

    try {
      _format = _allocFormat(sampleRate: _sampleRate);
      _handlePtr = calloc<IntPtr>();

      final result = _waveOutOpen(
        _handlePtr!,
        _deviceId,
        _format!,
        0,
        0,
        _callbackNull,
      );

      if (result != _mmsyserrNoerror) {
        sipLog('[WinAudio:Play] waveOutOpen failed: error $result (device=$_deviceId)');
        _free();
        return false;
      }

      _hWaveOut = _handlePtr!.value;

      for (int i = 0; i < _numBuffers; i++) {
        final buf = calloc<Uint8>(_bufferSize);
        final hdr = calloc<WAVEHDR>();
        hdr.ref.lpData = buf;
        hdr.ref.dwBufferLength = _bufferSize;
        hdr.ref.dwFlags = 0;

        final r =
            _waveOutPrepareHeader(_hWaveOut, hdr, sizeOf<WAVEHDR>());
        if (r != _mmsyserrNoerror) {
          calloc.free(buf);
          calloc.free(hdr);
          continue;
        }

        hdr.ref.dwFlags |= _whdrDone;

        _headers.add(hdr);
        _dataPtrs.add(buf);
      }

      _isOpen = true;
      sipLog('[WinAudio:Play] Opened, ${_headers.length} buffers');
      return true;
    } catch (e) {
      sipLog('[WinAudio:Play] Open failed: $e');
      _free();
      return false;
    }
  }

  /// Flush all queued buffers (cancel pending playback) without closing.
  void reset() {
    if (!_isOpen) return;
    _waveOutReset(_hWaveOut);
    // After reset, all buffers are marked DONE
    for (final hdr in _headers) {
      hdr.ref.dwFlags = _whdrPrepared | _whdrDone;
    }
  }

  void write(Uint8List pcm16Data) {
    if (!_isOpen || pcm16Data.isEmpty) return;

    int offset = 0;
    while (offset < pcm16Data.length) {
      int idx = -1;
      for (int i = 0; i < _headers.length; i++) {
        if (_headers[i].ref.dwFlags & _whdrDone != 0) {
          idx = i;
          break;
        }
      }

      if (idx == -1) break;

      final hdr = _headers[idx];
      final buf = _dataPtrs[idx];
      final chunkSize =
          (pcm16Data.length - offset).clamp(0, _bufferSize);

      final view = buf.asTypedList(_bufferSize);
      view.setRange(0, chunkSize, pcm16Data, offset);

      hdr.ref.dwBufferLength = chunkSize;
      hdr.ref.dwFlags = _whdrPrepared;

      final r = _waveOutWrite(_hWaveOut, hdr, sizeOf<WAVEHDR>());
      if (r != _mmsyserrNoerror) {
        sipLog('[WinAudio:Play] waveOutWrite error $r on buffer $idx');
      }
      offset += chunkSize;
    }
  }

  /// Write data and return true if at least some data was written.
  bool writeWithStatus(Uint8List pcm16Data) {
    if (!_isOpen || pcm16Data.isEmpty) return false;

    bool wrote = false;
    int offset = 0;
    while (offset < pcm16Data.length) {
      int idx = -1;
      for (int i = 0; i < _headers.length; i++) {
        if (_headers[i].ref.dwFlags & _whdrDone != 0) {
          idx = i;
          break;
        }
      }

      if (idx == -1) break;

      final hdr = _headers[idx];
      final buf = _dataPtrs[idx];
      final chunkSize =
          (pcm16Data.length - offset).clamp(0, _bufferSize);

      final view = buf.asTypedList(_bufferSize);
      view.setRange(0, chunkSize, pcm16Data, offset);

      hdr.ref.dwBufferLength = chunkSize;
      hdr.ref.dwFlags = _whdrPrepared;

      final r = _waveOutWrite(_hWaveOut, hdr, sizeOf<WAVEHDR>());
      if (r != _mmsyserrNoerror) {
        sipLog('[WinAudio:Play] waveOutWrite error $r on buffer $idx');
      } else {
        wrote = true;
      }
      offset += chunkSize;
    }
    return wrote;
  }

  /// Get current volume (0x0000-0xFFFF per channel, packed left/right)
  int getVolume() {
    if (!_isOpen) return 0;
    final vol = calloc<Uint32>();
    try {
      _waveOutGetVolume(_hWaveOut, vol);
      return vol.value;
    } finally {
      calloc.free(vol);
    }
  }

  /// Set volume to max (0xFFFF for both channels)
  void setMaxVolume() {
    if (!_isOpen) return;
    final r = _waveOutSetVolume(_hWaveOut, 0xFFFFFFFF);
    if (r != _mmsyserrNoerror) {
      sipLog('[WinAudio:Play] waveOutSetVolume failed: $r');
    }
  }

  void close() {
    if (!_isOpen) return;
    _isOpen = false;

    try {
      _waveOutReset(_hWaveOut);
      for (final hdr in _headers) {
        _waveOutUnprepareHeader(_hWaveOut, hdr, sizeOf<WAVEHDR>());
      }
      _waveOutClose(_hWaveOut);
    } catch (e) {
      sipLog('[WinAudio:Play] Close error: $e');
    }

    _hWaveOut = 0;
    _free();
    sipLog('[WinAudio:Play] Closed');
  }

  void _free() {
    for (final p in _dataPtrs) {
      calloc.free(p);
    }
    for (final h in _headers) {
      calloc.free(h);
    }
    _dataPtrs.clear();
    _headers.clear();
    if (_format != null) {
      calloc.free(_format!);
      _format = null;
    }
    if (_handlePtr != null) {
      calloc.free(_handlePtr!);
      _handlePtr = null;
    }
  }
}

// ════════════════════════════════════════════════════════════════════════
// WinAudioRecorder — real-time PCM16 capture via waveIn
// ════════════════════════════════════════════════════════════════════════

class WinAudioRecorder {
  static const int _numBuffers = 8;
  static const int _bufferSize = 320; // 20ms at 8kHz 16-bit mono
  final int _deviceId;

  WinAudioRecorder({int deviceId = _waveMapper}) : _deviceId = deviceId;

  int _hWaveIn = 0;
  bool _isOpen = false;
  Timer? _pollTimer;

  Pointer<WAVEFORMATEX>? _format;
  Pointer<IntPtr>? _handlePtr;
  final List<Pointer<WAVEHDR>> _headers = [];
  final List<Pointer<Uint8>> _dataPtrs = [];

  void Function(Uint8List pcm16Data)? onData;

  bool open() {
    if (_isOpen) return true;

    try {
      _format = _allocFormat();
      _handlePtr = calloc<IntPtr>();

      final result = _waveInOpen(
        _handlePtr!,
        _deviceId,
        _format!,
        0,
        0,
        _callbackNull,
      );

      if (result != _mmsyserrNoerror) {
        sipLog('[WinAudio:Rec] waveInOpen failed: error $result (device=$_deviceId)');
        _free();
        return false;
      }

      _hWaveIn = _handlePtr!.value;

      for (int i = 0; i < _numBuffers; i++) {
        final buf = calloc<Uint8>(_bufferSize);
        final hdr = calloc<WAVEHDR>();
        hdr.ref.lpData = buf;
        hdr.ref.dwBufferLength = _bufferSize;
        hdr.ref.dwFlags = 0;

        final r =
            _waveInPrepareHeader(_hWaveIn, hdr, sizeOf<WAVEHDR>());
        if (r != _mmsyserrNoerror) {
          calloc.free(buf);
          calloc.free(hdr);
          continue;
        }

        _waveInAddBuffer(_hWaveIn, hdr, sizeOf<WAVEHDR>());
        _headers.add(hdr);
        _dataPtrs.add(buf);
      }

      final startResult = _waveInStart(_hWaveIn);
      if (startResult != _mmsyserrNoerror) {
        sipLog('[WinAudio:Rec] waveInStart failed: error $startResult');
        close();
        return false;
      }

      _isOpen = true;

      _pollTimer =
          Timer.periodic(const Duration(milliseconds: 10), _pollBuffers);

      sipLog('[WinAudio:Rec] Opened, ${_headers.length} buffers');
      return true;
    } catch (e) {
      sipLog('[WinAudio:Rec] Open failed: $e');
      _free();
      return false;
    }
  }

  void _pollBuffers(Timer _) {
    if (!_isOpen) return;

    for (int i = 0; i < _headers.length; i++) {
      final hdr = _headers[i];
      if (hdr.ref.dwFlags & _whdrDone != 0) {
        final recorded = hdr.ref.dwBytesRecorded;
        if (recorded > 0) {
          final data =
              Uint8List.fromList(hdr.ref.lpData.asTypedList(recorded));
          onData?.call(data);
        }

        hdr.ref.dwFlags &= ~_whdrDone;
        hdr.ref.dwBytesRecorded = 0;
        _waveInAddBuffer(_hWaveIn, hdr, sizeOf<WAVEHDR>());
      }
    }
  }

  void close() {
    if (!_isOpen) return;
    _isOpen = false;

    _pollTimer?.cancel();
    _pollTimer = null;

    try {
      _waveInStop(_hWaveIn);
      _waveInReset(_hWaveIn);
      for (final hdr in _headers) {
        _waveInUnprepareHeader(_hWaveIn, hdr, sizeOf<WAVEHDR>());
      }
      _waveInClose(_hWaveIn);
    } catch (e) {
      sipLog('[WinAudio:Rec] Close error: $e');
    }

    _hWaveIn = 0;
    _free();
    sipLog('[WinAudio:Rec] Closed');
  }

  void _free() {
    for (final p in _dataPtrs) {
      calloc.free(p);
    }
    for (final h in _headers) {
      calloc.free(h);
    }
    _dataPtrs.clear();
    _headers.clear();
    if (_format != null) {
      calloc.free(_format!);
      _format = null;
    }
    if (_handlePtr != null) {
      calloc.free(_handlePtr!);
      _handlePtr = null;
    }
  }
}
