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
import '../../domain/models/remote_key_map.dart';
import '../../playback/device_controls.dart';
import '../../playback/media_kit_engine.dart';
import '../../playback/playback_session.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';

/// TV 版播放器。
///
/// 复用 PlaybackSession + MediaKitEngine + DeviceControls 的全部播放逻辑。
/// UI 全新：横屏固定、无手势、D-pad 控件栏。
/// 遥控器映射：
///   OK/ENTER → 播放/暂停（无焦点时）/ 激活按钮（有焦点时）
///   左右 → 焦点在控件间移动 / 长按快进快退 10s
///   上下 → 切换焦点区（视频区 ↔ 控件栏）
///   BACK → 退出播放器
///   MENU → 弹出选集/速度/画质面板
class TVPlayerScreen extends StatefulWidget {
  const TVPlayerScreen({super.key, required this.drama, this.initialEpisode});
  final Drama drama;
  final int? initialEpisode;
  @override
  State<TVPlayerScreen> createState() => _TVPlayerScreenState();
}

class _TVPlayerScreenState extends State<TVPlayerScreen>
    with WidgetsBindingObserver {
  late final AppController _app;
  late final MediaKitEngine _engine;
  late final PlaybackSession _session;
  late final DeviceControls _device;
  bool _controlsVisible = true;
  bool _sheetOpen = false;
  bool _foreground = true;
  bool _awake = false;
  bool _closing = false;
  Timer? _hideTimer;
  // seek 预览
  Duration? _seekPreview;
  // 边界提示（没有上/下集）
  String? _edgeToast;
  Timer? _edgeToastTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _app = AppScope.read(context);
    _engine = MediaKitEngine(preferences: _app.preferences);
    _device = DeviceControls(_engine);
    _session = PlaybackSession(
      app: _app,
      engine: _engine,
      drama: widget.drama,
    );
    _session.addListener(_sessionChanged);
    unawaited(_prepareDevice());
    unawaited(_session.initialize(initialEpisode: widget.initialEpisode));
    _showControls();
    // 注册调试悬浮面板动作：播放页不用焦点导航，方向键直接 seek/切集。
    tvPlayerDebugActions = TVPlayerDebugActions(
      onUp: () => _onRemoteDirection(RemoteAction.up),
      onDown: () => _onRemoteDirection(RemoteAction.down),
      onLeft: () => _onRemoteDirection(RemoteAction.left),
      onRight: () => _onRemoteDirection(RemoteAction.right),
      onOk: _togglePlay,
    );
  }

  /// 调试悬浮面板方向键入口：复用真实遥控器的方向动作逻辑。
  /// 与 [_onKey] 里的处理一致——控件隐藏时先唤出，可见时执行 seek/切集。
  void _onRemoteDirection(RemoteAction action) {
    if (_sheetOpen) return;
    final step = Duration(seconds: _app.preferences.seekStepSeconds);
    switch (action) {
      case RemoteAction.left:
        if (!_controlsVisible) {
          _showControls();
          return;
        }
        _seekBy(-step);
      case RemoteAction.right:
        if (!_controlsVisible) {
          _showControls();
          return;
        }
        _seekBy(step);
      case RemoteAction.up:
        if (!_controlsVisible) {
          _showControls();
          return;
        }
        _changeEpisode(false);
      case RemoteAction.down:
        if (!_controlsVisible) {
          _showControls();
          return;
        }
        _changeEpisode(true);
      case RemoteAction.ok:
      case RemoteAction.back:
      case RemoteAction.menu:
        break;
    }
  }

  Future<void> _prepareDevice() async {
    if (Platform.isAndroid) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      if (!mounted || _closing) return;
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    await _device.initialize();
    if (mounted && !_closing) setState(() {});
  }

  int? _currentEpisodeIndexForSkip;
  bool _introSkipped = false;
  bool _outroSkipped = false;

  void _sessionChanged() {
    if (!mounted || _closing) return;
    final awake = _foreground &&
        (_session.playing || _session.buffering) &&
        !_sheetOpen;
    if (awake != _awake) {
      _awake = awake;
      unawaited(_device.keepAwake(awake));
    }
    if (_session.playing && !_session.buffering && !_sheetOpen) {
      _ensureHideTimer();
    }
    _checkAutoSkip();
    setState(() {});
  }

  void _checkAutoSkip() {
    if (!_session.playing || _session.buffering || _session.duration <= Duration.zero) {
      return;
    }

    final epIndex = _session.currentIndex;
    if (_currentEpisodeIndexForSkip != epIndex) {
      _currentEpisodeIndexForSkip = epIndex;
      _introSkipped = false;
      _outroSkipped = false;
    }

    // 自动跳过片头
    final skipIntro = _app.preferences.skipIntroSeconds;
    if (skipIntro > 0 && !_introSkipped) {
      if (_session.position < const Duration(seconds: 1)) {
        _introSkipped = true;
        unawaited(_session.seek(Duration(seconds: skipIntro)));
        _showEdgeToast('已跳过片头 $skipIntro 秒');
        return;
      }
    }

    // 自动跳过片尾
    final skipOutro = _app.preferences.skipOutroSeconds;
    if (skipOutro > 0 &&
        !_outroSkipped &&
        _app.preferences.autoNext &&
        _session.canNext &&
        _session.duration > const Duration(seconds: 15)) {
      final remaining = _session.duration - _session.position;
      if (remaining <= Duration(seconds: skipOutro)) {
        _outroSkipped = true;
        _showEdgeToast('已跳过片尾，自动播放下一集');
        _changeEpisode(true);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_closing) return;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _session.release('background');
    } else {
      _session.boost(false);
      _session.hold('background');
      try {
        _engine.player.pause();
      } catch (_) {}
    }
    _sessionChanged();
  }

  void _showControls() {
    _controlsVisible = true;
    if (mounted) setState(() {});
    _restartHideTimer();
  }

  /// 重置并启动自动隐藏定时器（由用户交互或状态恢复触发）。
  void _restartHideTimer() {
    _hideTimer?.cancel();
    final timeout = _app.preferences.controlsAutoHideSeconds;
    if (timeout <= 0) return; // 0 表示从不自动隐藏
    _hideTimer = Timer(Duration(seconds: timeout), () {
      if (mounted &&
          !_closing &&
          _session.playing &&
          !_session.buffering &&
          !_sheetOpen &&
          _seekPreview == null) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  /// 确保自动隐藏定时器正在运行。
  /// 关键修复：若当前定时器已在倒计时中，绝不能在播放 tick 中 cancel 重置它，
  /// 否则播放时高频事件会导致定时器永远无法触发。
  void _ensureHideTimer() {
    final timeout = _app.preferences.controlsAutoHideSeconds;
    if (timeout <= 0) {
      _hideTimer?.cancel();
      return;
    }
    if (_hideTimer != null && _hideTimer!.isActive) {
      return;
    }
    _restartHideTimer();
  }

  /// 显示边界提示（没有上/下集），2 秒后自动消失。
  void _showEdgeToast(String message) {
    _edgeToast = message;
    _edgeToastTimer?.cancel();
    _edgeToastTimer = Timer(const Duration(seconds: 2), () {
      if (mounted && !_closing) {
        setState(() => _edgeToast = null);
      }
    });
    _showControls();
  }

  void _togglePlay() {
    _session.togglePlay();
    _showControls();
  }

  /// 遥控器左右键 seek
  void _seekBy(Duration delta) {
    if (_session.duration == Duration.zero) return;
    final current = _seekPreview ?? _session.position;
    var target = current + delta;
    if (target < Duration.zero) target = Duration.zero;
    if (target > _session.duration) target = _session.duration;
    _seekPreview = target;
    _showControls();
    // 防抖：停止操作 800ms 后真正 seek
    _seekDebounce?.cancel();
    _seekDebounce = Timer(const Duration(milliseconds: 800), () {
      if (_seekPreview != null && mounted) {
        unawaited(_session.seek(_seekPreview!));
        _seekPreview = null;
        setState(() {});
        if (_controlsVisible) _restartHideTimer();
      }
    });
  }

  Timer? _seekDebounce;

  void _changeEpisode(bool next) {
    if (_session.episodes.isEmpty) return;
    if (next && !_session.canNext) {
      _showEdgeToast('没有下集了');
      return;
    }
    if (!next && !_session.canPrevious) {
      _showEdgeToast('没有上集了');
      return;
    }
    unawaited(next ? _session.next() : _session.previous());
    _showControls();
  }

  Future<void> _openMenu() async {
    if (_sheetOpen) return;
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    _sessionChanged();
    try {
      await showReelSheet<void>(
        context,
        dark: true,
        builder: (context) => ListenableBuilder(
          listenable: _app,
          builder: (context, _) => _menuContent(context),
        ),
      );
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  Widget _menuContent(BuildContext context) => SheetFrame(
    title: _session.drama.title,
    subtitle:
        '第 ${_session.episode?.index ?? 1} 集 · 共 ${_session.episodes.length} 集',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            _menuAction(context, Icons.grid_view_rounded, '选集', () {
              Navigator.of(context).pop();
              _openEpisodes();
            }, autofocus: true),
            _menuAction(
              context,
              _app.isFavorite(_session.drama.id)
                  ? Icons.favorite_rounded
                  : Icons.favorite_border_rounded,
              _app.isFavorite(_session.drama.id) ? '已收藏' : '收藏',
              () => _app.toggleFavorite(_session.drama),
              active: _app.isFavorite(_session.drama.id),
            ),
            _menuAction(
              context,
              Icons.speed_rounded,
              '${_app.preferences.speed}x',
              () {
                Navigator.of(context).pop();
                _openSpeed();
              },
            ),
            _menuAction(
              context,
              Icons.high_quality_outlined,
              _session.currentQuality,
              () {
                Navigator.of(context).pop();
                _openQuality();
              },
            ),
            _menuAction(
              context,
              Icons.aspect_ratio_rounded,
              _fitLabel(_app.preferences.videoFitMode),
              () {
                Navigator.of(context).pop();
                _openFitMode();
              },
            ),
            _menuAction(
              context,
              Icons.volume_up_rounded,
              _audioBoostLabel(_app.preferences.audioBoost),
              () {
                Navigator.of(context).pop();
                _openAudioBoost();
              },
            ),
          ],
        ),
        const SizedBox(height: 14),
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
        const SizedBox(height: 10),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: () {
              Navigator.of(context).pop();
              _exit();
            },
            icon: const Icon(Icons.logout_rounded, size: 19),
            label: const Text('退出播放'),
          ),
        ),
      ],
    ),
  );

  Widget _menuAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool active = false,
    bool autofocus = false,
  }) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TVFocusable(
        radius: 14,
        onTap: onTap,
        autofocus: autofocus,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: active
                ? context.colors.primary.withValues(alpha: .12)
                : Colors.white.withValues(alpha: .05),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            children: [
              Icon(
                icon,
                size: 24,
                color: active ? context.colors.primary : Colors.white70,
              ),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12.5,
                  color: active ? context.colors.primary : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  Future<void> _openEpisodes() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<Episode>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '选集',
          subtitle: '共 ${_session.episodes.length} 集',
          child: _EpisodeGrid(
            episodes: _session.episodes,
            current: _session.episode?.index,
            onSelect: (episode) => Navigator.of(context).pop(episode),
          ),
        ),
      );
      if (result != null) {
        final index = _session.episodes.indexOf(result);
        unawaited(_session.playEpisode(index));
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  Future<void> _openSpeed() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<double>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '倍速',
          subtitle: '当前 ${_app.preferences.speed}x',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                for (final speed in playbackSpeeds)
                  SizedBox(
                    width: (constraints.maxWidth - 18) / 3,
                    child: TVFocusable(
                      radius: 12,
                      onTap: () => Navigator.of(context).pop(speed),
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          backgroundColor: speed == _app.preferences.speed
                              ? context.colors.primary
                              : Colors.white.withValues(alpha: .08),
                        ),
                        onPressed: null,
                        child: Text('${speed}x'),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
      if (result != null) _session.setSpeed(result);
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  Future<void> _openQuality() async {
    final choices = _session.options?.sources.map((s) => s.quality).toSet() ??
        {_session.currentQuality};
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    try {
      final result = await showReelSheet<String>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '画质',
          subtitle: choices.length == 1 ? '这集提供一种画质' : '切换后会保留当前播放进度',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final quality in choices)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: TVFocusable(
                    radius: 12,
                    onTap: () => Navigator.of(context).pop(quality),
                    child: ListTile(
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
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (result != null) unawaited(_session.setQuality(result));
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  String _fitLabel(String mode) => switch (mode) {
    'cover' => '撑满',
    'fill' => '拉伸',
    _ => '比例',
  };

  Future<void> _openFitMode() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    final modes = {
      'contain': '原始比例（包含全图·两侧留黑）',
      'cover': '撑满裁切（无黑边沉浸·放大填屏）',
      'fill': '拉伸铺满（画面铺满·适应屏幕）',
    };
    try {
      final result = await showReelSheet<String>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '画面比例与填充',
          subtitle: '当前：${modes[_app.preferences.videoFitMode] ?? "原始比例"}',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in modes.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TVFocusable(
                    radius: 12,
                    autofocus: entry.key == _app.preferences.videoFitMode,
                    onTap: () => Navigator.of(context).pop(entry.key),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: entry.key == _app.preferences.videoFitMode
                            ? context.colors.primary.withValues(alpha: .18)
                            : Colors.white.withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: entry.key == _app.preferences.videoFitMode
                              ? context.colors.primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry.value,
                            style: TextStyle(
                              color: entry.key == _app.preferences.videoFitMode
                                  ? context.colors.primary
                                  : Colors.white,
                              fontSize: 14.5,
                              fontWeight: entry.key == _app.preferences.videoFitMode
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          if (entry.key == _app.preferences.videoFitMode)
                            Icon(Icons.check_rounded, color: context.colors.primary, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (result != null) {
        _app.setPreferences(_app.preferences.copyWith(videoFitMode: result));
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  String _audioBoostLabel(int boost) => switch (boost) {
    25 => '人声+25%',
    50 => '增强+50%',
    100 => '倍增+100%',
    _ => '原声音量',
  };

  Future<void> _openAudioBoost() async {
    _session.hold('sheet');
    setState(() => _sheetOpen = true);
    final boosts = {
      0: '原始音量（100% 标准输出）',
      25: '清晰人声（+25% 对白清晰）',
      50: '沉浸增强（+50% 推荐·声音更洪亮）',
      100: '极限双倍（+100% 极小音量片源放大）',
    };
    try {
      final result = await showReelSheet<int>(
        context,
        dark: true,
        builder: (context) => SheetFrame(
          title: '声音与人声增强',
          subtitle: '当前：${boosts[_app.preferences.audioBoost] ?? "原始音量"}',
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final entry in boosts.entries)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: TVFocusable(
                    radius: 12,
                    autofocus: entry.key == _app.preferences.audioBoost,
                    onTap: () => Navigator.of(context).pop(entry.key),
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                      decoration: BoxDecoration(
                        color: entry.key == _app.preferences.audioBoost
                            ? context.colors.primary.withValues(alpha: .18)
                            : Colors.white.withValues(alpha: .06),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: entry.key == _app.preferences.audioBoost
                              ? context.colors.primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            entry.value,
                            style: TextStyle(
                              color: entry.key == _app.preferences.audioBoost
                                  ? context.colors.primary
                                  : Colors.white,
                              fontSize: 14.5,
                              fontWeight: entry.key == _app.preferences.audioBoost
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          if (entry.key == _app.preferences.audioBoost)
                            Icon(Icons.check_rounded, color: context.colors.primary, size: 20),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      if (result != null) {
        final newPrefs = _app.preferences.copyWith(audioBoost: result);
        _app.setPreferences(newPrefs);
        _engine.updatePreferences(newPrefs);
        unawaited(_engine.setVolume(_device.volume));
      }
    } finally {
      if (mounted && !_closing) {
        setState(() => _sheetOpen = false);
        _session.release('sheet');
        _showControls();
      }
    }
  }

  bool _cleanedUp = false;

  void _cleanup() {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _closing = true;
    try {
      _engine.player.pause();
      _engine.player.stop();
    } catch (_) {}
    unawaited(_session.close());
  }

  void _exit() {
    if (_closing) return;
    _cleanup();
    if (mounted) Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _cleanup();
    if (tvPlayerDebugActions != null) {
      tvPlayerDebugActions = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _seekDebounce?.cancel();
    _edgeToastTimer?.cancel();
    _session.removeListener(_sessionChanged);
    _session.dispose();
    unawaited(_device.dispose());
    if (Platform.isAndroid) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(SystemChrome.setPreferredOrientations([]));
    }
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (_sheetOpen) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final keyMap = _app.remoteKeyMap;
    final step = Duration(seconds: _app.preferences.seekStepSeconds);

    // BACK / ESC → 若控制栏可见则先收起控制栏，已收起则退出播放
    if (keyMap.matches(RemoteAction.back, key)) {
      if (_sheetOpen) {
        Navigator.of(context).maybePop();
      } else if (_controlsVisible) {
        setState(() => _controlsVisible = false);
        _hideTimer?.cancel();
      } else {
        _exit();
      }
      return KeyEventResult.handled;
    }
    // MENU（三条横岗等）→ 打开菜单
    if (keyMap.matches(RemoteAction.menu, key)) {
      unawaited(_openMenu());
      return KeyEventResult.handled;
    }
    // OK/ENTER/SPACE → 播放/暂停（同时确保控件可见）
    if (keyMap.matches(RemoteAction.ok, key)) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    // 左 → 快退
    if (keyMap.matches(RemoteAction.left, key)) {
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
      _seekBy(-step);
      return KeyEventResult.handled;
    }
    // 右 → 快进
    if (keyMap.matches(RemoteAction.right, key)) {
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
      _seekBy(step);
      return KeyEventResult.handled;
    }
    // 上 → 上一集（到顶提示）
    if (keyMap.matches(RemoteAction.up, key)) {
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
      _changeEpisode(false);
      return KeyEventResult.handled;
    }
    // 下 → 下一集（到底提示）
    if (keyMap.matches(RemoteAction.down, key)) {
      if (!_controlsVisible) {
        _showControls();
        return KeyEventResult.handled;
      }
      _changeEpisode(true);
      return KeyEventResult.handled;
    }
    // 媒体键
    if (key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaFastForward) {
      _seekBy(step);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.mediaRewind) {
      _seekBy(-step);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  BoxFit _getVideoBoxFit(String mode) => switch (mode) {
    'cover' => BoxFit.cover,
    'fill' => BoxFit.fill,
    _ => BoxFit.contain,
  };

  @override
  Widget build(BuildContext context) {
    final displayed = _seekPreview ?? _session.position;
    final fraction = _session.duration.inMilliseconds <= 0
        ? 0.0
        : (displayed.inMilliseconds / _session.duration.inMilliseconds)
            .clamp(0.0, 1.0);
    return Theme(
      data: ReelTheme.make(
        Brightness.dark,
        _app.preferences.accentColorKey,
      ),
      child: PopScope(
        canPop: !_sheetOpen,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _cleanup();
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Focus(
            onKeyEvent: _onKey,
            autofocus: true,
            child: Stack(
              fit: StackFit.expand,
              children: [
                // 视频层：用 videoChanges 监听引擎切换（预加载 promote 时
                // activeEngine 换成 standby 引擎，controller 引用变化），
                // 否则 Video widget 会停留在已 retire 的旧 controller 上黑屏。
                ValueListenableBuilder<int>(
                  valueListenable: _engine.videoChanges,
                  builder: (context, _, _) {
                    final controller = _engine.video;
                    return Video(
                      // key 随 controller 变化：media_kit 的 Video 在 didUpdateWidget
                      // 里不重新绑定 controller（只在 initState 绑定一次），
                      // 引擎 promote 后 controller 引用变了但 State 会复用旧
                      // controller（已 dispose）→ 黑屏。用 ObjectKey 强制重建
                      // State，新 State 绑定新 controller。
                      key: ObjectKey(controller),
                      controller: controller,
                      fit: _getVideoBoxFit(_app.preferences.videoFitMode),
                      controls: NoVideoControls,
                      pauseUponEnteringBackgroundMode: false,
                      resumeUponEnteringForegroundMode: false,
                      wakelock: false,
                    );
                  },
                ),
                // 画面任意区域点击：唤出或收起控制栏
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onTap: () {
                      if (_controlsVisible) {
                        setState(() => _controlsVisible = false);
                        _hideTimer?.cancel();
                      } else {
                        _showControls();
                      }
                    },
                  ),
                ),
                // 加载/缓冲指示
                if (_session.loadingDetail || _session.buffering)
                  IgnorePointer(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 32,
                            height: 32,
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
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // 暂停指示
                if (!_session.playing &&
                    !_session.buffering &&
                    !_session.loadingDetail &&
                    _session.error == null &&
                    !_sheetOpen)
                  IgnorePointer(
                    child: Center(
                      child: _glass(
                        radius: 42,
                        child: const Padding(
                          padding: EdgeInsets.all(22),
                          child: Icon(
                            Icons.play_arrow_rounded,
                            color: Colors.white,
                            size: 40,
                          ),
                        ),
                      ),
                    ),
                  ),
                // 错误提示
                if (_session.error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: _glass(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.cloud_off_outlined,
                                size: 36,
                                color: Colors.white70,
                              ),
                              const SizedBox(height: 16),
                              Text(
                                _session.error!,
                                textAlign: TextAlign.center,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.6,
                                ),
                              ),
                              const SizedBox(height: 22),
                              TVFocusable(
                                radius: 12,
                                onTap: _session.retry,
                                child: FilledButton.icon(
                                  onPressed: null,
                                  icon: const Icon(
                                    Icons.refresh_rounded,
                                    size: 19,
                                  ),
                                  label: const Text('重新播放'),
                                ),
                              ),
                              if (_session.canNext)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: TVFocusable(
                                    radius: 12,
                                    onTap: () => _changeEpisode(true),
                                    child: TextButton(
                                      onPressed: null,
                                      child: const Text('试试下一集'),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                // seek HUD
                if (_seekPreview != null)
                  IgnorePointer(
                    child: Center(
                      child: _glass(
                        radius: 20,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 14,
                          ),
                          child: Text(
                            '${formatTime(_seekPreview!)} / ${formatTime(_session.duration)}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 边界提示（没有上/下集）
                if (_edgeToast != null)
                  IgnorePointer(
                    child: Center(
                      child: _glass(
                        radius: 20,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 28,
                            vertical: 14,
                          ),
                          child: Text(
                            _edgeToast!,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                // 顶部信息栏 + 底部控件栏
                if (_controlsVisible && !_sheetOpen) ...[
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(
                      child: AnimatedOpacity(
                        opacity: 1,
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
                              padding: const EdgeInsets.fromLTRB(
                                24,
                                16,
                                24,
                                36,
                              ),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          _session.drama.title,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            color: Colors.white,
                                            fontSize: 18,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          '第 ${_session.episode?.index ?? 1} 集 · 共 ${_session.episodes.length} 集',
                                          style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 13,
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
                      ),
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: _bottomControls(fraction),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomControls(double fraction) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [Color(0xCC000000), Colors.transparent],
      ),
    ),
    child: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(32, 40, 32, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 进度条
            Row(
              children: [
                Text(
                  formatTime(_seekPreview ?? _session.position),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: fraction,
                      minHeight: 5,
                      backgroundColor: Colors.white24,
                      valueColor: AlwaysStoppedAnimation(
                        context.colors.primary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  formatTime(_session.duration),
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 控件按钮行（纯展示 + 鼠标可点击，不参与 D-pad 焦点）
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _ctrlButton(
                  Icons.skip_previous_rounded,
                  '上一集',
                  _session.canPrevious ? () => _changeEpisode(false) : null,
                ),
                const SizedBox(width: 20),
                _ctrlButton(
                  Icons.replay_rounded,
                  '快退 ${_app.preferences.seekStepSeconds}s',
                  () => _seekBy(Duration(seconds: -_app.preferences.seekStepSeconds)),
                ),
                const SizedBox(width: 20),
                _ctrlButton(
                  _session.playing
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded,
                  _session.playing ? '暂停' : '播放',
                  _togglePlay,
                  big: true,
                ),
                const SizedBox(width: 20),
                _ctrlButton(
                  Icons.forward_rounded,
                  '快进 ${_app.preferences.seekStepSeconds}s',
                  () => _seekBy(Duration(seconds: _app.preferences.seekStepSeconds)),
                ),
                const SizedBox(width: 20),
                _ctrlButton(
                  Icons.skip_next_rounded,
                  '下一集',
                  _session.canNext ? () => _changeEpisode(true) : null,
                ),
                const SizedBox(width: 20),
                _ctrlButton(
                  Icons.menu_rounded,
                  '菜单',
                  _openMenu,
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );

  Widget _ctrlButton(
    IconData icon,
    String label,
    VoidCallback? onTap, {
    bool big = false,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: EdgeInsets.all(big ? 18 : 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(big ? 42 : 14),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            icon,
            size: big ? 36 : 26,
            color: onTap == null ? Colors.white24 : Colors.white,
          ),
          if (!big) ...[
            const SizedBox(height: 4),
            Text(
              label,
              style: const TextStyle(color: Colors.white60, fontSize: 11),
            ),
          ],
        ],
      ),
    ),
  );

  Widget _glass({double radius = 28, required Widget child}) {
    final useGlass = _app.preferences.playerGlassEffect;
    final container = Container(
      decoration: BoxDecoration(
        color: useGlass ? const Color(0xCF12141A) : const Color(0xEE12141A),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: Colors.white12),
      ),
      child: child,
    );
    if (!useGlass) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: container,
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: container,
      ),
    );
  }
}

/// TV 版选集网格：每集用 TVFocusable 包裹。
class _EpisodeGrid extends StatelessWidget {
  const _EpisodeGrid({
    required this.episodes,
    required this.current,
    required this.onSelect,
  });
  final List<Episode> episodes;
  final int? current;
  final void Function(Episode) onSelect;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final columns = (constraints.maxWidth / 90).floor().clamp(4, 10);
      return Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final episode in episodes)
            SizedBox(
              width: (constraints.maxWidth - (columns - 1) * 8) / columns,
              child: TVFocusable(
                radius: 12,
                onTap: () => onSelect(episode),
                autofocus: episode.index == current,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: episode.index == current
                        ? context.colors.primary
                        : Colors.white.withValues(alpha: .06),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(
                    child: Text(
                      '${episode.index}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: episode.index == current
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: episode.index == current
                            ? Colors.white
                            : Colors.white70,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
