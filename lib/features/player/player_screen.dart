import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/preferences.dart';
import '../../playback/device_controls.dart';
import '../../playback/media_kit_engine.dart';
import '../../playback/playback_session.dart';
import '../detail/detail_sheet.dart';
import '../settings/settings_screen.dart';
import '../shared/widgets.dart';
import 'gesture_controller.dart';
import 'player_gesture_surface.dart';
import 'episode_pager.dart';
import 'player_controls.dart';

enum _Panel { menu, episodes, speed, quality, guide, exit }

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({super.key, required this.drama, this.initialEpisode});
  final Drama drama;
  final int? initialEpisode;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final AppController _app;
  late final MediaKitEngine _engine;
  late final PlaybackSession _session;
  late final DeviceControls _device;
  late final PlayerGestureController _gestures;
  bool _topVisible = true;
  bool _railOpen = false;
  bool _locked = false;
  bool _landscape = false;
  Future<void> _orientationChange = Future.value();
  bool _sheetOpen = false;
  bool _hint = false;
  bool _foreground = true;
  bool _awake = false;
  bool _closing = false;
  bool _paging = false;
  bool get _verticalPaging => Platform.isAndroid && !_landscape;
  GestureHud? _hud;
  Duration? _railPreview;
  String? _message;
  Timer? _topTimer;
  Timer? _railTimer;
  Timer? _messageTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = AppScope.read(context);
    _engine = MediaKitEngine(preferences: _app.preferences);
    _device = DeviceControls(_engine);
    _session = PlaybackSession(app: _app, engine: _engine, drama: widget.drama);
    _hint = !_app.preferences.gestureHintSeen;
    if (_hint) _session.hold('guide');
    _session.addListener(_sessionChanged);
    _gestures = PlayerGestureController(
      onTap: () {
        if (_landscape) {
          if (_topVisible) {
            setState(() => _topVisible = false);
          } else {
            _showTop();
          }
        } else {
          _session.togglePlay();
          _showTop();
        }
        _haptic();
      },
      onMenu: () => unawaited(_openPanel(_Panel.menu)),
      onBoost: _session.boost,
      onSeek: (target) => unawaited(_session.seek(target)),
      onScrubState: (active) =>
          active ? _session.hold('scrub') : _session.release('scrub'),
      onHud: _showHud,
      onHaptic: _haptic,
      readPosition: () => _session.position,
      readDuration: () => _session.duration,
    );
    unawaited(_prepareDevice());
    unawaited(_session.initialize(initialEpisode: widget.initialEpisode));
    _showTop(rebuild: false);
  }

  Future<void> _prepareDevice() async {
    if (Platform.isAndroid) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
      ]);
      if (!mounted || _closing) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    await _device.initialize();
    if (mounted && !_closing) setState(() {});
  }

  void _sessionChanged() {
    if (!mounted || _closing) return;
    final awake =
        _foreground &&
        (_session.playing || _session.buffering) &&
        !_sheetOpen &&
        !_hint;
    if (awake != _awake) {
      _awake = awake;
      unawaited(_device.keepAwake(awake));
    }
    setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) return;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _session.release('background');
    } else {
      _gestures.cancel();
      _session.boost(false);
      _session.hold('background');
    }
    _sessionChanged();
  }

  @override
  void didHaveMemoryPressure() =>
      _session.trimPreload(cooldown: const Duration(minutes: 1));

  void _pagingChanged(bool paging) {
    if (!mounted || _closing || _paging == paging) return;
    setState(() => _paging = paging);
    if (paging) {
      _gestures.cancel();
      _session.hold('paging');
    } else {
      _session.release('paging');
    }
  }

  void _selectPage(int index) {
    if (_closing || _locked || !_foreground || index == _session.currentIndex) {
      return;
    }
    _haptic();
    _showTop();
    unawaited(_session.playEpisode(index));
  }

  void _haptic() {
    if (_app.preferences.haptics) unawaited(HapticFeedback.selectionClick());
  }

  Widget _video(VideoController controller) => IgnorePointer(
    child: Video(
      key: ObjectKey(controller),
      controller: controller,
      fit: BoxFit.contain,
      controls: NoVideoControls,
      pauseUponEnteringBackgroundMode: false,
      resumeUponEnteringForegroundMode: false,
      wakelock: false,
    ),
  );

  Widget _buildVideoSurface() => ValueListenableBuilder<int>(
    valueListenable: _engine.videoChanges,
    builder: (context, _, _) {
      if (!_verticalPaging || _session.episodes.isEmpty) {
        return _video(_engine.video);
      }
      return EpisodePager(
        index: _session.currentIndex,
        count: _session.episodes.length,
        enabled:
            !_locked &&
            !_sheetOpen &&
            !_hint &&
            _foreground &&
            _railPreview == null &&
            _hud?.kind != GestureHudKind.boost &&
            _hud?.kind != GestureHudKind.seek,
        onSelected: _selectPage,
        onScrollingChanged: _pagingChanged,
        itemBuilder: (context, index) {
          final episode = _session.episodes[index];
          final controller = _engine.videoForEpisode(episode.id);
          return RepaintBoundary(
            key: ValueKey(episode.id),
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Colors.black),
                if (controller != null)
                  _video(controller)
                else
                  Opacity(
                    opacity: .5,
                    child: CoverImage(
                      drama: _session.drama,
                      fit: BoxFit.contain,
                    ),
                  ),
                if (index != _session.currentIndex || _paging)
                  Positioned(
                    left: 24,
                    right: 24,
                    bottom: 40,
                    child: Text(
                      '${_session.drama.title} · ${episode.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        shadows: [Shadow(blurRadius: 8)],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      );
    },
  );

  void _showTop({bool rebuild = true}) {
    _topTimer?.cancel();
    _topVisible = true;
    if (rebuild && mounted) setState(() {});
    _topTimer = Timer(const Duration(seconds: 3), () {
      if (_landscape && (!_session.playing || _railPreview != null)) return;
      if (mounted && !_closing) setState(() => _topVisible = false);
    });
  }

  void _showRail() {
    _haptic();
    setState(() => _railOpen = true);
    _bumpRail();
  }

  void _bumpRail() {
    _railTimer?.cancel();
    _railTimer = Timer(const Duration(milliseconds: 4500), () {
      if (mounted && _railPreview == null) setState(() => _railOpen = false);
    });
  }

  void _showHud(GestureHud? hud) {
    if (!mounted || _closing) return;
    setState(() => _hud = hud);
  }

  void _tell(String message) {
    if (!mounted || _closing || _locked) return;
    _messageTimer?.cancel();
    setState(() => _message = message);
    _messageTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _message = null);
    });
  }

  void _changeEpisode(bool next) {
    if (_session.episodes.isEmpty) return;
    if (next && !_session.canNext) {
      _tell('已经是最后一集了');
      return;
    }
    if (!next && !_session.canPrevious) {
      _tell('已经是第一集了');
      return;
    }
    _showTop();
    unawaited(next ? _session.next() : _session.previous());
    _bumpRail();
  }

  void _setLocked(bool value) {
    _gestures.cancel();
    _cancelSeek();
    _messageTimer?.cancel();
    _haptic();
    setState(() {
      _locked = value;
      _railOpen = false;
      _hud = null;
      _message = null;
    });
    if (!value) {
      if (_landscape) {
        _showTop();
      } else {
        _showRail();
      }
    }
  }

  Future<void> _setLandscape(bool value) async {
    if (_closing || _locked) return;
    _gestures.cancel();
    _cancelSeek();
    _pagingChanged(false);
    setState(() {
      _landscape = value;
      _railOpen = false;
      _hud = null;
    });
    _showTop();
    _orientationChange = _orientationChange.then((_) async {
      if (!mounted || _closing || !Platform.isAndroid) return;
      await SystemChrome.setPreferredOrientations(
        _landscape
            ? [
                DeviceOrientation.landscapeLeft,
                DeviceOrientation.landscapeRight,
              ]
            : [DeviceOrientation.portraitUp],
      );
    });
    await _orientationChange;
  }

  void _back() {
    if (_landscape) {
      unawaited(_setLandscape(false));
    } else {
      Navigator.of(context).pop();
    }
  }

  void _dismissHint() {
    _app.setPreferences(_app.preferences.copyWith(gestureHintSeen: true));
    setState(() => _hint = false);
    _session.release('guide');
    _showTop();
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _topTimer?.cancel();
    _railTimer?.cancel();
    _messageTimer?.cancel();
    _gestures.dispose();
    _session.removeListener(_sessionChanged);
    _session.dispose();
    unawaited(_device.dispose());
    if (Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final right = app.preferences.railSide == RailSide.right;
    final displayed =
        _railPreview ??
        (_hud?.kind == GestureHudKind.seek
            ? _hud!.position
            : _session.position);
    final fraction = _session.duration.inMilliseconds <= 0
        ? 0.0
        : (displayed.inMilliseconds / _session.duration.inMilliseconds).clamp(
            0.0,
            1.0,
          );
    return Theme(
      data: ReelTheme.make(Brightness.dark),
      child: PopScope(
        canPop: !_locked && !_landscape,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) {
            _closing = true;
            _gestures.cancel();
            unawaited(_session.close());
          } else if (_locked) {
            _setLocked(false);
          } else if (_landscape) {
            unawaited(_setLandscape(false));
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final size = constraints.biggest;
              return Stack(
                fit: StackFit.expand,
                children: [
                  Semantics(
                    label: _landscape
                        ? '播放器触控区域，单击显示控制栏'
                        : '播放器触控区域，单击播放或暂停，上下滚动切换剧集',
                    button: true,
                    onTap: _locked || _sheetOpen || _hint || !_foreground
                        ? null
                        : _gestures.tap,
                    child: PlayerGestureSurface(
                      key: const ValueKey('player-gesture-surface'),
                      controller: _gestures,
                      enabled: !_sheetOpen && !_hint && _foreground,
                      locked: _locked,
                      landscape: _landscape,
                      sensitivity: app.preferences.sensitivity,
                      child: _buildVideoSurface(),
                    ),
                  ),
                  if (!_device.applicationBrightnessAvailable)
                    IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: (1 - _device.brightness) * .65,
                        ),
                      ),
                    ),
                  if (_session.showLoading && !_paging)
                    IgnorePointer(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 30,
                              height: 30,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2.5,
                              ),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              _session.loadingDetail
                                  ? '正在加载短剧…'
                                  : _session.resolving
                                  ? (_session.loadingMessage ?? '正在加载本集…')
                                  : '正在缓冲…',
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (!_session.playing &&
                      !_session.buffering &&
                      !_session.loadingDetail &&
                      _session.error == null &&
                      !_paging &&
                      !_sheetOpen &&
                      !_hint)
                    IgnorePointer(
                      child: Center(
                        child: _glass(
                          radius: 38,
                          child: const Padding(
                            padding: EdgeInsets.all(19),
                            child: Icon(
                              Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 34,
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_session.error != null && !_hint && !_paging)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.all(34),
                        child: _glass(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.cloud_off_outlined,
                                  size: 32,
                                  color: Colors.white70,
                                ),
                                const SizedBox(height: 14),
                                Text(
                                  _session.error!,
                                  textAlign: TextAlign.center,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 14,
                                    height: 1.6,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                FilledButton.icon(
                                  onPressed: _session.retry,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 19,
                                  ),
                                  label: const Text('重新播放'),
                                ),
                                if (_session.canNext)
                                  TextButton(
                                    onPressed: () => _changeEpisode(true),
                                    child: const Text('试试下一集'),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      ignoring: !_topVisible || _locked || _hint || _sheetOpen,
                      child: AnimatedOpacity(
                        opacity: _topVisible && !_hint && !_locked ? 1 : 0,
                        duration: const Duration(milliseconds: 240),
                        child: Container(
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xAA000000), Colors.transparent],
                            ),
                          ),
                          child: SafeArea(
                            bottom: false,
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(6, 12, 12, 32),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  IconButton(
                                    tooltip: _landscape ? '切回竖屏' : '返回剧库',
                                    onPressed: _back,
                                    icon: const Icon(
                                      Icons.arrow_back_rounded,
                                      color: Colors.white,
                                      size: 23,
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.only(top: 6),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            _session.drama.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              color: Colors.white,
                                              fontSize: 15.5,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 5),
                                          Text(
                                            '第 ${_session.episode?.index ?? widget.initialEpisode ?? 1} / ${_session.episodes.isEmpty ? widget.drama.episodeCount : _session.episodes.length} 集 · ${_session.currentQuality}${_session.rate == 1 ? '' : ' · ${_session.rate}x'}',
                                            style: const TextStyle(
                                              color: Colors.white70,
                                              fontSize: 11.5,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  IconButton.filledTonal(
                                    key: const ValueKey('player-menu'),
                                    tooltip: '播放菜单',
                                    style: IconButton.styleFrom(
                                      backgroundColor: Colors.white.withValues(
                                        alpha: .14,
                                      ),
                                    ),
                                    onPressed: () => _openPanel(_Panel.menu),
                                    icon: const Icon(
                                      Icons.more_horiz_rounded,
                                      size: 22,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (!_landscape && !_railOpen && !_locked && !_hint)
                    Positioned(
                      top: (size.height - 64) / 2,
                      left: right ? null : 0,
                      right: right ? 0 : null,
                      child: _buildHandle(right),
                    ),
                  if (_locked)
                    Positioned(
                      top: (size.height - 48) / 2,
                      left: right ? null : 12,
                      right: right ? 12 : null,
                      child: PlayerLockButton(
                        onUnlock: () => _setLocked(false),
                      ),
                    ),
                  if (!_landscape && _railOpen && !_locked && !_hint)
                    Positioned(
                      top: 50,
                      bottom: 50,
                      left: right ? null : 10,
                      right: right ? 10 : null,
                      child: Center(
                        child: _buildRail(context, fraction, displayed, right),
                      ),
                    ),
                  if (_landscape && !_locked && !_hint)
                    Positioned(
                      left: 18,
                      right: 18,
                      bottom: 12,
                      child: SafeArea(
                        top: false,
                        child: IgnorePointer(
                          ignoring: !_topVisible || _sheetOpen,
                          child: AnimatedOpacity(
                            opacity: _topVisible && !_sheetOpen ? 1 : 0,
                            duration: const Duration(milliseconds: 220),
                            child: _buildLandscapeControls(fraction, displayed),
                          ),
                        ),
                      ),
                    ),
                  if (_hud != null && !_hint && !_locked)
                    IgnorePointer(child: _buildHud()),
                  if (_message != null && !_hint && !_locked)
                    Positioned(
                      left: 35,
                      right: 35,
                      bottom: 70,
                      child: IgnorePointer(
                        child: Center(
                          child: _glass(
                            radius: 18,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 17,
                                vertical: 11,
                              ),
                              child: Text(
                                _message!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (!_hint && !_landscape)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: IgnorePointer(
                        child: LinearProgressIndicator(
                          value: fraction,
                          minHeight: 2,
                          backgroundColor: Colors.white12,
                          color: Colors.white60,
                        ),
                      ),
                    ),
                  if (_hint)
                    ColoredBox(
                      color: Colors.black.withValues(alpha: .72),
                      child: Center(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(24),
                          child: _glass(
                            child: Padding(
                              padding: const EdgeInsets.all(22),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.touch_app_outlined,
                                    color: ReelTheme.gold,
                                    size: 30,
                                  ),
                                  const SizedBox(height: 12),
                                  const Text(
                                    '手势操作说明',
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  GestureGuide(landscape: _landscape),
                                  const SizedBox(height: 18),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton(
                                      key: const ValueKey(
                                        'dismiss-gesture-guide',
                                      ),
                                      onPressed: _dismissHint,
                                      child: const Text('开始观看'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  bool get _canSeek => _session.ready && _session.duration > Duration.zero;

  void _seekStart(double value) {
    _gestures.cancel();
    _railTimer?.cancel();
    _topTimer?.cancel();
    _session.hold('rail');
    setState(() => _railPreview = _session.position);
  }

  void _seekChanged(double value) {
    setState(
      () => _railPreview = Duration(
        milliseconds: (_session.duration.inMilliseconds * value).round(),
      ),
    );
  }

  Future<void> _seekEnd(double value) async {
    try {
      await _session.seek(
        Duration(
          milliseconds: (_session.duration.inMilliseconds * value).round(),
        ),
      );
    } finally {
      _session.release('rail');
      if (mounted && !_closing) {
        setState(() => _railPreview = null);
        if (_landscape) {
          _showTop();
        } else {
          _bumpRail();
        }
      }
    }
  }

  void _cancelSeek() {
    _session.release('rail');
    if (_railPreview != null && mounted && !_closing) {
      setState(() => _railPreview = null);
    }
  }

  Widget _buildRail(
    BuildContext context,
    double fraction,
    Duration displayed,
    bool right,
  ) => PortraitPlayerControls(
    playing: _session.playing,
    episode: _session.episode?.index ?? 1,
    episodeCount: _session.episodes.length,
    position: displayed,
    duration: _session.duration,
    value: fraction,
    right: right,
    onCollapse: () => setState(() => _railOpen = false),
    onPrevious: _session.canPrevious ? () => _changeEpisode(false) : null,
    onPlayPause: () {
      _session.togglePlay();
      _bumpRail();
    },
    onNext: _session.canNext ? () => _changeEpisode(true) : null,
    onLandscape: () => _setLandscape(true),
    onLock: () => _setLocked(true),
    onSeekStart: _canSeek ? _seekStart : null,
    onSeek: _canSeek ? _seekChanged : null,
    onSeekEnd: _canSeek ? _seekEnd : null,
    onSeekCancel: _cancelSeek,
  );

  Widget _buildLandscapeControls(double fraction, Duration displayed) =>
      LandscapePlayerControls(
        playing: _session.playing,
        position: displayed,
        duration: _session.duration,
        value: fraction,
        speed: _app.preferences.speed,
        onPrevious: _session.canPrevious ? () => _changeEpisode(false) : null,
        onPlayPause: () {
          _session.togglePlay();
          _showTop();
        },
        onNext: _session.canNext ? () => _changeEpisode(true) : null,
        onEpisodes: () => _openPanel(_Panel.episodes),
        onSpeed: () => _openPanel(_Panel.speed),
        onPortrait: () => _setLandscape(false),
        onLock: () => _setLocked(true),
        onSeekStart: _canSeek ? _seekStart : null,
        onSeek: _canSeek ? _seekChanged : null,
        onSeekEnd: _canSeek ? _seekEnd : null,
        onSeekCancel: _cancelSeek,
      );
  Widget _buildHandle(bool right) => Semantics(
    label: '展开播放控制栏',
    button: true,
    child: GestureDetector(
      key: const ValueKey('rail-handle'),
      behavior: HitTestBehavior.opaque,
      onTap: _showRail,
      child: SizedBox(
        width: 38,
        height: 64,
        child: Align(
          alignment: right ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 22,
            height: 52,
            decoration: BoxDecoration(
              color: const Color(0x88141820),
              border: Border.all(color: Colors.white24, width: .5),
              borderRadius: BorderRadius.horizontal(
                left: Radius.circular(right ? 14 : 0),
                right: Radius.circular(right ? 0 : 14),
              ),
            ),
            child: Center(
              child: Container(
                width: 3,
                height: 17,
                decoration: BoxDecoration(
                  color: Colors.white60,
                  borderRadius: BorderRadius.circular(4),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildHud() {
    final hud = _hud!;
    switch (hud.kind) {
      case GestureHudKind.boost:
        return Align(
          alignment: const Alignment(0, -.77),
          child: _glass(
            radius: 24,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 17, vertical: 11),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.fast_forward_rounded,
                    color: ReelTheme.darkAccent,
                    size: 20,
                  ),
                  SizedBox(width: 7),
                  Text(
                    '2.0X 快进中',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      case GestureHudKind.seek:
        return Center(
          child: _glass(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 25, vertical: 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        hud.delta.isNegative
                            ? Icons.fast_rewind_rounded
                            : Icons.fast_forward_rounded,
                        color: ReelTheme.darkAccent,
                        size: 21,
                      ),
                      const SizedBox(width: 7),
                      Text(
                        '${hud.delta.isNegative ? '' : '+'}${hud.delta.inSeconds}s',
                        style: const TextStyle(
                          color: ReelTheme.darkAccent,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: formatTime(hud.position),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 21,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        TextSpan(
                          text: ' / ${formatTime(hud.duration)}',
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 13),
                  SizedBox(
                    width: 170,
                    child: LinearProgressIndicator(
                      value: hud.duration.inMilliseconds > 0
                          ? hud.position.inMilliseconds /
                                hud.duration.inMilliseconds
                          : 0,
                      minHeight: 4,
                      borderRadius: BorderRadius.circular(4),
                      color: ReelTheme.darkAccent,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
    }
  }

  Widget _glass({required Widget child, double radius = 24}) => ClipRRect(
    borderRadius: BorderRadius.circular(radius),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xCF12141A),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: Colors.white.withValues(alpha: .13),
            width: .7,
          ),
        ),
        child: child,
      ),
    ),
  );

  Future<void> _openPanel(_Panel first) async {
    if (_sheetOpen || _hint || _locked) return;
    _gestures.cancel();
    _session.hold('sheet');
    setState(() {
      _sheetOpen = true;
      _railOpen = false;
      _hud = null;
    });
    _sessionChanged();
    _Panel? panel = first;
    try {
      while (mounted && panel != null) {
        final current = panel;
        final result = await showReelSheet<Object>(
          context,
          dark: true,
          builder: (context) => ListenableBuilder(
            listenable: _app,
            builder: (context, _) => _panelContent(context, current),
          ),
        );
        if (!mounted) break;
        if (result == _Panel.exit) {
          Navigator.of(context).pop();
          break;
        }
        if (result is _Panel) {
          panel = result;
          continue;
        }
        if (result is Episode) {
          final index = _session.episodes.indexOf(result);
          unawaited(_session.playEpisode(index));
        } else if (result is double) {
          _session.setSpeed(result);
        } else if (result is String && current == _Panel.quality) {
          unawaited(_session.setQuality(result));
        }
        panel = null;
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showTop();
      }
    }
  }

  Widget _panelContent(BuildContext context, _Panel panel) {
    switch (panel) {
      case _Panel.menu:
        final fav = _app.isFavorite(_session.drama.id);
        return SheetFrame(
          title: _session.drama.title,
          subtitle:
              '第 ${_session.episode?.index ?? 1} 集 · 共 ${_session.episodes.length} 集',
          child: Column(
            children: [
              Row(
                children: [
                  _menuAction(
                    context,
                    Icons.grid_view_rounded,
                    '选集',
                    () => Navigator.pop(context, _Panel.episodes),
                  ),
                  _menuAction(
                    context,
                    fav
                        ? Icons.favorite_rounded
                        : Icons.favorite_border_rounded,
                    fav ? '已收藏' : '收藏',
                    () {
                      _app.toggleFavorite(_session.drama);
                      _haptic();
                    },
                    active: fav,
                  ),
                  _menuAction(
                    context,
                    Icons.speed_rounded,
                    '${_app.preferences.speed}x',
                    () => Navigator.pop(context, _Panel.speed),
                  ),
                  _menuAction(
                    context,
                    Icons.high_quality_outlined,
                    _session.currentQuality,
                    () => Navigator.pop(context, _Panel.quality),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              StatefulBuilder(
                builder: (context, update) => Column(
                  children: [
                    _deviceSlider(
                      icon: Icons.brightness_6_outlined,
                      label: '亮度',
                      value: _device.brightness,
                      minimum: .03,
                      onChanged: (value) {
                        unawaited(_device.setBrightness(value));
                        update(() {});
                        if (mounted) setState(() {});
                      },
                    ),
                    _deviceSlider(
                      icon: Icons.volume_up_outlined,
                      label: '音量',
                      value: _device.volume,
                      onChanged: (value) {
                        unawaited(_device.setVolume(value));
                        update(() {});
                      },
                    ),
                  ],
                ),
              ),
              if (_session.drama.intro.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    _session.drama.intro,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      height: 1.7,
                    ),
                  ),
                ),
              _menuRow(
                context,
                Icons.touch_app_outlined,
                '手势操作说明',
                () => Navigator.pop(context, _Panel.guide),
              ),
              const SizedBox(height: 10),
              _menuRow(
                context,
                Icons.logout_rounded,
                '退出播放',
                () => Navigator.pop(context, _Panel.exit),
              ),
            ],
          ),
        );
      case _Panel.episodes:
        return SheetFrame(
          title: '选集',
          subtitle: '共 ${_session.episodes.length} 集',
          child: EpisodeGrid(
            episodes: _session.episodes,
            current: _session.episode?.index,
            onSelect: (episode) => Navigator.pop(context, episode),
          ),
        );
      case _Panel.speed:
        return SheetFrame(
          title: '倍速',
          subtitle: '当前 ${_app.preferences.speed}x · 长按临时使用 2.0x',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                for (final speed in playbackSpeeds)
                  SizedBox(
                    width: (constraints.maxWidth - 18) / 3,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: speed == _app.preferences.speed
                            ? context.colors.primary
                            : Colors.white.withValues(alpha: .08),
                      ),
                      onPressed: () => Navigator.pop(context, speed),
                      child: Text('${speed}x'),
                    ),
                  ),
              ],
            ),
          ),
        );
      case _Panel.quality:
        final choices =
            _session.options?.sources.map((s) => s.quality).toSet() ??
            {_session.currentQuality};
        return SheetFrame(
          title: '画质',
          subtitle: choices.length == 1 ? '这集提供一种画质' : '切换后会保留当前播放进度',
          child: Column(
            children: [
              for (final quality in choices)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    quality,
                    style: TextStyle(
                      fontSize: 15,
                      color: quality == _session.currentQuality
                          ? context.colors.primary
                          : Colors.white,
                    ),
                  ),
                  trailing: quality == _session.currentQuality
                      ? Icon(
                          Icons.check_rounded,
                          color: context.colors.primary,
                          size: 20,
                        )
                      : null,
                  onTap: () => Navigator.pop(context, quality),
                ),
            ],
          ),
        );
      case _Panel.guide:
        return SheetFrame(
          title: _landscape ? '横屏手势' : '手势操作说明',
          child: GestureGuide(landscape: _landscape),
        );
      case _Panel.exit:
        return const SizedBox.shrink();
    }
  }

  Widget _deviceSlider({
    required IconData icon,
    required String label,
    required double value,
    required ValueChanged<double> onChanged,
    double minimum = 0,
  }) => Row(
    children: [
      Icon(icon, color: Colors.white70, size: 20),
      const SizedBox(width: 10),
      Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      Expanded(
        child: Slider(
          value: value.clamp(minimum, 1),
          min: minimum,
          label: '$label ${(value * 100).round()}%',
          onChanged: onChanged,
        ),
      ),
      SizedBox(
        width: 36,
        child: Text(
          '${(value * 100).round()}%',
          textAlign: TextAlign.right,
          style: const TextStyle(color: Colors.white54, fontSize: 12),
        ),
      ),
    ],
  );

  Widget _menuAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback action, {
    bool active = false,
  }) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Material(
        color: active
            ? context.colors.primary.withValues(alpha: .16)
            : Colors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(19),
        child: InkWell(
          onTap: action,
          borderRadius: BorderRadius.circular(19),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 3),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: active ? context.colors.primary : Colors.white,
                ),
                const SizedBox(height: 9),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: active ? context.colors.primary : Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _menuRow(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback action,
  ) => Material(
    color: Colors.white.withValues(alpha: .08),
    borderRadius: BorderRadius.circular(18),
    child: ListTile(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      leading: Icon(icon, color: Colors.white70, size: 20),
      title: Text(
        label,
        style: const TextStyle(fontSize: 14, color: Colors.white),
      ),
      trailing: const Icon(
        Icons.chevron_right_rounded,
        color: Colors.white38,
        size: 19,
      ),
      onTap: action,
    ),
  );
}
