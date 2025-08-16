import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:just_audio/just_audio.dart';
import 'package:path_provider/path_provider.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:percent_indicator/percent_indicator.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'websocket_handler.dart';
import 'share_handler.dart';

void main() {
  runApp(const MyApp());
}

class QueueItem {
  final String title;
  final String videoId;
  final String addedBy;
  final String? thumbnailUrl;
  final String source; // 'youtube' or 'soundcloud'
  final DateTime addedAt;

  const QueueItem({
    required this.title,
    required this.videoId,
    required this.addedBy,
    this.thumbnailUrl,
    this.source = 'youtube',
    required this.addedAt,
  });

  String get computedThumbnailUrl {
    if (thumbnailUrl != null) return thumbnailUrl!;
    if (source == 'youtube') {
      return 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
    }
    return ''; // SoundCloud thumbnails will be fetched from API
  }

  Map<String, dynamic> toJson() => {
    'title': title,
    'videoId': videoId,
    'addedBy': addedBy,
    'thumbnailUrl': thumbnailUrl,
    'source': source,
    'addedAt': addedAt.toIso8601String(),
  };

  factory QueueItem.fromJson(Map<String, dynamic> json) => QueueItem(
    title: json['title'],
    videoId: json['videoId'],
    addedBy: json['addedBy'],
    thumbnailUrl: json['thumbnailUrl'],
    source: json['source'] ?? 'youtube',
    addedAt: DateTime.parse(json['addedAt']),
  );
}

class PlaybackState {
  final QueueItem? nowPlaying;
  final Duration position;
  final Duration? duration;
  final bool isPlaying;
  final double volume;

  PlaybackState({
    this.nowPlaying,
    this.position = Duration.zero,
    this.duration,
    this.isPlaying = false,
    this.volume = 1.0,
  });

  Map<String, dynamic> toJson() => {
    'nowPlaying': nowPlaying?.toJson(),
    'position': position.inMilliseconds,
    'duration': duration?.inMilliseconds,
    'isPlaying': isPlaying,
    'volume': volume,
  };
}

class RoundRobinQueueManager {
  final Map<String, List<QueueItem>> _deviceToItems = {};
  final List<String> _deviceOrder = [];
  int _nextTurnIndex = 0;

  void addItem(String deviceName, QueueItem item) {
    if (!_deviceToItems.containsKey(deviceName)) {
      _deviceToItems[deviceName] = <QueueItem>[];
      _deviceOrder.add(deviceName);
      if (_deviceOrder.length == 1) {
        _nextTurnIndex = 0;
      }
    }
    _deviceToItems[deviceName]!.add(item);
  }

  QueueItem? popNext() {
    if (_deviceOrder.isEmpty) return null;
    final int devicesCount = _deviceOrder.length;
    for (int i = 0; i < devicesCount; i++) {
      final int idx = (_nextTurnIndex + i) % devicesCount;
      final String device = _deviceOrder[idx];
      final List<QueueItem>? list = _deviceToItems[device];
      if (list != null && list.isNotEmpty) {
        final QueueItem item = list.removeAt(0);
        _nextTurnIndex = (idx + 1) % devicesCount;
        return item;
      }
    }
    return null;
  }

  List<QueueItem> buildUpcomingFlattened() {
    final Map<String, List<QueueItem>> snapshot = {
      for (final entry in _deviceToItems.entries)
        entry.key: List<QueueItem>.from(entry.value),
    };
    final List<QueueItem> result = [];
    if (_deviceOrder.isEmpty) return result;
    int idx = _nextTurnIndex;
    int remaining = snapshot.values.fold<int>(
      0,
      (prev, list) => prev + list.length,
    );
    while (remaining > 0) {
      final String device = _deviceOrder[idx % _deviceOrder.length];
      final List<QueueItem>? list = snapshot[device];
      if (list != null && list.isNotEmpty) {
        result.add(list.removeAt(0));
        remaining--;
      }
      idx = (idx + 1) % _deviceOrder.length;
      if (snapshot.values.every((l) => l.isEmpty)) break;
    }
    return result;
  }

  bool removeItem(QueueItem target) {
    for (final list in _deviceToItems.values) {
      final int index = list.indexWhere(
        (e) =>
            e.videoId == target.videoId &&
            e.title == target.title &&
            e.addedBy == target.addedBy,
      );
      if (index != -1) {
        list.removeAt(index);
        return true;
      }
    }
    return false;
  }

