import 'dart:typed_data';

/// Platform-neutral default device ID.
///
/// Each platform backend maps this to its native default device constant
/// (e.g., WAVE_MAPPER on Windows).
const int defaultAudioDeviceId = -1;

/// Abstract interface for PCM16 audio playback.
abstract class AudioPlayer {
  /// Whether the player is currently open and ready to accept audio data.
  bool get isPlayerOpen;

  /// Number of internal buffers currently available for writing.
  int get freeBufferCount;

  /// Open the audio output device. Returns true on success.
  bool open();

  /// Write PCM16 mono audio data to the output.
  void write(Uint8List pcm16Data);

  /// Write PCM16 data and return true if at least some data was enqueued.
  bool writeWithStatus(Uint8List pcm16Data);

  /// Flush all queued buffers without closing the device.
  void reset();

  /// Close the audio output device and release resources.
  void close();

  /// Get current volume as a platform-specific packed integer.
  int getVolume();

  /// Set output volume to maximum.
  void setMaxVolume();
}

/// Abstract interface for PCM16 audio capture.
abstract class AudioRecorder {
  /// Callback invoked when PCM16 audio data is captured.
  void Function(Uint8List pcm16Data)? onData;

  /// Open the audio input device and begin capture. Returns true on success.
  bool open();

  /// Stop capture and close the audio input device.
  void close();
}

/// Abstract interface for enumerating audio devices.
abstract class AudioDevices {
  /// List available output (playback) device names. Index = device ID.
  List<String> getOutputDevices();

  /// List available input (capture) device names. Index = device ID.
  List<String> getInputDevices();
}

/// Factory function type for creating an [AudioPlayer].
typedef AudioPlayerFactory = AudioPlayer Function({
  int numBuffers,
  int bufferSize,
  int sampleRate,
  int deviceId,
});

/// Factory function type for creating an [AudioRecorder].
typedef AudioRecorderFactory = AudioRecorder Function({int deviceId});
