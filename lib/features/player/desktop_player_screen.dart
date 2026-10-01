import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../desktop/desktop_window.dart';
import '../../desktop/window_chrome.dart';
import '../../domain/models/drama.dart';
import '../../domain/models/preferences.dart';
import '../../playback/device_controls.dart';
import '../../playback/media_kit_engine.dart';
import '../../playback/playback_engine.dart';
import '../../playback/playback_session.dart';
import '../shared/widgets.dart';
import 'desktop_player_controls.dart';
import 'desktop_player_input.dart';

enum _DesktopPanel { menu, episodes, speed, quality, shortcuts }

class DesktopPlayerScreen extends StatefulWidget {
  const DesktopPlayerScreen({
    super.key,
    required this.drama,
    this.initialEpisode,
    this.engine,
    this.videoSurface,
    this.window,
  });
  final Drama drama;
  final int? initialEpisode;
  final PlaybackEngine? engine;
  final Widget? videoSurface;
  final DesktopWindow? window;

  @override
  State<DesktopPlayerScreen> createState() => _DesktopPlayerScreenState();
}

class _DesktopPlayerScreenState extends State<DesktopPlayerScreen>
    with WidgetsBindingObserver {
  late final AppController _app;
  late final PlaybackEngine _engine;
  late final PlaybackSession _session;
  late final DeviceControls _device;
  late final DesktopWindow _window;
  final _focus = FocusNode(debugLabel: 'Desktop player');
  final _episodesScroll = ScrollController();
  bool _controlsVisible = true;
  bool _overControls = false;
  bool _keyboardNavigation = false;
  bool _hidden = false;
  bool _heldForMinimize = false;
  bool _heldForSystem = false;
  bool _awake = false;
  bool _wasPlaying = false;
  bool _closing = false;
  bool _leaving = false;
  bool _allowPop = false;
  _DesktopPanel? _panel;
  Duration? _seekPreview;
  Duration? _keyboardSeek;
  late double _volume;
  double _unmutedVolume = .75;
  String? _notice;
  Timer? _hideTimer;
  Timer? _noticeTimer;
  Future<void>? _closeFuture;

  @override
  void initState() {
    super.initState();
    _app = AppScope.read(context);
    _window = widget.window ?? DesktopWindow.instance;
    _engine = widget.engine ?? MediaKitEngine(preferences: _app.preferences);
    _device = DeviceControls(_engine);
    _volume = _app.preferences.desktopVolume;
    if (_volume > 0) _unmutedVolume = _volume;
    _session = PlaybackSession(app: _app, engine: _engine, drama: widget.drama);
    _session.addListener(_sessionChanged);
    _app.addListener(_preferencesChanged);
    _window.addListener(_windowChanged);
    _window.onPlayerClose = _closeSession;
    WidgetsBinding.instance.addObserver(this);
    unawaited(_windowAction(_window.enterPlayer));
    unawaited(_prepareDevice());
    _syncPauseReasons();
    unawaited(_session.initialize(initialEpisode: widget.initialEpisode));
  }

  Future<void> _prepareDevice() async {
    await _device.initialize();
    if (!_closing) await _device.setVolume(_volume);
  }

  void _sessionChanged() {
    if (!mounted || _closing) return;
    final playing = _session.playing;
    if (_wasPlaying != playing) {
      _wasPlaying = playing;
      _showControls();
    }
    _updateAwake();
    setState(() {});
  }

  void _preferencesChanged() {
    if (_closing) return;
    _syncPauseReasons();
    final volume = _app.preferences.desktopVolume;
    if (_volume != volume) {
      _volume = volume;
      unawaited(_device.setVolume(volume));
    }
    if (mounted) setState(() {});
  }

  @override
  void didHaveMemoryPressure() =>
      _session.trimPreload(cooldown: const Duration(minutes: 1));

  void _windowChanged() {
    if (_closing) return;
    _syncPauseReasons();
    _showControls();
    _updateAwake();
    if (mounted) setState(() {});
  }

  void _syncPauseReasons() {
    final minimize =
        (_window.minimized || _hidden) && _app.preferences.pauseWhenMinimized;
    if (_heldForMinimize != minimize) {
      _heldForMinimize = minimize;
      if (minimize) {
        _session.hold('minimized');
      } else {
        _session.release('minimized');
      }
    }
    final blocked = _window.systemBlocked;
    if (_heldForSystem != blocked) {
      _heldForSystem = blocked;
      if (blocked) {
        _session.hold('system');
      } else {
        _session.release('system');
      }
    }
  }

  void _updateAwake() {
    final awake =
        !_hidden &&
        !_window.minimized &&
        !_window.systemBlocked &&
        (_session.playing || _session.buffering);
    if (_awake == awake) return;
    _awake = awake;
    unawaited(_device.keepAwake(awake));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) return;
    _hidden =
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached;
    if (state != AppLifecycleState.resumed) _cancelSeek();
    // Inactive only means focus moved to another desktop window.
    _syncPauseReasons();
    _updateAwake();
  }

  void _showControls() {
    if (!mounted || _closing) return;
    _hideTimer?.cancel();
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted ||
          _closing ||
          !_session.playing ||
          _overControls ||
          _keyboardNavigation ||
          _panel != null ||
          _seekPreview != null) {
        return;
      }
      setState(() => _controlsVisible = false);
    });
  }

  void _mouseActivity() {
    _keyboardNavigation = false;
    _showControls();
  }

  void _tell(String text) {
    if (!mounted || _closing) return;
    _noticeTimer?.cancel();
    setState(() => _notice = text);
    _noticeTimer = Timer(const Duration(milliseconds: 1100), () {
      if (mounted && !_closing) setState(() => _notice = null);
    });
  }

  Future<void> _windowAction(Future<void> Function() action) async {
    try {
      await action();
    } on Exception {
      _tell('窗口操作暂时不可用，请重试');
    }
  }

  double get _aspectRatio {
    final engine = _engine;
    if (engine is MediaKitEngine) {
      final width = engine.player.state.width;
      final height = engine.player.state.height;
      if (width != null && height != null && width > 0 && height > 0) {
        return width / height;
      }
    }
    return 9 / 16;
  }

  void _command(DesktopPlayerCommand command, bool accelerated) {
    if (_closing) return;
    _showControls();
    switch (command) {
      case DesktopPlayerCommand.playPause:
        _session.togglePlay();
      case DesktopPlayerCommand.seekBack:
        unawaited(_seekRelative(accelerated ? -15 : -5));
      case DesktopPlayerCommand.seekForward:
        unawaited(_seekRelative(accelerated ? 15 : 5));
      case DesktopPlayerCommand.volumeUp:
        _setVolume(_volume + .05);
      case DesktopPlayerCommand.volumeDown:
        _setVolume(_volume - .05);
      case DesktopPlayerCommand.fullScreen:
        unawaited(_windowAction(_window.toggleFullScreen));
      case DesktopPlayerCommand.back:
        unawaited(_escape());
      case DesktopPlayerCommand.mute:
        _toggleMute();
      case DesktopPlayerCommand.previous:
        _changeEpisode(false);
      case DesktopPlayerCommand.next:
        _changeEpisode(true);
      case DesktopPlayerCommand.episodes:
        _openPanel(_DesktopPanel.episodes);
    }
  }

  Future<void> _seekRelative(int seconds) async {
    if (!_session.ready || _session.duration <= Duration.zero) return;
    final next = Duration(
      milliseconds:
          ((_keyboardSeek ?? _session.position).inMilliseconds + seconds * 1000)
              .clamp(0, _session.duration.inMilliseconds),
    );
    _keyboardSeek = next;
    _tell(
      '${seconds > 0 ? '前进' : '后退'} ${seconds.abs()} 秒 · ${formatTime(next)}',
    );
    try {
      await _session.seek(next);
    } finally {
      if (_keyboardSeek == next) _keyboardSeek = null;
    }
  }

  void _setVolume(double value) {
    final volume = value.clamp(0.0, 1.0);
    if (_volume == volume) return;
    _volume = volume;
    if (volume > 0) _unmutedVolume = volume;
    unawaited(_device.setVolume(volume));
    _app.setPreferences(_app.preferences.copyWith(desktopVolume: volume));
    _tell(volume == 0 ? '已静音' : '音量 ${(volume * 100).round()}%');
    _showControls();
  }

  void _toggleMute() => _setVolume(_volume > 0 ? 0 : _unmutedVolume);

  void _changeEpisode(bool next) {
    _cancelSeek();
    _keyboardSeek = null;
    if (next ? !_session.canNext : !_session.canPrevious) {
      _tell(next ? '已经是最后一集' : '已经是第一集');
      return;
    }
    unawaited(next ? _session.next() : _session.previous());
    _showControls();
  }

  void _seekStart(double value) {
    _hideTimer?.cancel();
    _session.hold('scrub');
    setState(() => _seekPreview = _session.position);
  }

  void _seekChanged(double value) => setState(
    () => _seekPreview = Duration(
      milliseconds: (_session.duration.inMilliseconds * value).round(),
    ),
  );

  Future<void> _seekEnd(double value) async {
    try {
      await _session.seek(
        Duration(
          milliseconds: (_session.duration.inMilliseconds * value).round(),
        ),
      );
    } finally {
      _cancelSeek();
    }
  }

  void _cancelSeek() {
    if (_seekPreview == null) return;
    _seekPreview = null;
    _session.release('scrub');
    if (mounted && !_closing) {
      setState(() {});
      _showControls();
    }
  }

  void _openPanel(_DesktopPanel panel) {
    _cancelSeek();
    setState(() {
      _panel = panel;
      _controlsVisible = true;
    });
    _hideTimer?.cancel();
    _focus.requestFocus();
    if (panel == _DesktopPanel.episodes) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_episodesScroll.hasClients) {
          _episodesScroll.jumpTo(
            math.min(
              (_session.currentIndex ~/ 5) * 50.0,
              _episodesScroll.position.maxScrollExtent,
            ),
          );
        }
      });
    }
  }

  void _closePanel() {
    setState(() => _panel = null);
    _focus.requestFocus();
    _showControls();
  }

  Future<void> _escape() async {
    if (_panel != null) {
      _closePanel();
    } else if (_window.fullScreen) {
      await _windowAction(() => _window.setFullScreen(false));
    } else if (_window.mode != PlayerWindowMode.normal) {
      await _windowAction(
        () => _window.changePlayerMode(_window.mode, _aspectRatio),
      );
    } else {
      await _leave();
    }
  }

  Future<void> _closeSession() => _closeFuture ??= _doCloseSession();
  Future<void> _doCloseSession() async {
    _closing = true;
    _hideTimer?.cancel();
    _noticeTimer?.cancel();
    await _session.close();
    await _device.keepAwake(false);
  }

  Future<void> _leave() async {
    if (_leaving) return;
    _leaving = true;
    await _closeSession();
    await _windowAction(_window.leavePlayer);
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _closing = true;
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _noticeTimer?.cancel();
    _app.removeListener(_preferencesChanged);
    _window.removeListener(_windowChanged);
    if (_window.onPlayerClose == _closeSession) _window.onPlayerClose = null;
    _session.removeListener(_sessionChanged);
    unawaited(_closeSession());
    _session.dispose();
    unawaited(_device.dispose());
    if (!_window.closing) unawaited(_windowAction(_window.leavePlayer));
    _focus.dispose();
    _episodesScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final engine = _engine;
    final canSeek = _session.ready && _session.duration > Duration.zero;
    return Theme(
      data: ReelTheme.make(Brightness.dark),
      child: PopScope(
        canPop: _allowPop,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) unawaited(_escape());
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: DesktopPlayerInput(
            focusNode: _focus,
            onCommand: _command,
            allowPlayback: _panel == null && !_closing,
            onKeyboardNavigation: () {
              _keyboardNavigation = true;
              _showControls();
            },
            child: MouseRegion(
              cursor: _controlsVisible || _panel != null
                  ? MouseCursor.defer
                  : SystemMouseCursors.none,
              onHover: (_) => _mouseActivity(),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final compact = constraints.maxWidth < 640;
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      widget.videoSurface ??
                          (engine is MediaKitEngine
                              ? Video(
                                  key: ObjectKey(engine.video),
                                  controller: engine.video,
                                  fit: BoxFit.contain,
                                  controls: NoVideoControls,
                                  pauseUponEnteringBackgroundMode: false,
                                  resumeUponEnteringForegroundMode: false,
                                  wakelock: false,
                                )
                              : const ColoredBox(color: Colors.black)),
                      GestureDetector(
                        key: const ValueKey('desktop-video-surface'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          _focus.requestFocus();
                          _session.togglePlay();
                          _showControls();
                        },
                        onDoubleTap: () =>
                            _windowAction(_window.toggleFullScreen),
                        onSecondaryTap: () => _openPanel(_DesktopPanel.menu),
                        child: const SizedBox.expand(),
                      ),
                      if (_session.showLoading)
                        IgnorePointer(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const SizedBox(
                                  width: 28,
                                  height: 28,
                                  child: CircularProgressIndicator(
                                    color: Colors.white70,
                                    strokeWidth: 2,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  _session.loadingDetail
                                      ? '正在加载短剧…'
                                      : _session.loadingMessage ?? '正在缓冲…',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (!_session.playing &&
                          !_session.buffering &&
                          !_session.loadingDetail &&
                          _session.error == null)
                        const IgnorePointer(
                          child: Center(
                            child: Icon(
                              Icons.play_circle_outline_rounded,
                              size: 62,
                              color: Colors.white54,
                            ),
                          ),
                        ),
                      if (_session.error != null)
                        Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 420),
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.cloud_off_outlined,
                                    color: Colors.white54,
                                    size: 36,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    _session.error!,
                                    textAlign: TextAlign.center,
                                    style: const TextStyle(
                                      color: Colors.white70,
                                      height: 1.6,
                                    ),
                                  ),
                                  const SizedBox(height: 20),
                                  FilledButton.icon(
                                    onPressed: _session.retry,
                                    icon: const Icon(Icons.refresh_rounded),
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
                      Positioned(
                        top: 0,
                        left: 0,
                        right: 0,
                        child: _chrome(_topBar(compact)),
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: _chrome(
                          DesktopPlayerControls(
                            playing: _session.playing,
                            position: _seekPreview ?? _session.position,
                            duration: _session.duration,
                            buffer: _session.snapshot.buffer,
                            volume: _volume,
                            speed: _session.rate,
                            fullScreen: _window.fullScreen,
                            onPlayPause: () {
                              _session.togglePlay();
                              _showControls();
                            },
                            onPrevious: _session.canPrevious
                                ? () => _changeEpisode(false)
                                : null,
                            onNext: _session.canNext
                                ? () => _changeEpisode(true)
                                : null,
                            onVolume: _setVolume,
                            onMute: _toggleMute,
                            onEpisodes: () =>
                                _openPanel(_DesktopPanel.episodes),
                            onSpeed: () => _openPanel(_DesktopPanel.speed),
                            onMenu: () => _openPanel(_DesktopPanel.menu),
                            onFullScreen: () =>
                                _windowAction(_window.toggleFullScreen),
                            onSeekStart: canSeek ? _seekStart : null,
                            onSeek: canSeek ? _seekChanged : null,
                            onSeekEnd: canSeek ? _seekEnd : null,
                            onSeekCancel: _cancelSeek,
                          ),
                        ),
                      ),
                      if (_notice != null)
                        Positioned(
                          top: constraints.maxHeight * .24,
                          left: 20,
                          right: 20,
                          child: IgnorePointer(
                            child: Center(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: const Color(0xE01A1D24),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 18,
                                    vertical: 12,
                                  ),
                                  child: Text(
                                    _notice!,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 13,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (_panel != null) ...[
                        GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _closePanel,
                          child: const ColoredBox(color: Color(0x26000000)),
                        ),
                        Positioned(
                          top: 64,
                          right: 16,
                          bottom: 136,
                          width: math.min(350, constraints.maxWidth - 32),
                          child: Material(
                            key: const ValueKey('desktop-player-panel'),
                            color: const Color(0xFF171A22),
                            borderRadius: BorderRadius.circular(16),
                            clipBehavior: Clip.antiAlias,
                            child: Column(
                              children: [
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    18,
                                    8,
                                    8,
                                    8,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _panelTitle,
                                          style: const TextStyle(
                                            fontSize: 16,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: _closePanel,
                                        tooltip: '关闭面板 · Esc',
                                        icon: const Icon(
                                          Icons.close_rounded,
                                          size: 19,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                Expanded(child: _panelContent(context)),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _chrome(Widget child) => MouseRegion(
    onEnter: (_) {
      _overControls = true;
      _showControls();
    },
    onExit: (_) {
      _overControls = false;
      _showControls();
    },
    child: IgnorePointer(
      ignoring: !_controlsVisible || _panel != null,
      child: ExcludeFocus(
        excluding: !_controlsVisible || _panel != null,
        child: AnimatedOpacity(
          opacity: _controlsVisible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: child,
        ),
      ),
    ),
  );

  Widget _topBar(bool compact) => DecoratedBox(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xBB000000), Colors.transparent],
      ),
    ),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 4, 28),
      child: Row(
        children: [
          desktopPlayerButton(
            label: '返回剧库',
            icon: Icons.arrow_back_rounded,
            onPressed: _leave,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: (_) => _window.startDragging(),
              onDoubleTap: () => _windowAction(_window.toggleFullScreen),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _session.drama.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '第 ${_session.episode?.index ?? widget.initialEpisode ?? 1} 集 · ${_session.currentQuality}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!compact) ...[
            desktopPlayerButton(
              label: '适应视频窗口',
              icon: Icons.aspect_ratio_rounded,
              active: _window.mode == PlayerWindowMode.fit,
              onPressed: () => _windowAction(
                () => _window.changePlayerMode(
                  PlayerWindowMode.fit,
                  _aspectRatio,
                ),
              ),
            ),
            desktopPlayerButton(
              label: '迷你置顶',
              icon: Icons.picture_in_picture_alt_rounded,
              active: _window.mode == PlayerWindowMode.mini,
              onPressed: () => _windowAction(
                () => _window.changePlayerMode(
                  PlayerWindowMode.mini,
                  _aspectRatio,
                ),
              ),
            ),
            desktopPlayerButton(
              label: _window.pinned ? '取消置顶' : '窗口置顶',
              icon: Icons.push_pin_outlined,
              active: _window.pinned,
              onPressed: () => _windowAction(_window.togglePinned),
            ),
            const SizedBox(width: 12),
          ],
          if (!_window.fullScreen) WindowButtons(window: _window, light: true),
          if (_window.fullScreen)
            desktopPlayerButton(
              label: '退出全屏 · Esc',
              icon: Icons.fullscreen_exit_rounded,
              onPressed: () =>
                  _windowAction(() => _window.setFullScreen(false)),
            ),
        ],
      ),
    ),
  );

  String get _panelTitle => switch (_panel!) {
    _DesktopPanel.menu => '播放菜单',
    _DesktopPanel.episodes => '选集 · 共 ${_session.episodes.length} 集',
    _DesktopPanel.speed => '倍速',
    _DesktopPanel.quality => '画质',
    _DesktopPanel.shortcuts => '鼠标与快捷键',
  };

  Widget _panelContent(BuildContext context) {
    if (_panel == _DesktopPanel.episodes) {
      return GridView.builder(
        controller: _episodesScroll,
        padding: const EdgeInsets.all(16),
        itemCount: _session.episodes.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          mainAxisExtent: 42,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
        ),
        itemBuilder: (context, index) {
          final episode = _session.episodes[index];
          return FilledButton(
            style: FilledButton.styleFrom(
              padding: EdgeInsets.zero,
              backgroundColor: index == _session.currentIndex
                  ? context.colors.primary
                  : const Color(0xFF292D38),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: () {
              _closePanel();
              _keyboardSeek = null;
              unawaited(_session.playEpisode(index));
            },
            child: Text('${episode.index}'),
          );
        },
      );
    }
    if (_panel == _DesktopPanel.shortcuts) {
      return const SingleChildScrollView(
        padding: EdgeInsets.symmetric(horizontal: 18),
        child: DesktopShortcutGuide(),
      );
    }
    if (_panel == _DesktopPanel.speed) {
      return ListView(
        children: [
          for (final speed in playbackSpeeds)
            ListTile(
              title: Text('${speed}x'),
              trailing: speed == _session.rate
                  ? const Icon(Icons.check_rounded, color: ReelTheme.darkAccent)
                  : null,
              onTap: () {
                _session.setSpeed(speed);
                _closePanel();
              },
            ),
        ],
      );
    }
    if (_panel == _DesktopPanel.quality) {
      return ListView(
        children: [
          for (final quality
              in _session.options?.sources
                      .map((source) => source.quality)
                      .toSet() ??
                  {_session.currentQuality})
            ListTile(
              title: Text(quality),
              trailing: quality == _session.currentQuality
                  ? const Icon(Icons.check_rounded, color: ReelTheme.darkAccent)
                  : null,
              onTap: () {
                _closePanel();
                unawaited(_session.setQuality(quality));
              },
            ),
        ],
      );
    }
    final favorite = _app.isFavorite(_session.drama.id);
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: [
        _menuItem(
          Icons.playlist_play_rounded,
          '选集',
          () => _openPanel(_DesktopPanel.episodes),
        ),
        _menuItem(
          favorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          favorite ? '取消收藏' : '收藏短剧',
          () => _app.toggleFavorite(_session.drama),
        ),
        _menuItem(
          Icons.speed_rounded,
          '倍速 · ${_session.rate}x',
          () => _openPanel(_DesktopPanel.speed),
        ),
        _menuItem(
          Icons.high_quality_outlined,
          '画质 · ${_session.currentQuality}',
          () => _openPanel(_DesktopPanel.quality),
        ),
        const Divider(),
        _menuItem(
          Icons.aspect_ratio_rounded,
          _window.mode == PlayerWindowMode.fit ? '还原窗口' : '适应视频窗口',
          () {
            _closePanel();
            unawaited(
              _windowAction(
                () => _window.changePlayerMode(
                  PlayerWindowMode.fit,
                  _aspectRatio,
                ),
              ),
            );
          },
        ),
        _menuItem(
          Icons.picture_in_picture_alt_rounded,
          _window.mode == PlayerWindowMode.mini ? '退出小窗' : '迷你置顶',
          () {
            _closePanel();
            unawaited(
              _windowAction(
                () => _window.changePlayerMode(
                  PlayerWindowMode.mini,
                  _aspectRatio,
                ),
              ),
            );
          },
        ),
        _menuItem(
          Icons.push_pin_outlined,
          _window.pinned ? '取消置顶' : '窗口置顶',
          () => _windowAction(_window.togglePinned),
        ),
        _menuItem(
          Icons.keyboard_outlined,
          '鼠标与快捷键',
          () => _openPanel(_DesktopPanel.shortcuts),
        ),
        _menuItem(Icons.logout_rounded, '退出播放', _leave),
      ],
    );
  }

  Widget _menuItem(IconData icon, String label, VoidCallback action) =>
      ListTile(
        dense: true,
        leading: Icon(icon, size: 20, color: Colors.white60),
        title: Text(label, style: const TextStyle(fontSize: 13)),
        onTap: action,
      );
}
