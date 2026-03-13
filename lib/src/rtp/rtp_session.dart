import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../logging.dart';

/// Native RTP audio handler without WebRTC.
/// Handles plain RTP/AVP audio for Asterisk compatibility.
class RtpSession {
  static final RtpSession instance = RtpSession._internal();
  RtpSession._internal();

  RawDatagramSocket? _rtpSocket;
  int? _localRtpPort;
  String? _remoteHost;
  int? _remotePort;

  // RTP state
  int _sequenceNumber = 0;
  int _timestamp = 0;
  final int _ssrc = DateTime.now().millisecondsSinceEpoch & 0xFFFFFFFF;

  // Audio state
  bool _isActive = false;
  bool get isActive => _isActive;

  // Packet counter for periodic logging
  int _rxCount = 0;
  int _txCount = 0;

  // Callbacks
  Function(Uint8List audioData)? onAudioReceived;
  Function(String error)? onError;

  /// Initialize RTP socket.
  Future<void> initialize({String? localIp}) async {
    if (_rtpSocket != null) {
      close();
    }

    try {
      _rtpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _localRtpPort = _rtpSocket!.port;
      sipLog('[RTP] Socket bound to port $_localRtpPort');

      _rtpSocket!.listen(
        (event) {
          if (event == RawSocketEvent.read) {
            try {
              _handleIncomingPacket();
            } catch (e) {
              if (_rxCount % 100 == 0) {
                sipLog('[RTP] Receive error: $e');
              }
            }
          }
        },
        onError: (error) {
          sipLog('[RTP] Socket error: $error');
        },
      );

      _isActive = true;
      _rxCount = 0;
      _txCount = 0;
    } catch (e) {
      sipLog('[RTP] Failed to initialize: $e');
      onError?.call('Failed to initialize RTP: $e');
      rethrow;
    }
  }

  int? get localPort => _localRtpPort;

  void setRemoteEndpoint(String host, int port) {
    _remoteHost = host;
    _remotePort = port;
    sipLog('[RTP] Remote endpoint set to $host:$port');
  }

  void _handleIncomingPacket() {
    final datagram = _rtpSocket!.receive();
    if (datagram == null) return;

    try {
      final data = datagram.data;
      _rxCount++;

      if (_rxCount <= 3 || _rxCount % 500 == 0) {
        sipLog('[RTP] Received packet #$_rxCount, ${data.length} bytes from ${datagram.address.address}:${datagram.port}');
      }

      if (data.length < 12) return;

      final padding = (data[0] >> 5) & 0x01;
      final extension = (data[0] >> 4) & 0x01;
      final csrcCount = data[0] & 0x0F;

      int headerLength = 12 + (csrcCount * 4);
      if (extension == 1 && data.length >= headerLength + 4) {
        final extLength =
            ((data[headerLength + 2] << 8) | data[headerLength + 3]) * 4;
        headerLength += 4 + extLength;
      }

      int payloadLength = data.length - headerLength;
      if (padding == 1 && payloadLength > 0) {
        payloadLength -= data[data.length - 1];
      }

      if (payloadLength > 0 && headerLength + payloadLength <= data.length) {
        final audioPayload = Uint8List.sublistView(
            data, headerLength, headerLength + payloadLength);

        onAudioReceived?.call(audioPayload);
      }
    } catch (e) {
      if (_rxCount % 100 == 0) {
        sipLog('[RTP] Packet processing error: $e');
      }
    }
  }

  void sendAudio(Uint8List audioData, int payloadType) {
    if (_rtpSocket == null || _remoteHost == null || _remotePort == null) {
      return;
    }

    try {
      final packet = BytesBuilder();

      packet.addByte(0x80);
      packet.addByte(payloadType & 0x7F);

      packet.addByte((_sequenceNumber >> 8) & 0xFF);
      packet.addByte(_sequenceNumber & 0xFF);
      _sequenceNumber = (_sequenceNumber + 1) & 0xFFFF;

      packet.addByte((_timestamp >> 24) & 0xFF);
      packet.addByte((_timestamp >> 16) & 0xFF);
      packet.addByte((_timestamp >> 8) & 0xFF);
      packet.addByte(_timestamp & 0xFF);

      packet.addByte((_ssrc >> 24) & 0xFF);
      packet.addByte((_ssrc >> 16) & 0xFF);
      packet.addByte((_ssrc >> 8) & 0xFF);
      packet.addByte(_ssrc & 0xFF);

      packet.add(audioData);

      final address = InternetAddress(_remoteHost!);
      _rtpSocket!.send(packet.toBytes(), address, _remotePort!);

      _txCount++;
      _timestamp = (_timestamp + 160) & 0xFFFFFFFF;

      if (_txCount <= 3 || _txCount % 500 == 0) {
        sipLog('[RTP] Sent packet #$_txCount to $_remoteHost:$_remotePort');
      }
    } catch (e) {
      if (_txCount % 100 == 0) {
        sipLog('[RTP] Send error: $e');
      }
    }
  }

  void close() {
    sipLog('[RTP] Closing. Received: $_rxCount packets, Sent: $_txCount packets');
    _rtpSocket?.close();
    _rtpSocket = null;
    _localRtpPort = null;
    _remoteHost = null;
    _remotePort = null;
    _isActive = false;
    _sequenceNumber = 0;
    _timestamp = 0;
    _rxCount = 0;
    _txCount = 0;
  }
}
