import 'package:flutter/material.dart';

class StatsBar extends StatelessWidget {
  final int totalPlayed;
  final Duration sessionDuration;
  final Duration totalListeningTime;
  final int queueSize;

  const StatsBar({
    super.key,
    required this.totalPlayed,
    required this.sessionDuration,
    required this.totalListeningTime,
    required this.queueSize,
  });

  String _formatDuration(Duration d) {
    String two(int n) => n.toString().padLeft(2, '0');
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) {
      return '${two(h)}:${two(m)}:${two(s)}';
    }
    return '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
      decoration: BoxDecoration(
        color: const Color(0xFF667EEA).withOpacity(0.1),
        border: const Border(
          top: BorderSide(
            color: Color(0x55667EEA),
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildStatItem(
            icon: Icons.play_circle_outline,
            label: 'Tracks Played',
            value: totalPlayed.toString(),
          ),
          _buildStatItem(
            icon: Icons.timer,
            label: 'Session Time',
            value: _formatDuration(sessionDuration),
          ),
          _buildStatItem(
            icon: Icons.headphones,
            label: 'Total Listening',
            value: _formatDuration(totalListeningTime),
          ),
          _buildStatItem(
            icon: Icons.queue_music,
            label: 'Queue Size',
            value: queueSize.toString(),
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
            const Text(
              '',
              style: TextStyle(fontSize: 0),
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
}