  Map<String, dynamic> toJson() => {
    'deviceToItems': _deviceToItems.map((k, v) => 
      MapEntry(k, v.map((item) => item.toJson()).toList())),
    'deviceOrder': _deviceOrder,
    'nextTurnIndex': _nextTurnIndex,
  };

  void fromJson(Map<String, dynamic> json) {
    _deviceToItems.clear();
    _deviceOrder.clear();
    
    final deviceItems = json['deviceToItems'] as Map<String, dynamic>;
    deviceItems.forEach((device, items) {
      _deviceToItems[device] = (items as List)
        .map((item) => QueueItem.fromJson(item))
        .toList();
      _deviceOrder.add(device);
    });
    
    _nextTurnIndex = json['nextTurnIndex'] ?? 0;
  }
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with TickerProviderStateMixin {
  final RoundRobinQueueManager _rr = RoundRobinQueueManager();
  List<QueueItem> _queue = [];
  QueueItem? _nowPlaying;
  HttpServer? _server;
  String? _deviceDisplayName;
  late final AudioPlayer _player;
  bool _isDownloadingOrPreparing = false;
  bool _isSkipping = false;
  String _lastSkippedFilePath = '';
  
  // UI State
  late AnimationController _playPauseAnimController;
  bool _showDetailedQueue = false;
  
  // Stats
  int _totalPlayed = 0;
  Duration _totalListeningTime = Duration.zero;
  DateTime? _sessionStartTime;
  
  // Throttle noisy playback logs
  DateTime _lastPlaybackLogTs = DateTime.fromMillisecondsSinceEpoch(0);
  ProcessingState? _lastLoggedProcessingState;
  final Duration _playbackLogInterval = const Duration(seconds: 2);
  
  // Deduplicate concurrent downloads per videoId
  final Map<String, Future<String>> _inflightDownloads = {};
  
  // Persistence
  SharedPreferences? _prefs;
  Timer? _saveTimer;
  final WebSocketHandler _wsHandler = WebSocketHandler();

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String();
    print('[CQ $ts] $msg');
  }

  static const int _serverPort = 5283;

