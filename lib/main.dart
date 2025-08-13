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
  final AudioPlayer _player = AudioPlayer();
  bool _isDownloadingOrPreparing = false;
  String _lastSkippedFilePath = '';

  static const int _serverPort = 5283;

  @override
  void initState() {
    super.initState();
    _initDeviceDisplayName();
    if (Platform.isMacOS || Platform.isLinux) {
      _startServer();
    } else {
      _initShareListeners();
    }
    _player.playerStateStream.listen((state) async {
      var audioUri = (_player.audioSource as UriAudioSource).uri.toString();
      if (state.processingState == ProcessingState.completed && audioUri != _lastSkippedFilePath) {
        _lastSkippedFilePath = audioUri;
        await _skip();
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
                                          await _skip();
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
    print('Sending link to host: $url');
    final body = jsonEncode({'url': url, 'deviceName': deviceName});
    try {
      final res = await http
          .post(
            Uri.parse('http://192.168.1.110:5283/append-queue'),
            headers: headers,
            body: body,
          )
          .timeout(const Duration(seconds: 3));
      if (res.statusCode >= 200 && res.statusCode < 300) {
        print('Successfully sent link to host');
        if (Platform.isAndroid) {
          const MethodChannel channel = MethodChannel('cosmos_queue/share');
          channel.invokeMethod('completeShare');
        }
      }
    } catch (err) {
      print('Error sending link to host: $err');
    }
  }

  Future<void> _addUrl(String url, String deviceName) async {
    final String? videoId = _parseYouTubeVideoId(url);
    if (videoId == null) {
      throw 'Invalid YouTube video ID';
    }
    final String title =
        await _fetchYouTubeTitle(url) ?? 'YouTube Video';
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
      final String? currentNowPlayingId = _nowPlaying?.videoId;
      if (currentNowPlayingId != null && currentNowPlayingId != previousNowPlayingId) {
        _startPlaybackForCurrent();
      }
    });

    // start downloading in advanced
    _downloadOrGetCachedMp3(videoId);
  }

  Future<void> _startServer() async {
    try {
      final HttpServer server = await HttpServer.bind(
        InternetAddress.anyIPv4,
        _serverPort,
      );
      _server = server;
      server.listen((HttpRequest request) async {
        if (request.method == 'POST' && request.uri.path == '/append-queue') {
          final String content = await utf8.decoder.bind(request).join();
          print('Received link from host: $content');
          try {
            final Map<String, dynamic> payload =
                jsonDecode(content) as Map<String, dynamic>;
            final String? url = payload['url'] as String?;
            final String? deviceName = payload['deviceName'] as String?;
            if (url == null || deviceName == null) {
              request.response.statusCode = HttpStatus.badRequest;
              request.response.headers.add('Access-Control-Allow-Origin', '*');
              await request.response.close();
              return;
            }
            try {
              await _addUrl(url, deviceName);
            } catch (e) {
              if (e == 'Invalid YouTube video ID') {
                request.response.statusCode = HttpStatus.unprocessableEntity;
                request.response.headers.add('Access-Control-Allow-Origin', '*');
                await request.response.close();
                return;
              }
            }
            request.response.statusCode = HttpStatus.ok;
            request.response.headers.contentType = ContentType.json;
            request.response.headers.add('Access-Control-Allow-Origin', '*');
            request.response.write(jsonEncode({'ok': true}));
            await request.response.close();
          } catch (e) {
            request.response.statusCode = HttpStatus.internalServerError;
            print('Error sending link to host: $e');
            request.response.headers.add('Access-Control-Allow-Origin', '*');
            await request.response.close();
          }
        } else if (request.method == 'GET' && request.uri.path == '/health') {
          request.response.statusCode = HttpStatus.ok;
          request.response.headers.contentType = ContentType.json;
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          request.response.write(jsonEncode({'status': 'ok'}));
          await request.response.close();
        } else {
          request.response.statusCode = HttpStatus.notFound;
          request.response.headers.add('Access-Control-Allow-Origin', '*');
          await request.response.close();
        }
      });
    } catch (err) {
      print('Error starting server: $err');
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
    if (!Platform.isMacOS && !Platform.isLinux) return;
    if (_isDownloadingOrPreparing) return;
    final current = _nowPlaying;
    if (current == null) return;
    _isDownloadingOrPreparing = true;
    try {
      print('Starting playback for: ${current.title}');
      final String filePath = await _downloadOrGetCachedMp3(current.videoId);
      await _player.setFilePath(filePath);
      await _player.play();
    } catch (e) {
      print('Error playing audio: $e');
      // Skip on failure
      await _skip();
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
      return target;
    }
    // Use yt-dlp to download audio
    final ProcessResult result = await Process.run(
      '/opt/homebrew/bin/yt-dlp',
      ['-f', 'bestaudio', '-x', '--audio-format', 'mp3', '-o', target, 'https://www.youtube.com/watch?v=$videoId'],
      runInShell: true,
    );

    if (result.exitCode != 0) {
      throw 'Download failed: ${result.stderr}';
    }
    if (!await f.exists()) {
      throw 'File not found after download';
    }
    return target;
  }
}
