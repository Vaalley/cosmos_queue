import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:web_socket_channel/web_socket_channel.dart';

class WebSocketHandler {
  final Set<WebSocket> _clients = {};
  HttpServer? _wsServer;
  
  Future<void> startWebSocketServer(int port) async {
    try {
      _wsServer = await HttpServer.bind(InternetAddress.anyIPv4, port + 1);
      print('[WS] WebSocket server listening on port ${port + 1}');
      
      _wsServer!.listen((HttpRequest request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          WebSocket socket = await WebSocketTransformer.upgrade(request);
          _clients.add(socket);
          print('[WS] Client connected. Total clients: ${_clients.length}');
          
          socket.listen(
            (message) {
              // Handle incoming messages from clients
              _handleClientMessage(socket, message);
            },
            onDone: () {
              _clients.remove(socket);
              print('[WS] Client disconnected. Total clients: ${_clients.length}');
            },
            onError: (error) {
              _clients.remove(socket);
              print('[WS] Client error: $error');
            },
          );
          
          // Send initial state to new client
          _sendInitialState(socket);
        }
      });
    } catch (e) {
      print('[WS] Failed to start WebSocket server: $e');
    }
  }
  
  void _handleClientMessage(WebSocket socket, dynamic message) {
    try {
      final Map<String, dynamic> data = jsonDecode(message);
      final String type = data['type'] ?? '';
      
      switch (type) {
        case 'ping':
          socket.add(jsonEncode({'type': 'pong'}));
          break;
        case 'request_state':
          _sendInitialState(socket);
          break;
        default:
          print('[WS] Unknown message type: $type');
      }
    } catch (e) {
      print('[WS] Error handling client message: $e');
    }
  }
  
  void _sendInitialState(WebSocket socket) {
    // This will be called from main.dart with actual state
  }
  
  void broadcast(Map<String, dynamic> message) {
    final String jsonMessage = jsonEncode(message);
    final List<WebSocket> clientsCopy = _clients.toList();
    
    for (final client in clientsCopy) {
      try {
        client.add(jsonMessage);
      } catch (e) {
        print('[WS] Error broadcasting to client: $e');
        _clients.remove(client);
      }
    }
  }
  
  void broadcastQueueUpdate(List<dynamic> queue) {
    broadcast({
      'type': 'queue_update',
      'queue': queue,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  void broadcastPlaybackState(Map<String, dynamic> state) {
    broadcast({
      'type': 'playback_update',
      'state': state,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  void broadcastTrackAdded(Map<String, dynamic> track) {
    broadcast({
      'type': 'track_added',
      'track': track,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  void broadcastTrackRemoved(String videoId) {
    broadcast({
      'type': 'track_removed',
      'videoId': videoId,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  void broadcastSkip() {
    broadcast({
      'type': 'track_skipped',
      'timestamp': DateTime.now().toIso8601String(),
    });
  }
  
  Future<void> close() async {
    for (final client in _clients) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
    await _wsServer?.close();
  }
}
