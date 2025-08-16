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

void main() {
  runApp(const MyApp());
}

class QueueItem {
  final String title;
  final String videoId;
  final String addedBy;

  const QueueItem({
    required this.title,
    required this.videoId,
    required this.addedBy,
  });

  get thumbnailUrl => 'https://i.ytimg.com/vi/$videoId/hqdefault.jpg';
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
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final RoundRobinQueueManager _rr = RoundRobinQueueManager();
  List<QueueItem> _queue = [];
  QueueItem? _nowPlaying;
  HttpServer? _server;
  String? _deviceDisplayName;
  late final AudioPlayer _player;
  bool _isDownloadingOrPreparing = false;
  bool _isSkipping = false;
  String _lastSkippedFilePath = '';
  // Throttle noisy playback logs
  DateTime _lastPlaybackLogTs = DateTime.fromMillisecondsSinceEpoch(0);
  ProcessingState? _lastLoggedProcessingState;
  final Duration _playbackLogInterval = const Duration(seconds: 2);
  // Deduplicate concurrent downloads per videoId
  final Map<String, Future<String>> _inflightDownloads = {};

  void _log(String msg) {
    final ts = DateTime.now().toIso8601String();
    print('[CQ $ts] $msg');
  }

  static const int _serverPort = 5283;

