import 'dart:collection';
import 'dart:io';

import '../logging.dart';

/// Sends datagrams in order and never drops one because the socket was busy.
///
/// `RawDatagramSocket.send` returns 0 when the socket cannot take the
/// datagram right now. On Windows that happens on almost every back-to-back
/// send (100 Trying + 180 Ringing, ACK + BYE, DTMF end packets), and the
/// datagram is silently lost. Unsent datagrams are queued here and flushed
/// on the next write event.
class DatagramSender {
  final RawDatagramSocket socket;
  final int maxQueue;
  final Queue<(List<int>, InternetAddress, int)> _queue = Queue();

  DatagramSender(this.socket, {this.maxQueue = 256});

  /// Datagrams waiting for the socket.
  int get pending => _queue.length;

  void send(List<int> data, InternetAddress address, int port) {
    if (_queue.isEmpty && _trySend(data, address, port)) return;
    if (_queue.length >= maxQueue) _queue.removeFirst();
    _queue.add((data, address, port));
    _armWrite();
  }

  /// Call on every [RawSocketEvent.write].
  void onWrite() {
    while (_queue.isNotEmpty) {
      final (data, address, port) = _queue.first;
      if (!_trySend(data, address, port)) {
        _armWrite();
        return;
      }
      _queue.removeFirst();
    }
  }

  void clear() => _queue.clear();

  bool _trySend(List<int> data, InternetAddress address, int port) {
    try {
      return socket.send(data, address, port) > 0;
    } on SocketException catch (e) {
      // Network down or unreachable: drop it, retransmissions recover.
      sipLog('[NET] Send to ${address.address}:$port failed: ${e.message}');
      return true;
    }
  }

  void _armWrite() {
    try {
      socket.writeEventsEnabled = true;
    } catch (_) {}
  }
}