  @override
  void initState() {
    super.initState();
    
    _playPauseAnimController = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    
    _sessionStartTime = DateTime.now();
    
    // Initialize media_kit backend for just_audio on desktop platforms (Linux/Windows)
    if (Platform.isLinux || Platform.isWindows) {
      JustAudioMediaKit.ensureInitialized();
    }
    
    _player = AudioPlayer();
    _initDeviceDisplayName();
    _loadPersistedQueue();
    
    // Initialize iOS share handler
    ShareHandler.init((url, text) {
      if (Platform.isMacOS || Platform.isLinux) {
        // Host mode - add to queue directly
        _enqueue(url, text ?? 'iOS Share');
      }
    });
    
    if (Platform.isMacOS || Platform.isLinux) {
      _startServer();
    } else {
      _initShareListeners();
    }
    _wsHandler.startWebSocketServer(5283);
    
    // Detailed player diagnostics
    _player.playbackEventStream.listen((event) {
      final now = DateTime.now();
      final bool stateChanged = event.processingState != _lastLoggedProcessingState;
      final bool timeElapsed = now.difference(_lastPlaybackLogTs) >= _playbackLogInterval;
      if (!(stateChanged || timeElapsed)) return;
      _lastPlaybackLogTs = now;
      _lastLoggedProcessingState = event.processingState;
      final pos = _player.position;
      final dur = _player.duration;
      final buff = _player.bufferedPosition;
      _log('PlaybackEvent: state=${event.processingState} pos=$pos dur=$dur buff=$buff');
      
      // Broadcast state to WebSocket clients
      _broadcastPlaybackState();
    });
    
    _player.playerStateStream.listen((state) async {
      _log('Player state: processing=${state.processingState} playing=${state.playing}');
      
      if (state.playing) {
        _playPauseAnimController.forward();
      } else {
        _playPauseAnimController.reverse();
      }
      
      // Handle song completion
      if (state.processingState == ProcessingState.completed) {
        _log('Song completed, advancing to next');
        _totalPlayed++;
        _totalListeningTime += _player.duration ?? Duration.zero;
        _isDownloadingOrPreparing = false; // Reset flag before playing next
        _isSkipping = false;
        await _playNext();
      }
      
      // Also handle if player goes idle unexpectedly
      if (state.processingState == ProcessingState.idle && _nowPlaying != null) {
        _log('Player went idle unexpectedly, resetting flags');
        _isDownloadingOrPreparing = false;
        _isSkipping = false;
      }
    });
    
    // Periodic save
    _saveTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      _persistQueue();
    });
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _persistQueue();
    _server?.close(force: true);
    _wsHandler.close();
    _playPauseAnimController.dispose();
    _player.dispose();
    super.dispose();
  }

  Future<void> _loadPersistedQueue() async {
    try {
      _prefs = await SharedPreferences.getInstance();
      final String? queueJson = _prefs!.getString('queue_state');
      if (queueJson != null) {
        final Map<String, dynamic> data = jsonDecode(queueJson);
        _rr.fromJson(data);
        _queue = _rr.buildUpcomingFlattened();
        _totalPlayed = _prefs!.getInt('total_played') ?? 0;
        _totalListeningTime = Duration(seconds: _prefs!.getInt('total_listening_seconds') ?? 0);
        _log('Loaded persisted queue with ${_queue.length} items');
        setState(() {});
        
        // Start playback if queue is not empty and nothing is playing
        if (_queue.isNotEmpty && !_player.playing) {
          _log('Starting playback after queue restore');
          _playNext();
        }
      }
    } catch (e) {
      _log('Error loading persisted queue: $e');
    }
  }

  Future<void> _persistQueue() async {
    try {
      if (_prefs == null) return;
      final String queueJson = jsonEncode(_rr.toJson());
      await _prefs!.setString('queue_state', queueJson);
      await _prefs!.setInt('total_played', _totalPlayed);
      await _prefs!.setInt('total_listening_seconds', _totalListeningTime.inSeconds);
      _log('Persisted queue state');
    } catch (e) {
      _log('Error persisting queue: $e');
    }
  }

  void _broadcastPlaybackState() {
    final state = PlaybackState(
      nowPlaying: _nowPlaying,
      position: _player.position,
      duration: _player.duration,
      isPlaying: _player.playing,
      volume: _player.volume,
    );
    _wsHandler.broadcastPlaybackState(state.toJson());
    _log('Playback state updated');
  }

  void _broadcastQueueUpdate() {
    // WebSocket broadcast will be implemented later
    _log('Queue updated: ${_queue.length} items');
  }

  Future<void> _initDeviceDisplayName() async {
    final deviceInfo = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
      _deviceDisplayName = androidInfo.model ?? 'Android Device';
    } else if (Platform.isIOS) {
      IosDeviceInfo iosInfo = await deviceInfo.iosInfo;
      _deviceDisplayName = iosInfo.name ?? 'iOS Device';
    } else if (Platform.isMacOS) {
      try {
        // Try hostname command first
        try {
          final result = await Process.run('hostname', ['-s']);
          if (result.exitCode == 0) {
            _deviceDisplayName = result.stdout.toString().trim();
            return;
          }
        } catch (e) {
          // If hostname -s fails, try without the -s flag
          try {
            final result = await Process.run('hostname', []);
            if (result.exitCode == 0) {
              _deviceDisplayName = result.stdout.toString().trim().split('.').first;
              return;
            }
          } catch (e2) {
            _log('Could not get hostname: $e2');
          }
        }
      } catch (e) {
        _log('Could not get hostname: $e');
      }
      _deviceDisplayName = 'Mac';
    } else if (Platform.isLinux) {
      try {
        // Try hostname command first
        try {
          final result = await Process.run('hostname', ['-s']);
          if (result.exitCode == 0) {
            _deviceDisplayName = result.stdout.toString().trim();
            return;
          }
        } catch (e) {
          // If hostname -s fails, try without the -s flag
          try {
            final result = await Process.run('hostname', []);
            if (result.exitCode == 0) {
              _deviceDisplayName = result.stdout.toString().trim().split('.').first;
              return;
            }
          } catch (e2) {
            _log('Could not get hostname: $e2');
          }
        }
      } catch (e) {
        _log('Could not get hostname: $e');
      }
      _deviceDisplayName = 'Linux';
    } else {
      _deviceDisplayName = 'Unknown Device';
    }
    _log('Device display name: $_deviceDisplayName');
    setState(() {});
  }

  Future<String> _downloadOrGetCachedMp3(String videoId, String source) async {
    final Directory appDir = await getApplicationSupportDirectory();
    final Directory audioDir = Directory('${appDir.path}/audio');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    final String target = '${audioDir.path}/${source}_$videoId.mp3';
    final File f = File(target);
    if (await f.exists() && await f.length() > 1024) {
      _log('Using cached MP3: $target');
      return target;
    }
    final existing = _inflightDownloads[videoId];
    if (existing != null) {
      _log('Reusing in-flight download for video=$videoId');
      return await existing;
    }
    _log('Downloading via yt-dlp to $target for video=$videoId source=$source');
    final Future<String> future = (() async {
      String url;
      if (source == 'youtube') {
        url = 'https://www.youtube.com/watch?v=$videoId';
      } else if (source == 'soundcloud') {
        url = videoId; // For SoundCloud, videoId is the full URL
      } else {
        throw 'Unsupported source: $source';
      }
      
      final ProcessResult result = await Process.run(
        'yt-dlp',
        [
          '-f', 'bestaudio',
          '-x', '--audio-format', 'mp3',
          '--no-part',
          '--retries', '5', '--fragment-retries', '5',
          '--http-chunk-size', '10M',
          '-o', target,
          url,
        ],
        runInShell: true,
      );
      if (result.exitCode != 0) {
        _log('yt-dlp failed: code=${result.exitCode} stderr=${result.stderr}');
        throw 'Download failed: ${result.stderr}';
      }
      if (!await f.exists()) {
        _log('yt-dlp reported success but file missing');
        throw 'File not found after download';
      }
      _log('Download complete: $target');
      return target;
    })();
    _inflightDownloads[videoId] = future;
    try {
      return await future;
    } finally {
      _inflightDownloads.remove(videoId);
    }
  }

  Future<void> _playNext() async {
    if (_isDownloadingOrPreparing || _isSkipping) {
      _log('Already downloading/preparing or skipping, ignoring _playNext');
      return;
    }
    _isDownloadingOrPreparing = true;
    try {
      final QueueItem? toPlay = _rr.popNext();
      if (toPlay == null) {
        _log('Queue is empty');
        _nowPlaying = null;
        _isDownloadingOrPreparing = false;
        setState(() {});
        _broadcastQueueUpdate();
        return;
      }
      _log('Playing next: ${toPlay.title} by ${toPlay.addedBy}');
      _nowPlaying = toPlay;
      setState(() {
        _queue = _rr.buildUpcomingFlattened();
      });
      _broadcastQueueUpdate();
      
      final String audioFilePath = await _downloadOrGetCachedMp3(toPlay.videoId, toPlay.source);
      final Uri audioUri = Uri.file(audioFilePath);
      await _player.setAudioSource(AudioSource.uri(audioUri));
      await _player.play();
      
      // Reset flag after successful play start
      _isDownloadingOrPreparing = false;
      
      // Prefetch next item
      final nextItems = _rr.buildUpcomingFlattened();
      if (nextItems.isNotEmpty) {
        final next = nextItems.first;
        _log('Prefetching next: ${next.title}');
        _downloadOrGetCachedMp3(next.videoId, next.source).catchError((e) {
          _log('Prefetch error (non-fatal): $e');
        });
      }
    } catch (e) {
      _log('Error in _playNext: $e');
      _isDownloadingOrPreparing = false;
      await _safeSkip();
    }
  }

  Future<void> _safeSkip() async {
    if (_isSkipping) {
      _log('Already skipping, ignoring');
      return;
    }
    _isSkipping = true;
    try {
      await _player.stop();
      await _playNext();
    } finally {
      _isSkipping = false;
    }
  }

  void _enqueue(String url, String deviceName) async {
    try {
      String videoId;
      String title;
      String source = 'youtube';
      
      // Parse URL
      if (url.contains('youtube.com') || url.contains('youtu.be')) {
        source = 'youtube';
        final uri = Uri.tryParse(url);
        if (uri != null) {
          videoId = uri.queryParameters['v'] ?? '';
          if (videoId.isEmpty && uri.pathSegments.isNotEmpty) {
            videoId = uri.pathSegments.last;
          }
        } else {
          videoId = url.split('v=').last.split('&').first;
        }
        // Fetch title via yt-dlp
        final result = await Process.run(
          'yt-dlp',
          ['--get-title', url],
          runInShell: true,
        );
        title = result.stdout.toString().trim();
        if (title.isEmpty) title = 'Unknown Title';
      } else if (url.contains('soundcloud.com')) {
        source = 'soundcloud';
        videoId = url; // Store full URL for SoundCloud
        // Fetch title via yt-dlp
        final result = await Process.run(
          'yt-dlp',
          ['--get-title', url],
          runInShell: true,
        );
        title = result.stdout.toString().trim();
        if (title.isEmpty) title = 'SoundCloud Track';
      } else {
        _log('Unsupported URL: $url');
        return;
      }
      
      final item = QueueItem(
        title: title,
        videoId: videoId,
        addedBy: deviceName,
        source: source,
        addedAt: DateTime.now(),
      );
      
      _rr.addItem(deviceName, item);
      setState(() {
        _queue = _rr.buildUpcomingFlattened();
      });
      _broadcastQueueUpdate();
      _persistQueue();
      
      // Start playback if nothing is playing
      if (_nowPlaying == null && !_player.playing) {
        await _playNext();
      }
    } catch (e) {
      _log('Error enqueueing: $e');
    }
  }

  void _remove(QueueItem item) {
    if (_rr.removeItem(item)) {
      setState(() {
        _queue = _rr.buildUpcomingFlattened();
      });
      _broadcastQueueUpdate();
      _persistQueue();
    }
  }

  Future<void> _startServer() async {
    try {
      _server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _serverPort,
      );
      _log('HTTP server listening on port $_serverPort');
      
      await for (HttpRequest request in _server!) {
        _handleRequest(request);
      }
    } catch (e) {
      _log('Failed to start server: $e');
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final String path = request.uri.path;
    final String method = request.method;
    
    try {
      if (path == '/health' && method == 'GET') {
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.text
          ..write('OK');
        await request.response.close();
      } else if (path == '/append-queue' && method == 'POST') {
        final String body = await utf8.decoder.bind(request).join();
        final Map<String, dynamic> data = jsonDecode(body);
        final String? url = data['url'];
        final String? deviceName = data['device_name'] ?? data['deviceName'];
        
        if (url == null || deviceName == null) {
          request.response
            ..statusCode = HttpStatus.badRequest
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'error': 'Missing url or device_name'}));
        } else {
          _enqueue(url, deviceName);
          request.response
            ..statusCode = HttpStatus.ok
            ..headers.contentType = ContentType.json
            ..write(jsonEncode({'status': 'ok', 'message': 'Added to queue'}));
        }
        await request.response.close();
      } else if (path == '/queue-state' && method == 'GET') {
        // Return current queue state for sync
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'nowPlaying': _nowPlaying?.toJson(),
            'queue': _queue.map((item) => item.toJson()).toList(),
            'stats': {
              'totalPlayed': _totalPlayed,
              'totalListeningSeconds': _totalListeningTime.inSeconds,
            },
          }));
        await request.response.close();
      } else if (path == '/' && method == 'GET') {
        // Serve web client
        await _serveWebClient(request);
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not Found');
        await request.response.close();
      }
    } catch (e) {
      _log('Error handling request: $e');
      request.response
        ..statusCode = HttpStatus.internalServerError
        ..write('Internal Server Error');
      await request.response.close();
    }
  }

  Future<void> _serveWebClient(HttpRequest request) async {
    final File webFile = File('web/index.html');
    if (await webFile.exists()) {
      final String content = await webFile.readAsString();
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(content);
    } else {
      // Fallback inline HTML
      request.response
        ..statusCode = HttpStatus.ok
        ..headers.contentType = ContentType.html
        ..write(_getFallbackHtml());
    }
    await request.response.close();
  }

  String _getFallbackHtml() {
    return '''<!DOCTYPE html>
<html>
<head>
    <title>Cosmos Queue</title>
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <style>
        body { font-family: system-ui; max-width: 500px; margin: 50px auto; padding: 20px; }
        input, button { display: block; width: 100%; margin: 10px 0; padding: 10px; }
        button { background: #007bff; color: white; border: none; cursor: pointer; }
        button:hover { background: #0056b3; }
    </style>
</head>
<body>
    <h1>Cosmos Queue</h1>
    <form method="POST" action="/append-queue">
        <input type="text" name="url" placeholder="YouTube or SoundCloud URL" required>
        <input type="text" name="device_name" placeholder="Your Name" required>
        <button type="submit">Add to Queue</button>
    </form>
</body>
</html>''';
  }

  void _initShareListeners() {
    // This would be implemented for mobile platforms
    // For now, just a placeholder
    _log('Share listeners initialized');
  }

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final minutes = twoDigits(duration.inMinutes.remainder(60));
    final seconds = twoDigits(duration.inSeconds.remainder(60));
    return '${duration.inMinutes}:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    var isHost = Platform.isMacOS || Platform.isLinux;
    var isClient = Platform.isAndroid || Platform.isIOS;

    if (isHost) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          primaryColor: const Color(0xFF667EEA),
          scaffoldBackgroundColor: const Color(0xFF0F0F1E),
          colorScheme: const ColorScheme.dark(
            primary: Color(0xFF667EEA),
            secondary: Color(0xFF764BA2),
          ),
        ),
        home: _buildHostUI(),
      );
    } else if (isClient) {
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark().copyWith(
          primaryColor: const Color(0xFF667EEA),
          scaffoldBackgroundColor: const Color(0xFF0F0F1E),
        ),
        home: _buildClientUI(),
      );
    }
    
    return const MaterialApp(
      home: Scaffold(
        body: Center(
          child: Text('Unsupported platform'),
        ),
      ),
    );
  }

  Widget _buildHostUI() {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF1A1A2E),
              Color(0xFF0F0F1E),
            ],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHostHeader(),
              Expanded(
                child: Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: _buildNowPlayingSection(),
                    ),
                    Expanded(
                      flex: 2,
                      child: _buildQueueSection(),
                    ),
                  ],
                ),
              ),
              _buildPlaybackControls(),
              _buildStatsBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHostHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      child: Row(
        children: [
          const Icon(
            Icons.album,
            size: 32,
            color: Color(0xFF667EEA),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Cosmos Queue',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Text(
                'Server: ${_deviceDisplayName ?? "Loading..."} • Port: $_serverPort',
                style: TextStyle(
                  fontSize: 12,
                  color: Colors.white.withOpacity(0.6),
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: const Color(0xFF667EEA).withOpacity(0.2),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: const Color(0xFF667EEA).withOpacity(0.5),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.wifi_tethering,
                  size: 16,
                  color: const Color(0xFF667EEA),
                ),
                const SizedBox(width: 8),
                Text(
                  'Online',
                  style: TextStyle(
                    color: const Color(0xFF667EEA),
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlayingSection() {
    return Container(
      margin: const EdgeInsets.all(20),
      padding: const EdgeInsets.all(30),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xFF667EEA).withOpacity(0.1),
            const Color(0xFF764BA2).withOpacity(0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (_nowPlaying != null) ...[
            Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(15),
                boxShadow: [
                  BoxShadow(
                    color: const Color(0xFF667EEA).withOpacity(0.3),
                    blurRadius: 30,
                    spreadRadius: 5,
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(15),
                child: Image.network(
                  _nowPlaying!.computedThumbnailUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: const Color(0xFF667EEA).withOpacity(0.3),
                      child: const Icon(
                        Icons.music_note,
                        size: 80,
                        color: Colors.white,
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              _nowPlaying!.title,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 8),
            Text(
              'Added by ${_nowPlaying!.addedBy}',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 20),
            StreamBuilder<Duration>(
              stream: _player.positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = _player.duration ?? Duration.zero;
                
                return Column(
                  children: [
                    LinearPercentIndicator(
                      width: 300,
                      lineHeight: 6,
                      percent: duration.inMilliseconds > 0
                          ? (position.inMilliseconds / duration.inMilliseconds)
                              .clamp(0.0, 1.0)
                          : 0.0,
                      backgroundColor: Colors.white.withOpacity(0.1),
                      progressColor: const Color(0xFF667EEA),
                      barRadius: const Radius.circular(3),
                      animation: false,
                    ),
                    const SizedBox(height: 8),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          _formatDuration(position),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '/',
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDuration(duration),
                          style: TextStyle(
                            color: Colors.white.withOpacity(0.7),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ] else ...[
            Icon(
              Icons.queue_music,
              size: 100,
              color: Colors.white.withOpacity(0.3),
            ),
            const SizedBox(height: 20),
            Text(
              'No track playing',
              style: TextStyle(
                fontSize: 24,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Add songs to get started',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.3),
              ),
            ),
          ],
        ],
      ),
    );
  }
  Widget _buildQueueSection() {
    return Container(
      margin: const EdgeInsets.only(top: 20, right: 20, bottom: 20),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: Colors.white.withOpacity(0.1),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Up Next',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFF667EEA).withOpacity(0.2),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '${_queue.length} tracks',
                  style: const TextStyle(
                    color: Color(0xFF667EEA),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Expanded(
            child: _queue.isEmpty
                ? Center(
                    child: Text(
                      'Queue is empty',
                      style: TextStyle(
                        color: Colors.white.withOpacity(0.3),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _queue.length,
                    itemBuilder: (context, index) {
                      final item = _queue[index];
                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.05),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: Colors.white.withOpacity(0.05),
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  item.computedThumbnailUrl,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return Container(
                                      color: const Color(0xFF667EEA).withOpacity(0.2),
                                      child: const Icon(
                                        Icons.music_note,
                                        size: 20,
                                        color: Colors.white,
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item.title,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    item.addedBy,
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.5),
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: Icon(
                                Icons.close,
                                size: 18,
                                color: Colors.white.withOpacity(0.3),
                              ),
                              onPressed: () {
                                setState(() {
                                  _remove(item);
                                });
                              },
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaybackControls() {
    final TextEditingController urlController = TextEditingController();
    
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 30),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.3),
        border: Border(
          top: BorderSide(
            color: Colors.white.withOpacity(0.1),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Skip button
          Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: const LinearGradient(
                colors: [Color(0xFF667EEA), Color(0xFF764BA2)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF667EEA).withOpacity(0.3),
                  blurRadius: 20,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(30),
                onTap: () async {
                  await _safeSkip();
                },
                child: Container(
                  padding: const EdgeInsets.all(15),
                  child: const Icon(
                    Icons.skip_next,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),
          
          const SizedBox(width: 40),
          
          // Add URL field
          Container(
            width: 400,
            height: 45,
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.05),
              borderRadius: BorderRadius.circular(25),
              border: Border.all(
                color: Colors.white.withOpacity(0.1),
              ),
            ),
            child: TextField(
              controller: urlController,
              style: const TextStyle(color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Paste YouTube or SoundCloud URL...',
                hintStyle: TextStyle(
                  color: Colors.white.withOpacity(0.3),
                ),
                prefixIcon: Icon(
                  Icons.link,
                  color: Colors.white.withOpacity(0.3),
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
              ),
              onSubmitted: (value) async {
                if (value.isNotEmpty) {
                  _enqueue(value, _deviceDisplayName ?? 'Host');
                  urlController.clear();
                }
              },
            ),
          ),
          
          const SizedBox(width: 40),
          
          // Volume control
          Icon(
            Icons.volume_down,
            color: Colors.white.withOpacity(0.5),
          ),
          SizedBox(
            width: 100,
            child: StreamBuilder<double>(
              stream: _player.volumeStream,
              builder: (context, snapshot) {
                final volume = snapshot.data ?? 1.0;
                return Slider(
                  value: volume,
                  onChanged: (value) {
                    _player.setVolume(value);
                  },
                  activeColor: const Color(0xFF667EEA),
                  inactiveColor: Colors.white.withOpacity(0.1),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatsBar() {
    final sessionDuration = _sessionStartTime != null
        ? DateTime.now().difference(_sessionStartTime!)
        : Duration.zero;
    
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
      decoration: BoxDecoration(
        color: const Color(0xFF667EEA).withOpacity(0.1),
        border: Border(
          top: BorderSide(
            color: const Color(0xFF667EEA).withOpacity(0.3),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildStatItem(
            icon: Icons.play_circle_outline,
            label: 'Tracks Played',
            value: _totalPlayed.toString(),
          ),
          _buildStatItem(
            icon: Icons.timer,
            label: 'Session Time',
            value: _formatDuration(sessionDuration),
          ),
          _buildStatItem(
            icon: Icons.headphones,
            label: 'Total Listening',
            value: _formatDuration(_totalListeningTime),
          ),
          _buildStatItem(
            icon: Icons.queue_music,
            label: 'Queue Size',
            value: _queue.length.toString(),
          ),
        ],
      ),
    );
  }

  Widget _buildStatItem({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 20,
          color: const Color(0xFF667EEA),
        ),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withOpacity(0.5),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildClientUI() {
    final TextEditingController deviceNameController = TextEditingController();
    final TextEditingController urlController = TextEditingController();
    final TextEditingController serverController = TextEditingController(text: 'http://192.168.1.108:5283');
    
    return StatefulBuilder(
      builder: (context, setState) {
        WebSocketChannel? wsChannel;
        bool isConnected = false;
        String? connectionStatus;
        
        void connectWebSocket() async {
          final serverUrl = serverController.text.trim();
          if (serverUrl.isEmpty) return;
          
          try {
            final wsUrl = serverUrl.replaceFirst('http://', 'ws://').replaceFirst(':5283', ':5284');
            wsChannel = WebSocketChannel.connect(Uri.parse(wsUrl));
            
            setState(() {
              isConnected = true;
              connectionStatus = 'Connected';
            });
            
            wsChannel!.stream.listen(
              (message) {
                // Handle incoming WebSocket messages
                setState(() {
                  connectionStatus = 'Last update: ${DateTime.now().toString().substring(11, 19)}';
                });
              },
              onError: (error) {
                setState(() {
                  isConnected = false;
                  connectionStatus = 'Connection error';
                });
              },
              onDone: () {
                setState(() {
                  isConnected = false;
                  connectionStatus = 'Disconnected';
                });
              },
            );
          } catch (e) {
            setState(() {
              connectionStatus = 'Failed to connect';
            });
          }
        }
        
        return Scaffold(
          body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color(0xFF667EEA),
              Color(0xFF764BA2),
            ],
          ),
        ),
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.album,
                  size: 80,
                  color: Colors.white,
                ),
                const SizedBox(height: 20),
                const Text(
                  'Cosmos Queue',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 40),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Column(
                    children: [
                      TextField(
                            controller: deviceNameController,
                            style: const TextStyle(color: Colors.white),
                            decoration: InputDecoration(
                              labelText: 'Your Name',
                              labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                              prefixIcon: const Icon(Icons.person, color: Colors.white),
                              enabledBorder: OutlineInputBorder(
                                borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderSide: const BorderSide(color: Colors.white),
                                borderRadius: BorderRadius.circular(10),
                              ),
                            ),
                          ),
                      const SizedBox(height: 15),
                      TextField(
                        controller: urlController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'YouTube/SoundCloud URL',
                          labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                          prefixIcon: const Icon(Icons.link, color: Colors.white),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: const BorderSide(color: Colors.white),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 15),
                      TextField(
                        controller: serverController,
                        style: const TextStyle(color: Colors.white),
                        decoration: InputDecoration(
                          labelText: 'Server URL',
                          labelStyle: TextStyle(color: Colors.white.withOpacity(0.7)),
                          prefixIcon: const Icon(Icons.computer, color: Colors.white),
                          enabledBorder: OutlineInputBorder(
                            borderSide: BorderSide(color: Colors.white.withOpacity(0.3)),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderSide: const BorderSide(color: Colors.white),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                      const SizedBox(height: 25),
                      ElevatedButton(
                        onPressed: () async {
                          final url = urlController.text.trim();
                          final deviceName = deviceNameController.text.trim();
                          final serverUrl = serverController.text.trim();
                          
                          if (url.isNotEmpty && deviceName.isNotEmpty && serverUrl.isNotEmpty) {
                            try {
                              final response = await http.post(
                                Uri.parse('$serverUrl/append-queue'),
                                headers: {'Content-Type': 'application/json'},
                                body: jsonEncode({
                                  'url': url,
                                  'device_name': deviceName,
                                }),
                              );
                              
                              if (response.statusCode == 200) {
                                urlController.clear();
                                ScaffoldMessenger.of(context).showSnackBar(
                                  const SnackBar(
                                    content: Text('Added to queue!'),
                                    backgroundColor: Colors.green,
                                  ),
                                );
                              } else {
                                throw 'Server returned ${response.statusCode}';
                              }
                            } catch (e) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                  content: Text('Error: $e'),
                                  backgroundColor: Colors.red,
                                ),
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white,
                          foregroundColor: const Color(0xFF667EEA),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 50,
                            vertical: 15,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(30),
                          ),
                        ),
                        child: const Text(
                          'Add to Queue',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
      },
    );
  }
}
