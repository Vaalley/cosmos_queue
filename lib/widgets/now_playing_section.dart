import 'package:flutter/material.dart';
import 'package:percent_indicator/percent_indicator.dart';

class NowPlayingSection extends StatelessWidget {
  final String? title;
  final String? addedBy;
  final String? thumbnailUrl;
  final Stream<Duration> positionStream;
  final Duration? totalDuration;

  const NowPlayingSection({
    super.key,
    required this.title,
    required this.addedBy,
    required this.thumbnailUrl,
    required this.positionStream,
    required this.totalDuration,
  });

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${two(h)}:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    final hasItem = title != null && addedBy != null;
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
          if (hasItem) ...[
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
                child: thumbnailUrl != null && thumbnailUrl!.isNotEmpty
                    ? Image.network(
                        thumbnailUrl!,
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
                      )
                    : Container(
                        color: const Color(0xFF667EEA).withOpacity(0.3),
                        child: const Icon(
                          Icons.music_note,
                          size: 80,
                          color: Colors.white,
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 30),
            Text(
              title!,
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
              'Added by ${addedBy!}',
              style: TextStyle(
                fontSize: 16,
                color: Colors.white.withOpacity(0.7),
              ),
            ),
            const SizedBox(height: 20),
            StreamBuilder<Duration>(
              stream: positionStream,
              builder: (context, snapshot) {
                final position = snapshot.data ?? Duration.zero;
                final duration = totalDuration ?? Duration.zero;

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
            const Icon(
              Icons.queue_music,
              size: 100,
              color: Colors.white,
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
}
