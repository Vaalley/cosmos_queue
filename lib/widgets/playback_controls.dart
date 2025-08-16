import 'package:flutter/material.dart';

class PlaybackControls extends StatefulWidget {
  final Future<void> Function()? onSkip;
  final Future<void> Function()? onPlay;
  final Future<void> Function()? onPause;
  final bool isPlaying;
  final void Function(String url) onSubmitUrl;
  final Stream<double> volumeStream;
  final void Function(double value) onVolumeChanged;

  const PlaybackControls({
    super.key,
    this.onSkip,
    this.onPlay,
    this.onPause,
    required this.isPlaying,
    required this.onSubmitUrl,
    required this.volumeStream,
    required this.onVolumeChanged,
  });

  @override
  State<PlaybackControls> createState() => _PlaybackControlsState();
}

class _PlaybackControlsState extends State<PlaybackControls> {
  final TextEditingController _urlController = TextEditingController();

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
          // Play/Pause toggle
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
                  if (widget.isPlaying) {
                    if (widget.onPause != null) {
                      await widget.onPause!();
                    }
                  } else {
                    if (widget.onPlay != null) {
                      await widget.onPlay!();
                    }
                  }
                },
                child: Container(
                  padding: const EdgeInsets.all(15),
                  child: Icon(
                    widget.isPlaying ? Icons.pause : Icons.play_arrow,
                    color: Colors.white,
                    size: 30,
                  ),
                ),
              ),
            ),
          ),

          const SizedBox(width: 20),

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
                  if (widget.onSkip != null) {
                    await widget.onSkip!();
                  }
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
              controller: _urlController,
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
                  widget.onSubmitUrl(value);
                  _urlController.clear();
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
              stream: widget.volumeStream,
              builder: (context, snapshot) {
                final volume = snapshot.data ?? 1.0;
                return Slider(
                  value: volume,
                  onChanged: (value) {
                    widget.onVolumeChanged(value);
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
}
