import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:venera/utils/translations.dart';

/// Prefix used by a comic source when an episode resolves to a video instead
/// of a list of image URLs. The reader consumes this marker and replaces its
/// route with [VideoPlayerPage].
const kVideoMediaMarker = 'venera-video:';

/// Decode a source-provided video marker.
///
/// Keeping this format small and JSON-based lets JavaScript sources pass a
/// signed HLS URL, a title, and any required request headers without adding a
/// video-specific API to every source.
Map<String, dynamic>? decodeVideoMediaMarker(String value) {
  if (!value.startsWith(kVideoMediaMarker)) return null;
  try {
    final decoded = jsonDecode(value.substring(kVideoMediaMarker.length));
    if (decoded is! Map || decoded['url'] is! String) return null;
    return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return null;
  }
}

/// A reusable video playback page for video-capable comic sources.
///
/// The source is deliberately kept independent from the comic-source model:
/// a source only needs to resolve a playable URL and, when necessary, its HTTP
/// headers. This keeps playback out of the image reader and makes it possible
/// to add video sources incrementally.
class VideoPlayerPage extends StatefulWidget {
  const VideoPlayerPage({
    required this.url,
    this.title,
    this.headers,
    this.autoPlay = true,
    super.key,
  });

  final String url;
  final String? title;
  final Map<String, String>? headers;
  final bool autoPlay;