  @override
  void initState() {
    super.initState();
    // Initialize media_kit backend for just_audio on desktop platforms (Linux/Windows)
    if (Platform.isLinux || Platform.isWindows) {
      JustAudioMediaKit.ensureInitialized();
    }
    _player = AudioPlayer();
    _initDeviceDisplayName();
    if (Platform.isMacOS || Platform.isLinux) {
      _startServer();
    } else {
      _initShareListeners();
    }
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
    });
    _player.playerStateStream.listen((state) async {
      _log('Player state: processing=${state.processingState} playing=${state.playing}');
      final source = _player.audioSource;
      String? audioUri = source is UriAudioSource ? source.uri.toString() : null;
      if (state.processingState == ProcessingState.completed && audioUri != null && audioUri != _lastSkippedFilePath) {
        _lastSkippedFilePath = audioUri;
        await _safeSkip();
      }
    });
  }

  @override
  void dispose() {
    _server?.close(force: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    var isHost = Platform.isMacOS || Platform.isLinux;

    TextStyle fontStyleWithSize(double size) =>
        CupertinoTheme.of(context).textTheme.textStyle.copyWith(fontSize: size);

    return CupertinoApp(
      debugShowCheckedModeBanner: false,
      home: CupertinoPageScaffold(
        child: SafeArea(
          child: isHost
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 12,
                  children: [
                    CupertinoTextField(
                      onSubmitted: (value) {
                        setState(() {
                          _addUrl(value, 'MacOS');
                        });
                      },
                    ),
                    ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 300),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: _queue.isEmpty && _nowPlaying == null
                            ? Text('No videos in queue')
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                spacing: 8,
                                children: [
                                  Row(
                                    children: [
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        spacing: 8,
                                        children: [
                                          Text('Currently Playing'),
                                          Text(
                                            _nowPlaying?.title ??
                                                'Nothing playing',
                                            style: fontStyleWithSize(32),
                                          ),
                                        ],
                                      ),
                                      Spacer(),
                                      CupertinoButton(
                                        child: const Text('Skip'),
                                        onPressed: () async {
                                          await _safeSkip();
                                        },
                                      ),
                                    ],
                                  ),
                                  SizedBox(height: 12),
                                  if (_queue.isNotEmpty)
                                    Text(
                                      'Queue',
                                      style: CupertinoTheme.of(context)
                                          .textTheme
                                          .textStyle
                                          .copyWith(fontSize: 24),
                                    ),
                                  Column(
                                    children: [
                                      for (var item in _queue)
                                        Row(
                                          spacing: 12,
                                          children: [
                                            SizedBox(
                                              height: 48,
                                              child: AspectRatio(
                                                aspectRatio: 16 / 9,
                                                child: Image.network(
                                                  item.thumbnailUrl,
                                                  fit: BoxFit.cover,
                                                ),
                                              ),
                                            ),
                                            Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment
                                                      .spaceBetween,
                                              children: [
                                                Text(
                                                  item.title,
                                                  style: fontStyleWithSize(24),
                                                ),
                                                Text(
                                                  'Added by: ${item.addedBy}',
                                                  style: fontStyleWithSize(18),
                                                ),
                                              ],
                                            ),
                                            Spacer(),
                                            CupertinoButton(
                                              child: const Text('Remove'),
                                              onPressed: () {
                                                setState(() {
                                                  _remove(item);
                                                });
                                              },
                                            ),
                                          ],
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                      ),
                    ),
                  ],
                )
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      'Share a video to this app to add it to the queue.',
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _initDeviceDisplayName() async {
    try {
      final DeviceInfoPlugin plugin = DeviceInfoPlugin();
      if (Platform.isIOS) {
        final ios = await plugin.iosInfo;
        _deviceDisplayName = ios.name;
      } else if (Platform.isAndroid) {
        final android = await plugin.androidInfo;
        final manufacturer = android.manufacturer.trim();
        final model = android.model.trim();
        final combined = [
          manufacturer,
          model,
        ].where((e) => e.isNotEmpty).join(' ');
        _deviceDisplayName = combined.isNotEmpty ? combined : 'Android Device';
      } else if (Platform.isMacOS) {
        _deviceDisplayName = Platform.localHostname;
      } else {
        _deviceDisplayName = 'Unknown Device';
      }
      if (mounted) setState(() {});
    } catch (_) {
      _deviceDisplayName = 'Unknown Device';
    }
  }

  void _initShareListeners() {
    const MethodChannel channel = MethodChannel('cosmos_queue/share');
    channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedText') {
        final String? text = call.arguments as String?;
        if (text != null) {
          _handleIncomingSharedText(text);
        }
      }
    });
    channel
        .invokeMethod<String>('getInitialSharedText')
        .then((value) {
          if (value != null) {
            _handleIncomingSharedText(value);
          }
        })
        .catchError((err) {
          print('Error getting initial shared text: $err');
        });
  }

  void _handleIncomingSharedText(String text) {
    final String? url = _extractFirstUrl(text);
    if (url == null) return;
    final String sender = _deviceDisplayName ?? 'Unknown Device';
    _sendLinkToHost(url: url, deviceName: sender);
  }

  String? _extractFirstUrl(String text) {
    final RegExp re = RegExp(r'(https?:\/\/\S+)');
    final match = re.firstMatch(text);
    return match?.group(1);
  }

  Future<void> _sendLinkToHost({
    required String url,
    required String deviceName,
  }) async {
    final headers = {'Content-Type': 'application/json'};
    _log('Sending link to host: url=$url from=$deviceName');
    final body = jsonEncode({'url': url, 'deviceName': deviceName});
    try {
      final res = await http
          .post(
            Uri.parse('http://192.168.1.108:5283/append-queue'),
            headers: headers,
            body: body,
          )
          .timeout(const Duration(seconds: 3));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        _log('Link delivered to host: status=${res.statusCode}');
        if (Platform.isAndroid) {
          const MethodChannel channel = MethodChannel('cosmos_queue/share');
          channel.invokeMethod('completeShare');
        }
      } else {
        _log('Host responded with non-2xx: status=${res.statusCode} body=${res.body}');
      }
    } catch (err) {
      _log('Error sending link to host: $err');
    }
  }

  Future<void> _addUrl(String url, String deviceName) async {
    _log('Add URL requested: url=$url from=$deviceName');
    final String? videoId = _parseYouTubeVideoId(url);
    if (videoId == null) {
      _log('Parsing failed for URL, not a supported YouTube link');
      throw 'Invalid YouTube video ID';
    }
    final String title = await _fetchYouTubeTitle(url) ?? 'YouTube Video';
    _log('Parsed video: id=$videoId title="$title"');
    final QueueItem item = QueueItem(
      title: title,
      videoId: videoId,
      addedBy: deviceName,
    );

    setState(() {
      final String? previousNowPlayingId = _nowPlaying?.videoId;
      _rr.addItem(deviceName, item);
      _nowPlaying ??= _rr.popNext();
      _queue = _rr.buildUpcomingFlattened();
      _log('Queue updated: nowPlaying=${_nowPlaying?.videoId} upcoming=${_queue.length}');
      final String? currentNowPlayingId = _nowPlaying?.videoId;
      if (currentNowPlayingId != null && currentNowPlayingId != previousNowPlayingId) {
        _startPlaybackForCurrent();
      }
    });

    // Prefetch the NEXT up item (not the one that just became nowPlaying)
    final String? prefetchId = _queue.isNotEmpty ? _queue.first.videoId : null;
    if (prefetchId != null) {
      _downloadOrGetCachedMp3(prefetchId);
    }
  }

  Future<void> _startServer() async {
    try {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _serverPort,
      );
      _server = server;
      _log('HTTP server started on 0.0.0.0:$_serverPort');
      _log('Web client available at http://localhost:$_serverPort/');
      server.listen((HttpRequest request) async {
        _log('HTTP ${request.method} ${request.uri.path}');
        if (request.method == 'POST' && request.uri.path == '/append-queue') {
          final String content = await utf8.decoder.bind(request).join();
          _log('Received append-queue payload: $content');
          try {
            final Map<String, dynamic> payload =
                jsonDecode(content) as Map<String, dynamic>;
            final String? url = payload['url'] as String?;
            final String? deviceName = payload['deviceName'] as String?;
            if (url == null || deviceName == null) {
              request.response.statusCode = HttpStatus.badRequest;
              request.response.headers.add('Access-Control-Allow-Origin', '*');
              await request.response.close();
              _log('Responded 400 due to missing url/deviceName');
              return;
            }
            try {
              await _addUrl(url, deviceName);
            } catch (e) {
              if (e == 'Invalid YouTube video ID') {
                request.response.statusCode = HttpStatus.unprocessableEntity;
                request.response.headers.add('Access-Control-Allow-Origin', '*');
                await request.response.close();
                _log('Responded 422 invalid YouTube URL');
                return;
              }
            }
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType.json;
            request.response.headers.add('Access-Control-Allow-Origin', '*');
            request.response.write(jsonEncode({'ok': true}));
            await request.response.close();
            _log('Responded 200 OK to append-queue');
          } catch (e) {
            request.response.statusCode = HttpStatus.internalServerError;
            _log('Server error handling append-queue: $e');
            request.response.headers.add('Access-Control-Allow-Origin', '*');
            await request.response.close();
          }
        } else if (request.method == 'GET' && request.uri.path == '/health') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.write(jsonEncode({'status': 'ok'}));
          await request.response.close();
          _log('Responded to /health');
        } else if (request.method == 'GET' && request.uri.path == '/') {
          // Serve the web client
          await _serveWebClient(request);
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          await request.response.close();
          _log('Responded 404 ${request.uri.path}');
        }
      });
    } catch (err) {
      _log('Error starting server: $err');
    }
  }

  Future<String?> _fetchYouTubeTitle(String url) async {
    try {
      final Uri oembed = Uri.parse(
        'https://www.youtube.com/oembed?url=${Uri.encodeComponent(url)}&format=json',
      );
      final http.Response res = await http
          .get(oembed)
          .timeout(const Duration(seconds: 5));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        return data['title'] as String?;
      }
    } catch (err) {
      print('Error fetching YouTube title: $err');
    }
    return null;
  }

  String? _parseYouTubeVideoId(String url) {
    try {
      final Uri uri = Uri.parse(url);
      final String host = uri.host.toLowerCase();
      if (host == 'youtu.be') {
        final String path = uri.path;
        if (path.isNotEmpty) {
          return path.replaceAll('/', '');
        }
      }
      if (host.endsWith('youtube.com') || host.endsWith('music.youtube.com')) {
        if (uri.path == '/watch') {
          return uri.queryParameters['v'];
        }
        if (uri.path.startsWith('/shorts/')) {
          return uri.pathSegments.length > 1 ? uri.pathSegments[1] : null;
        }
      }
    } catch (err) {
      print('Error parsing YouTube video ID: $err');
    }
    return null;
  }

  Future<void> _skip() async {
    print('Skipping: ${_nowPlaying?.title}');
    await _player.stop();
    setState(() {
      _nowPlaying = _rr.popNext();
      _queue = _rr.buildUpcomingFlattened();
      _startPlaybackForCurrent();
    });
  }

  void _remove(QueueItem item) {
    _rr.removeItem(item);
    setState(() {
      _queue = _rr.buildUpcomingFlattened();
      _startPlaybackForCurrent();
    });
  }

  Future<void> _startPlaybackForCurrent() async {
    if (!Platform.isMacOS && !Platform.isLinux) {
      _log('Start playback skipped: not desktop platform');
      return;
    }
    if (_isDownloadingOrPreparing) {
      _log('Start playback skipped: already downloading/preparing');
      return;
    }
    final current = _nowPlaying;
    if (current == null) {
      _log('Start playback skipped: nowPlaying is null');
      return;
    }
    _isDownloadingOrPreparing = true;
    try {
      _log('Start playback: id=${current.videoId} title="${current.title}"');
      final String filePath = await _downloadOrGetCachedMp3(current.videoId);
      _log('Audio file ready at: $filePath');
      // Use just_audio on both macOS & Linux (Linux via just_audio_media_kit)
      _log('AudioPlayer volume=${_player.volume}');
      await _player.setFilePath(filePath);
      if (_player.volume < 0.9) {
        await _player.setVolume(1.0);
        _log('Volume adjusted to 1.0');
      }
      await _player.play();
      _log('Playback started');
    } catch (e) {
      _log('Error playing audio: $e');
      // Skip on failure
      await _safeSkip();
    } finally {
      _isDownloadingOrPreparing = false;
    }
  }

  Future<String> _downloadOrGetCachedMp3(String videoId) async {
    final Directory appDir = await getApplicationSupportDirectory();
    final Directory audioDir = Directory('${appDir.path}/audio');
    if (!await audioDir.exists()) {
      await audioDir.create(recursive: true);
    }
    final String target = '${audioDir.path}/$videoId.mp3';
    final File f = File(target);
    if (await f.exists() && await f.length() > 1024) {
      _log('Using cached MP3: $target');
      return target;
    }
    // Reuse in-flight download for this videoId if present
    final existing = _inflightDownloads[videoId];
    if (existing != null) {
      _log('Reusing in-flight download for video=$videoId');
      return await existing;
    }
    // Use yt-dlp to download audio (deduplicated via in-flight map)
    _log('Downloading via yt-dlp to $target for video=$videoId');
    final Future<String> future = (() async {
      final ProcessResult result = await Process.run(
        'yt-dlp',
        [
          '-f', 'bestaudio',
          '-x', '--audio-format', 'mp3',
          '--no-part', // avoid per-fragment part files that can error on rename
          '--retries', '5', '--fragment-retries', '5',
          '--http-chunk-size', '10M',
          '-o', target,
          'https://www.youtube.com/watch?v=$videoId',
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

  Future<void> _safeSkip() async {
    if (_isSkipping) return;
    _isSkipping = true;
    try {
      _log('Safe skip requested');
      await _skip();
    } finally {
      _isSkipping = false;
    }
  }

  Future<void> _serveWebClient(HttpRequest request) async {
    try {
      // Try to find the web client HTML file
      final String exePath = Platform.resolvedExecutable;
      final String exeDir = File(exePath).parent.path;
      
      // Try different possible locations for the web client
      final List<String> possiblePaths = [
        '${File(exeDir).parent.path}/web/index.html', // Development: project/web/
        '$exeDir/web/index.html', // Built app: next to executable
        '${Directory.current.path}/web/index.html', // Current directory
      ];
      
      File? htmlFile;
      for (final path in possiblePaths) {
        final file = File(path);
        if (await file.exists()) {
          htmlFile = file;
          _log('Found web client at: $path');
          break;
        }
      }
      
      if (htmlFile != null) {
        final String content = await htmlFile.readAsString();
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.write(content);
        await request.response.close();
        _log('Served web client');
      } else {
        // Fallback: return a simple inline HTML form
        request.response.statusCode = HttpStatus.ok;
        request.response.headers.contentType = ContentType.html;
        request.response.headers.add('Access-Control-Allow-Origin', '*');
        request.response.write(_getFallbackWebClient());
        await request.response.close();
        _log('Served fallback web client');
      }
    } catch (e) {
      _log('Error serving web client: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      await request.response.close();
    }
  }

  String _getFallbackWebClient() {
    return '''
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Cosmos Queue</title>
    <style>
        body { font-family: system-ui; max-width: 500px; margin: 50px auto; padding: 20px; }
        h1 { color: #333; }
        input, button { width: 100%; padding: 10px; margin: 10px 0; font-size: 16px; }
        button { background: #667eea; color: white; border: none; border-radius: 5px; cursor: pointer; }
        button:hover { background: #5a67d8; }
        .status { margin-top: 10px; padding: 10px; border-radius: 5px; }
        .success { background: #d4edda; color: #155724; }
        .error { background: #f8d7da; color: #721c24; }
    </style>
</head>
<body>
    <h1>🎵 Cosmos Queue</h1>
    <form id="form">
        <input type="url" id="url" placeholder="YouTube URL" required>
        <input type="text" id="device" placeholder="Your Name" value="Web" required>
        <button type="submit">Add to Queue</button>
    </form>
    <div id="status"></div>
    <script>
        document.getElementById('form').onsubmit = async (e) => {
            e.preventDefault();
            const status = document.getElementById('status');
            try {
                const response = await fetch('/append-queue', {
                    method: 'POST',
                    headers: {'Content-Type': 'application/json'},
                    body: JSON.stringify({
                        url: document.getElementById('url').value,
                        deviceName: document.getElementById('device').value
                    })
                });
                if (response.ok) {
                    status.className = 'status success';
                    status.textContent = '✅ Added to queue!';
                    document.getElementById('url').value = '';
                } else {
                    throw new Error('Server error');
                }
            } catch (err) {
                status.className = 'status error';
                status.textContent = '❌ Error: ' + err.message;
            }
        };
    </script>
</body>
</html>
    ''';
  }
}
