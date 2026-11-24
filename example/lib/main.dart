import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:sip_helper/sip_helper.dart';

void main() {
  sipLogger = debugPrint;
  runApp(const SoftphoneApp());
}

class SoftphoneApp extends StatelessWidget {
  const SoftphoneApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'sip_helper',
      theme: ThemeData(colorSchemeSeed: Colors.teal, useMaterial3: true),
      home: const SoftphonePage(),
    );
  }
}

class SoftphonePage extends StatefulWidget {
  const SoftphonePage({super.key});

  @override
  State<SoftphonePage> createState() => _SoftphonePageState();
}

class _SoftphonePageState extends State<SoftphonePage> {
  final sip = SipHelper.instance;
  final _server = TextEditingController(text: '192.168.1.10');
  final _port = TextEditingController(text: '5060');
  final _user = TextEditingController(text: '1001');
  final _password = TextEditingController();
  final _dial = TextEditingController();
  final List<StreamSubscription<dynamic>> _subs = [];
  bool _registered = false;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _subs.add(sip.connectionStateStream.listen((registered) {
      setState(() => _registered = registered);
    }));
    _subs.add(sip.incomingCallStream.listen((_) => setState(() {})));
    _subs.add(sip.callEventStream.listen((e) {
      setState(() => _status = '${e.call?.displayName ?? e.callId}: ${e.event.name}');
    }));
    _subs.add(sip.errorStream.listen((error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }));
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _connect() async {
    setState(() => _busy = true);
    try {
      if (_registered) {
        await sip.disconnect();
      } else {
        await sip.initialize(SipConfiguration(
          server: _server.text.trim(),
          port: int.tryParse(_port.text) ?? 5060,
          username: _user.text.trim(),
          password: _password.text,
        ));
        await sip.requestMicrophonePermission();
        await sip.connect();
      }
    } catch (_) {
      // Shown through errorStream.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _call() async {
    final number = _dial.text.trim();
    if (number.isEmpty) return;
    try {
      await sip.makeCall(number);
    } catch (_) {}
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final calls = sip.calls.values.toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text('sip_helper softphone'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Icon(Icons.circle,
                size: 14, color: _registered ? Colors.green : Colors.grey),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!_registered) ...[
            _field(_server, 'Server'),
            _field(_port, 'Port', number: true),
            _field(_user, 'Extension'),
            _field(_password, 'Password', obscure: true),
          ],
          FilledButton(
            onPressed: _busy ? null : _connect,
            child: Text(_registered ? 'Disconnect' : 'Register'),
          ),
          const SizedBox(height: 24),
          Row(children: [
            Expanded(child: _field(_dial, 'Number to call', number: true)),
            const SizedBox(width: 8),
            IconButton.filled(
              onPressed: _registered ? _call : null,
              icon: const Icon(Icons.call),
            ),
          ]),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(_status!, style: Theme.of(context).textTheme.bodySmall),
            ),
          for (final call in calls) _CallCard(call: call, onChanged: () => setState(() {})),
        ],
      ),
    );
  }

  Widget _field(TextEditingController c, String label,
      {bool number = false, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        controller: c,
        obscureText: obscure,
        keyboardType: number ? TextInputType.phone : TextInputType.text,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      ),
    );
  }
}

class _CallCard extends StatelessWidget {
  final CallInfo call;
  final VoidCallback onChanged;

  const _CallCard({required this.call, required this.onChanged});

  SipHelper get sip => SipHelper.instance;

  @override
  Widget build(BuildContext context) {
    final id = call.callId!;
    final ringingIn =
        call.state == CallState.ringing && call.direction == CallDirection.incoming;
    final live = call.state == CallState.active || call.state == CallState.onHold;
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(call.displayName, style: Theme.of(context).textTheme.titleMedium),
            Text([
              call.direction == CallDirection.incoming ? 'Incoming' : 'Outgoing',
              call.stateText,
              if (call.isRemoteHold) 'held by other side',
            ].join(' / ')),
            const SizedBox(height: 8),
            Wrap(spacing: 8, runSpacing: 8, children: [
              if (ringingIn)
                FilledButton.icon(
                  onPressed: () => sip.answerCall(id),
                  icon: const Icon(Icons.call),
                  label: const Text('Answer'),
                ),
              if (live)
                OutlinedButton(
                  onPressed: () async {
                    if (call.state == CallState.onHold) {
                      await sip.unholdCall(id);
                    } else {
                      await sip.holdCall(id);
                    }
                    onChanged();
                  },
                  child: Text(call.state == CallState.onHold ? 'Resume' : 'Hold'),
                ),
              if (live)
                OutlinedButton(
                  onPressed: () {
                    sip.setMuted(!sip.isMuted);
                    onChanged();
                  },
                  child: Text(sip.isMuted ? 'Unmute' : 'Mute'),
                ),
              if (live)
                OutlinedButton(
                  onPressed: () async {
                    await sip.setSpeakerphone(!sip.isSpeakerphoneOn);
                    onChanged();
                  },
                  child: Text(sip.isSpeakerphoneOn ? 'Earpiece' : 'Speaker'),
                ),
              if (live)
                OutlinedButton(
                  onPressed: () => _keypad(context, id),
                  child: const Text('Keypad'),
                ),
              if (live)
                OutlinedButton(
                  onPressed: () => _transfer(context, id),
                  child: const Text('Transfer'),
                ),
              FilledButton.tonalIcon(
                style: FilledButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () => sip.hangupCall(id),
                icon: const Icon(Icons.call_end),
                label: Text(ringingIn ? 'Decline' : 'Hang up'),
              ),
            ]),
          ],
        ),
      ),
    );
  }

  void _keypad(BuildContext context, String id) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        padding: const EdgeInsets.all(16),
        childAspectRatio: 2,
        children: [
          for (final k in keys)
            TextButton(
              onPressed: () => sip.sendDtmf(id, k),
              child: Text(k, style: const TextStyle(fontSize: 24)),
            ),
        ],
      ),
    );
  }

  Future<void> _transfer(BuildContext context, String id) async {
    final controller = TextEditingController();
    final target = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Transfer to'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.phone,
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('Transfer'),
          ),
        ],
      ),
    );
    if (target != null && target.isNotEmpty) await sip.transferCall(id, target);
  }
}
