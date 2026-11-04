import AVFoundation
import Flutter
import UIKit

/// Native call audio for sip_helper on iOS.
///
/// One AVAudioEngine does both directions. Playback goes through an
/// AVAudioPlayerNode fed with 16-bit mono PCM from Dart. Capture taps the
/// input node with voice processing on (echo cancellation, noise
/// suppression) and sends 8 kHz 16-bit mono frames to Dart.
///
/// Outside a call the session is `soloAmbient` (ring tone, respects the
/// silent switch) and is only active while something plays. During a call
/// it is `playAndRecord` / `voiceChat`.
public class SipHelperPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var engine = AVAudioEngine()
  private var playerNode = AVAudioPlayerNode()
  private var playerAttached = false
  private var playerFormat: AVAudioFormat?
  private var playerRate: Double = 16000
  private var playerOpen = false

  private var recorderOpen = false
  private var tapInstalled = false
  private var voiceProcessing = false
  private let micFormat = AVAudioFormat(
    commonFormat: .pcmFormatInt16, sampleRate: 8000, channels: 1, interleaved: true)!
  private var micSink: FlutterEventSink?

  private var callActive = false
  private var speakerOn = false

  private let queueLock = NSLock()
  private var queuedFrames: Int64 = 0
  private var queueGeneration = 0
  private var idleWork: DispatchWorkItem?
  private var observers: [NSObjectProtocol] = []
  private var engineObserver: NSObjectProtocol?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = SipHelperPlugin()
    let channel = FlutterMethodChannel(
      name: "sip_helper/audio", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: channel)
    let events = FlutterEventChannel(
      name: "sip_helper/audio/mic", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    instance.observeSystemEvents()
  }

  // MARK: Method calls

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "hasPermission":
      result(currentPermission() == .granted)
    case "requestPermission":
      requestPermission { granted in result(granted) }
    case "openPlayer":
      if let rate = args?["sampleRate"] as? Int, rate > 0 {
        playerRate = Double(rate)
      }
      playerOpen = true
      result(true)
    case "write":
      if let data = call.arguments as? FlutterStandardTypedData {
        write(data.data)
      }
      result(nil)
    case "resetPlayer":
      resetPlayer()
      result(nil)
    case "closePlayer":
      closePlayer()
      result(nil)
    case "openRecorder":
      requestPermission { [weak self] granted in
        guard let self = self, granted else {
          result(false)
          return
        }
        result(self.startRecorder())
      }
    case "closeRecorder":
      stopRecorder()
      result(nil)
    case "startSession":
      speakerOn = (args?["speaker"] as? Bool) ?? false
      startSession()
      result(nil)
    case "stopSession":
      stopSession()
      result(nil)
    case "setSpeaker":
      speakerOn = (args?["on"] as? Bool) ?? false
      applyRoute()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: Event channel

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink)
    -> FlutterError?
  {
    micSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    micSink = nil
    return nil
  }

  // MARK: Permission

  private enum Permission {
    case granted, denied, undetermined
  }

  private func currentPermission() -> Permission {
    if #available(iOS 17.0, *) {
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return .granted
      case .denied: return .denied
      default: return .undetermined
      }
    } else {
      switch AVAudioSession.sharedInstance().recordPermission {
      case .granted: return .granted
      case .denied: return .denied
      default: return .undetermined
      }
    }
  }

  private func requestPermission(_ done: @escaping (Bool) -> Void) {
    switch currentPermission() {
    case .granted:
      done(true)
    case .denied:
      done(false)
    case .undetermined:
      let finish: (Bool) -> Void = { granted in
        DispatchQueue.main.async { done(granted) }
      }
      if #available(iOS 17.0, *) {
        AVAudioApplication.requestRecordPermission(completionHandler: finish)
      } else {
        AVAudioSession.sharedInstance().requestRecordPermission(finish)
      }
    }
  }

  // MARK: Session

  private func configureSession() {
    let session = AVAudioSession.sharedInstance()
    do {
      if callActive || recorderOpen {
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth])
        try? session.setPreferredIOBufferDuration(0.02)
      } else {
        try session.setCategory(.soloAmbient, mode: .default, options: [])
      }
      try session.setActive(true)
    } catch {
      NSLog("[sip_helper] Audio session error: \(error)")
    }
  }

  private func deactivateSession() {
    do {
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    } catch {
      NSLog("[sip_helper] Audio session deactivate error: \(error)")
    }
  }

  private func startSession() {
    idleWork?.cancel()
    let wasRunning = engine.isRunning
    flushPlayer()
    if wasRunning { engine.stop() }
    callActive = true
    configureSession()
    applyRoute()
    if wasRunning { _ = startEngine() }
  }

  private func stopSession() {
    guard callActive else { return }
    callActive = false
    speakerOn = false
    setProximity(false)
    flushPlayer()
    if recorderOpen {
      // With the call flag cleared this also stops the engine, turns voice
      // processing off and releases the session.
      stopRecorder()
    } else {
      engine.stop()
      disableVoiceProcessing()
      deactivateSession()
    }
    try? AVAudioSession.sharedInstance().overrideOutputAudioPort(.none)
  }

  private func applyRoute() {
    guard callActive else { return }
    do {
      try AVAudioSession.sharedInstance().overrideOutputAudioPort(speakerOn ? .speaker : .none)
    } catch {
      NSLog("[sip_helper] Route error: \(error)")
    }
    setProximity(!speakerOn)
  }

  /// Turn the screen off when the phone is held to the ear.
  private func setProximity(_ on: Bool) {
    let enable = on && callActive
    DispatchQueue.main.async {
      UIDevice.current.isProximityMonitoringEnabled = enable
    }
  }

  // MARK: Engine

  private func ensurePlayerGraph() {
    if !playerAttached {
      engine.attach(playerNode)
      playerAttached = true
    }
    if playerFormat == nil || playerFormat!.sampleRate != playerRate {
      guard let format = AVAudioFormat(standardFormatWithSampleRate: playerRate, channels: 1)
      else { return }
      if playerFormat != nil {
        engine.disconnectNodeOutput(playerNode)
      }
      engine.connect(playerNode, to: engine.mainMixerNode, format: format)
      playerFormat = format
    }
  }

  @discardableResult
  private func startEngine() -> Bool {
    ensurePlayerGraph()
    if !engine.isRunning {
      engine.prepare()
      do {
        try engine.start()
      } catch {
        NSLog("[sip_helper] Engine start failed: \(error)")
        return false
      }
    }
    if playerOpen && !playerNode.isPlaying {
      playerNode.play()
    }
    return true
  }

  private func enableVoiceProcessing() {
    guard !voiceProcessing else { return }
    do {
      try engine.inputNode.setVoiceProcessingEnabled(true)
      voiceProcessing = true
      reconnectOutput()
    } catch {
      NSLog("[sip_helper] Voice processing unavailable: \(error)")
    }
  }

  private func disableVoiceProcessing() {
    guard voiceProcessing else { return }
    try? engine.inputNode.setVoiceProcessingEnabled(false)
    voiceProcessing = false
    reconnectOutput()
  }

  /// Turning voice processing on or off can change the output hardware
  /// format; the mixer to output connection has to follow it.
  private func reconnectOutput() {
    let format = engine.outputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else { return }
    engine.connect(engine.mainMixerNode, to: engine.outputNode, format: format)
  }

  /// Stop the player and forget everything queued.
  private func flushPlayer() {
    if playerAttached { playerNode.stop() }
    resetQueue()
  }

  // MARK: Player

  private func write(_ data: Data) {
    guard playerOpen, data.count >= 2 else { return }
    if !engine.isRunning {
      configureSession()
      guard startEngine() else { return }
    }
    if !playerNode.isPlaying { playerNode.play() }
    guard let format = playerFormat else { return }

    let frames = data.count / 2
    queueLock.lock()
    let queued = queuedFrames
    let generation = queueGeneration
    queueLock.unlock()
    // More than three seconds waiting means playback stalled: drop instead
    // of building up delay.
    if queued > Int64(playerRate * 3) { return }

    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
      let out = buffer.floatChannelData?[0]
    else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for i in 0..<frames {
        let lo = UInt16(raw[i * 2])
        let hi = UInt16(raw[i * 2 + 1])
        out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768.0
      }
    }

    queueLock.lock()
    queuedFrames += Int64(frames)
    queueLock.unlock()
    playerNode.scheduleBuffer(buffer) { [weak self] in
      guard let self = self else { return }
      self.queueLock.lock()
      if self.queueGeneration == generation {
        self.queuedFrames = max(0, self.queuedFrames - Int64(frames))
      }
      self.queueLock.unlock()
    }
    scheduleIdleStop(after: Double(queued + Int64(frames)) / playerRate + 2.0)
  }

  private func resetQueue() {
    queueLock.lock()
    queuedFrames = 0
    queueGeneration += 1
    queueLock.unlock()
  }

  private func resetPlayer() {
    guard playerAttached else { return }
    playerNode.stop()
    resetQueue()
    if engine.isRunning && playerOpen {
      playerNode.play()
    }
  }

  private func closePlayer() {
    playerOpen = false
    idleWork?.cancel()
    if playerAttached { playerNode.stop() }
    resetQueue()
    if !recorderOpen && !callActive && engine.isRunning {
      engine.stop()
      deactivateSession()
    }
  }

  /// Outside a call, release the audio session once the queued sound has
  /// played, so other apps' audio comes back.
  private func scheduleIdleStop(after seconds: Double) {
    idleWork?.cancel()
    guard !callActive && !recorderOpen else { return }
    let work = DispatchWorkItem { [weak self] in self?.stopEngineIfIdle() }
    idleWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
  }

  private func stopEngineIfIdle() {
    guard !callActive && !recorderOpen else { return }
    queueLock.lock()
    let queued = queuedFrames
    queueLock.unlock()
    if queued > 0 {
      scheduleIdleStop(after: 1.0)
      return
    }
    if playerAttached { playerNode.stop() }
    if engine.isRunning {
      engine.stop()
      deactivateSession()
    }
  }

  // MARK: Recorder

  private func startRecorder() -> Bool {
    if recorderOpen { return true }
    idleWork?.cancel()
    recorderOpen = true
    if engine.isRunning { engine.stop() }
    configureSession()
    enableVoiceProcessing()
    guard installTap(), startEngine() else {
      removeTap()
      recorderOpen = false
      return false
    }
    return true
  }

  private func installTap() -> Bool {
    let input = engine.inputNode
    if tapInstalled {
      input.removeTap(onBus: 0)
      tapInstalled = false
    }
    let format = input.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      NSLog("[sip_helper] No microphone input available")
      return false
    }
    guard let converter = AVAudioConverter(from: format, to: micFormat) else {
      NSLog("[sip_helper] No converter from \(format) to 8 kHz")
      return false
    }
    converter.downmix = true
    let target = micFormat
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
      guard let bytes = SipHelperPlugin.convert(buffer, with: converter, to: target) else {
        return
      }
      DispatchQueue.main.async {
        guard let self = self, self.recorderOpen, let sink = self.micSink else { return }
        sink(FlutterStandardTypedData(bytes: bytes))
      }
    }
    tapInstalled = true
    return true
  }

  private func removeTap() {
    if tapInstalled {
      engine.inputNode.removeTap(onBus: 0)
      tapInstalled = false
    }
  }

  /// Runs on the audio thread: convert one tap buffer to 8 kHz mono PCM16.
  private static func convert(
    _ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat
  ) -> Data? {
    guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return nil }
    let ratio = format.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
      return nil
    }
    var consumed = false
    var error: NSError?
    let status = converter.convert(to: out, error: &error) { _, inputStatus in
      if consumed {
        inputStatus.pointee = .noDataNow
        return nil
      }
      consumed = true
      inputStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let channel = out.int16ChannelData else {
      return nil
    }
    return Data(bytes: channel[0], count: Int(out.frameLength) * 2)
  }

  private func stopRecorder() {
    guard recorderOpen else { return }
    recorderOpen = false
    removeTap()
    if !callActive {
      // No call: give the microphone back completely.
      engine.stop()
      disableVoiceProcessing()
      deactivateSession()
    }
  }

  // MARK: System events

  private func observeSystemEvents() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: nil, queue: .main
      ) { [weak self] note in
        self?.handleInterruption(note)
      })
    observers.append(
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main
      ) { [weak self] _ in
        self?.rebuildEngine()
      })
    observeEngine()
  }

  private func observeEngine() {
    if let old = engineObserver {
      NotificationCenter.default.removeObserver(old)
    }
    engineObserver = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
    ) { [weak self] _ in
      self?.restartAfterChange()
    }
  }

  /// After a media services reset the old engine and nodes are dead: build
  /// new ones and bring back whatever was running.
  private func rebuildEngine() {
    engine = AVAudioEngine()
    playerNode = AVAudioPlayerNode()
    playerAttached = false
    playerFormat = nil
    tapInstalled = false
    voiceProcessing = false
    resetQueue()
    observeEngine()
    restartAfterChange()
  }

  private func handleInterruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }
    if type == .ended {
      restartAfterChange()
    }
  }

  /// Route changes (Bluetooth, headset) and interruptions stop the engine;
  /// bring it back while a call or the microphone needs it.
  private func restartAfterChange() {
    guard callActive || recorderOpen else { return }
    flushPlayer()
    if engine.isRunning { engine.stop() }
    configureSession()
    if recorderOpen {
      enableVoiceProcessing()
      if !installTap() {
        NSLog("[sip_helper] Microphone lost after audio route change")
      }
    }
    startEngine()
    applyRoute()
  }
}
