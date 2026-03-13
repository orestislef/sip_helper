import 'package:sip_helper/sip_helper.dart';

void main() async {
  // Optional: receive log output
  sipLogger = print;

  // 1. Configure SIP account
  final config = SipConfiguration(
    server: 'pbx.example.com',
    username: '1001',
    password: 'secret',
    displayName: 'John Doe',
    port: 5060,
  );

  // 2. Initialize the helper (wires SIP + RTP + audio together)
  final sip = SipHelper.instance;
  await sip.initialize(config);

  // 3. Listen for events
  sip.connectionStateStream.listen((connected) {
    print('SIP registered: $connected');
  });

  sip.incomingCallStream.listen((call) {
    print('Incoming call from ${call.callerNumber}');
    // Answer automatically after 1 second
    Future.delayed(Duration(seconds: 1), () {
      sip.answerCall(call.callId!);
    });
  });

  sip.callStateStream.listen((event) {
    print('Call state: $event');
  });

  sip.errorStream.listen((error) {
    print('Error: $error');
  });

  // 4. Connect (registers with the SIP server)
  await sip.connect();

  // 5. Make an outgoing call
  // await sip.makeCall('1002');

  // 6. Hang up
  // await sip.hangupCall(callId);

  // 7. Adjust audio
  sip.soundService.setOutputGain(5.0);   // 500% output gain
  sip.microphoneService.setInputGain(1.0); // 100% input gain

  // 8. Audio device selection (Windows)
  final outputs = WinAudioDevices.getOutputDevices();
  for (int i = 0; i < outputs.length; i++) {
    print('Output [$i]: ${outputs[i]}');
  }
  final inputs = WinAudioDevices.getInputDevices();
  for (int i = 0; i < inputs.length; i++) {
    print('Input [$i]: ${inputs[i]}');
  }

  // Keep running...
  print('SIP helper running. Press Ctrl+C to exit.');
}