  @override
  State<VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<VideoPlayerPage> {
  late final Player _player;
  late final VideoController _controller;
  Timer? _hideControlsTimer;
  bool _controlsVisible = true;
  bool _isFullscreen = false;
  bool _isSeeking = false;
  double? _seekValue;
  String? _error;

  @override
  void initState() {
    super.initState();
    _player = Player(
      configuration: PlayerConfiguration(title: widget.title ?? 'Venera'),
    );
    _controller = VideoController(_player);
    _player.stream.error.listen((error) {
      if (!mounted || error.isEmpty) return;
      setState(() => _error = error);
      _showControls();
    });
    _openMedia();
  }

  Future<void> _openMedia() async {
    setState(() => _error = null);
    try {
      await _player.open(
        Media(widget.url, httpHeaders: widget.headers),
        play: widget.autoPlay,
      );
      if (mounted) _scheduleHideControls();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
      _showControls();
    }
  }

  @override
  void dispose() {
    _hideControlsTimer?.cancel();
    _restoreSystemUi();
    _player.dispose();
    super.dispose();
  }

  void _showControls() {
    _hideControlsTimer?.cancel();
    if (!_controlsVisible && mounted) {
      setState(() => _controlsVisible = true);
    }
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _hideControlsTimer?.cancel();
    if (_error != null || _isSeeking) return;
    _hideControlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _controlsVisible = false);
    });
  }

  void _toggleControls() {
    if (_controlsVisible) {
      _hideControlsTimer?.cancel();
      setState(() => _controlsVisible = false);
    } else {
      _showControls();
    }
  }

  Future<void> _toggleFullscreen() async {
    _isFullscreen = !_isFullscreen;
    if (_isFullscreen) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await _restoreSystemUi();
    }
    if (mounted) setState(() {});
  }

  Future<void> _restoreSystemUi() async {
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }

  Future<void> _seekBy(Duration offset) async {
    final position = _player.state.position + offset;
    final duration = _player.state.duration;
    final target = position < Duration.zero
        ? Duration.zero
        : position > duration
            ? duration
            : position;
    await _player.seek(target);
    _showControls();
  }

  void _onSeekStart() {
    _hideControlsTimer?.cancel();
    setState(() {
      _isSeeking = true;
      _seekValue = _player.state.position.inMilliseconds.toDouble();
    });
  }

  void _onSeekUpdate(double value) {
    setState(() => _seekValue = value);
  }

  Future<void> _onSeekEnd() async {
    final value = _seekValue;
    setState(() {
      _isSeeking = false;
      _seekValue = null;
    });
    if (value != null) {
      await _player.seek(Duration(milliseconds: value.round()));
    }
    _scheduleHideControls();
  }

  String _formatDuration(Duration value) {
    final hours = value.inHours;
    final minutes = value.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = value.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  @override
  Widget build(BuildContext context) {
    final title = widget.title?.trim();
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          top: !_isFullscreen,
          bottom: !_isFullscreen,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Center(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Video(
                      controller: _controller,
                      controls: NoVideoControls,
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
                if (_controlsVisible)
                  _VideoControlsOverlay(
                    title: title?.isEmpty == false ? title : null,
                    player: _player,
                    error: _error,
                    isFullscreen: _isFullscreen,
                    seekValue: _seekValue,
                    formatDuration: _formatDuration,
                    onBack: () => Navigator.maybePop(context),
                    onRetry: _openMedia,
                    onPlayPause: () async {
                      await _player.playOrPause();
                      _showControls();
                    },
                    onSeekBack: () => _seekBy(const Duration(seconds: -10)),
                    onSeekForward: () => _seekBy(const Duration(seconds: 10)),
                    onSeekStart: _onSeekStart,
                    onSeekUpdate: _onSeekUpdate,
                    onSeekEnd: _onSeekEnd,
                    onFullscreen: _toggleFullscreen,
                    onInteraction: _showControls,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VideoControlsOverlay extends StatelessWidget {
  const _VideoControlsOverlay({
    required this.title,
    required this.player,
    required this.error,
    required this.isFullscreen,
    required this.seekValue,
    required this.formatDuration,
    required this.onBack,
    required this.onRetry,
    required this.onPlayPause,
    required this.onSeekBack,
    required this.onSeekForward,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
    required this.onFullscreen,
    required this.onInteraction,
  });

  final String? title;
  final Player player;
  final String? error;
  final bool isFullscreen;
  final double? seekValue;
  final String Function(Duration) formatDuration;
  final VoidCallback onBack;
  final Future<void> Function() onRetry;
  final Future<void> Function() onPlayPause;
  final Future<void> Function() onSeekBack;
  final Future<void> Function() onSeekForward;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final Future<void> Function() onSeekEnd;
  final Future<void> Function() onFullscreen;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xaa000000), Colors.transparent, Color(0xdd000000)],
          stops: [0, 0.45, 1],
        ),
      ),
      child: Column(
        children: [
          _buildTopBar(context),
          const Spacer(),
          if (error != null)
            _buildError(context)
          else
            _buildCenterControls(),
          const Spacer(),
          _buildBottomBar(context),
        ],
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 8,
        right: 8,
        top: MediaQuery.paddingOf(context).top + 4,
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Back'.tl,
            color: Colors.white,
            onPressed: onBack,
            icon: const Icon(Icons.arrow_back),
          ),
          if (title != null)
            Expanded(
              child: Text(
                title!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            const Spacer(),
          _PlaybackRateButton(player: player, onInteraction: onInteraction),
          _VolumeButton(player: player, onInteraction: onInteraction),
        ],
      ),
    );
  }

  Widget _buildCenterControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _RoundControlButton(
          icon: Icons.replay_10,
          onPressed: onSeekBack,
          tooltip: 'Back 10 seconds'.tl,
        ),
        const SizedBox(width: 28),
        StreamBuilder<bool>(
          stream: player.stream.playing,
          initialData: player.state.playing,
          builder: (context, snapshot) {
            return _RoundControlButton(
              size: 64,
              icon: snapshot.data == true ? Icons.pause : Icons.play_arrow,
              onPressed: onPlayPause,
              tooltip: (snapshot.data == true ? 'Pause' : 'Play').tl,
            );
          },
        ),
        const SizedBox(width: 28),
        _RoundControlButton(
          icon: Icons.forward_10,
          onPressed: onSeekForward,
          tooltip: 'Forward 10 seconds'.tl,
        ),
      ],
    );
  }

  Widget _buildError(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 34),
          const SizedBox(height: 10),
          Text(
            'Video could not be loaded'.tl,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
          const SizedBox(height: 6),
          Text(
            error!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 14),
          FilledButton.icon(
            onPressed: () => onRetry(),
            icon: const Icon(Icons.refresh),
            label: Text('Retry'.tl),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        bottom: MediaQuery.paddingOf(context).bottom + 12,
      ),
      child: StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (context, positionSnapshot) {
          return StreamBuilder<Duration>(
            stream: player.stream.duration,
            initialData: player.state.duration,
            builder: (context, durationSnapshot) {
              final duration = durationSnapshot.data ?? Duration.zero;
              final position = positionSnapshot.data ?? Duration.zero;
              final max = duration.inMilliseconds.toDouble();
              final value = seekValue ?? position.inMilliseconds.toDouble();
              final hasDuration = max > 0;
              final clamped = hasDuration ? value.clamp(0, max).toDouble() : 0;
              return Column(
                children: [
                  Row(
                    children: [
                      Text(
                        formatDuration(
                          Duration(milliseconds: clamped.round()),
                        ),
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                      const Text(
                        ' / ',
                        style: TextStyle(color: Colors.white60, fontSize: 12),
                      ),
                      Text(
                        formatDuration(duration),
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: isFullscreen
                            ? 'Exit full screen'.tl
                            : 'Full Screen'.tl,
                        color: Colors.white,
                        onPressed: onFullscreen,
                        icon: Icon(
                          isFullscreen
                              ? Icons.fullscreen_exit
                              : Icons.fullscreen,
                        ),
                      ),
                    ],
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 3,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 6,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 14,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white38,
                      thumbColor: Colors.white,
                      overlayColor: Colors.white24,
                    ),
                    child: Slider(
                      min: 0,
                      max: hasDuration ? max : 1,
                      value: clamped,
                      onChangeStart: hasDuration ? (_) => onSeekStart() : null,
                      onChanged: hasDuration ? onSeekUpdate : null,
                      onChangeEnd: hasDuration ? (_) => onSeekEnd() : null,
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _RoundControlButton extends StatelessWidget {
  const _RoundControlButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
    this.size = 48,
  });

  final IconData icon;
  final Future<void> Function() onPressed;
  final String tooltip;
  final double size;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, color: Colors.white),
      iconSize: size == 64 ? 34 : 28,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black45,
        fixedSize: Size.square(size),
      ),
    );
  }
}

class _PlaybackRateButton extends StatelessWidget {
  const _PlaybackRateButton({required this.player, required this.onInteraction});

  final Player player;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.rate,
      initialData: player.state.rate,
      builder: (context, snapshot) {
        final rate = snapshot.data ?? 1.0;
        return PopupMenuButton<double>(
          tooltip: 'Playback speed'.tl,
          initialValue: rate,
          onOpened: onInteraction,
          onSelected: (value) {
            player.setRate(value);
            onInteraction();
          },
          color: Theme.of(context).colorScheme.surface,
          itemBuilder: (context) => [
            for (final value in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0])
              PopupMenuItem(value: value, child: Text('${value}x')),
          ],
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '${rate}x',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        );
      },
    );
  }
}

class _VolumeButton extends StatelessWidget {
  const _VolumeButton({required this.player, required this.onInteraction});

  final Player player;
  final VoidCallback onInteraction;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<double>(
      stream: player.stream.volume,
      initialData: player.state.volume,
      builder: (context, snapshot) {
        final volume = snapshot.data ?? 100;
        return PopupMenuButton<double>(
          tooltip: 'Volume'.tl,
          onOpened: onInteraction,
          onSelected: (value) {
            player.setVolume(value);
            onInteraction();
          },
          color: Theme.of(context).colorScheme.surface,
          itemBuilder: (context) => [
            for (final value in [0.0, 25.0, 50.0, 75.0, 100.0])
              PopupMenuItem(value: value, child: Text('${value.round()}%')),
          ],
          icon: Icon(
            volume == 0 ? Icons.volume_off : Icons.volume_up,
            color: Colors.white,
          ),
        );
      },
    );
  }
}
