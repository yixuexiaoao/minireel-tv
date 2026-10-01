import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/app_controller.dart';
import '../../app/theme.dart';
import '../../core/services/app_update_service.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/remote_key_map.dart';
import '../shared/widgets.dart';
import 'tv_focus.dart';
import 'tv_remote_key_settings.dart';
import 'tv_update_dialog.dart';

/// TV 版设置页。
/// 复用 SettingsScreen 的核心设置项，省略 TV 不适用的项（手势灵敏度）。
/// 所有交互元素用 TVFocusable 包裹。横屏居中约束宽度。
class TVSettingsScreen extends StatefulWidget {
  const TVSettingsScreen({super.key});
  @override
  State<TVSettingsScreen> createState() => _TVSettingsScreenState();
}

class _TVSettingsScreenState extends State<TVSettingsScreen> {
  Future<int>? _cache;
  bool _checkingUpdate = false;
  late final Future<PackageInfo?> _packageInfo = PackageInfo.fromPlatform()
      .then<PackageInfo?>((value) => value)
      .catchError((Object _) => null);

  Future<void> _manualCheckUpdate() async {
    setState(() => _checkingUpdate = true);
    try {
      final info = await AppUpdateService.checkForUpdate();
      if (!mounted) return;
      if (info != null && info.hasUpdate) {
        await showTVUpdateDialog(context, info);
      } else if (info != null) {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('当前已是最新版本 (v${info.currentVersion})'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            width: 320,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).clearSnackBars();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('检查更新失败，请检查网络连接'),
            duration: const Duration(seconds: 3),
            behavior: SnackBarBehavior.floating,
            width: 280,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).clearSnackBars();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('检查更新出错: $e'),
          duration: const Duration(seconds: 3),
          behavior: SnackBarBehavior.floating,
          width: 300,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    } finally {
      if (mounted) setState(() => _checkingUpdate = false);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _cache ??= AppScope.read(context).store.cacheBytes();
  }

  @override
  Widget build(BuildContext context) {
    final app = AppScope.watch(context);
    final prefs = app.preferences;
    const appearances = {
      AppAppearance.system: '跟随系统',
      AppAppearance.light: '浅色',
      AppAppearance.dark: '深色',
    };
    const accentColors = {
      'default': '经典玫红',
      'orange': '活力橙',
      'blue': '极客蓝',
      'green': '翡翠绿',
      'purple': '优雅紫',
    };
    const autoHideOptions = {
      3: '3 秒',
      5: '5 秒（推荐）',
      8: '8 秒',
      10: '10 秒',
      0: '从不自动隐藏（常显）',
    };
    const fitModes = {
      'contain': '原始比例（包含全图）',
      'cover': '撑满裁切（无黑边沉浸）',
      'fill': '拉伸全屏（画面铺满）',
    };
    const seekSteps = {
      5: '5 秒',
      10: '10 秒（推荐）',
      15: '15 秒',
      30: '30 秒',
    };
    const skipIntroOptions = {
      0: '不跳过',
      3: '跳过 3 秒',
      5: '跳过 5 秒',
      8: '跳过 8 秒',
      10: '跳过 10 秒',
    };
    const skipOutroOptions = {
      0: '不跳过',
      3: '提前 3 秒切集',
      5: '提前 5 秒切集',
      8: '提前 8 秒切集',
      10: '提前 10 秒切集',
    };
    const tvColumnOptions = {
      0: '自适应（推荐）',
      4: '大图沉浸（4 列）',
      5: '标准平衡（5 列）',
      6: '紧凑高效（6 列）',
    };
    const longPressSpeedOptions = {
      1.5: '1.5x 倍速',
      2.0: '2.0x 倍速（默认）',
      3.0: '3.0x 极速',
    };
    const hwdecOptions = {
      'auto': '自动硬解（auto-safe，低发热推荐）',
      'mediacodec': '强制硬件解码（MediaCodec）',
      'no': '纯软解兼容（绿屏/黑屏时使用）',
    };
    const bufferSizeOptions = {
      8: '8 MB（极速省流·省内存）',
      16: '16 MB（标准平衡·推荐）',
      32: '32 MB（增强缓冲·更抗抖动）',
      64: '64 MB（超大缓冲·极限抗卡顿）',
    };
    const audioBoostOptions = {
      0: '原始音量（100% 标准输出）',
      25: '清晰人声（+25% 对白更清晰）',
      50: '沉浸增强（+50% 推荐·声音更洪亮）',
      100: '极限双倍（+100% 极小音量片源放大）',
    };
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(24, 22, 24, 18),
              child: Text(
                '设置',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
            ),
            Expanded(
              child: FocusTraversalGroup(
                policy: TVFocusTraversalPolicy(),
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
                  children: [
                  _group(context, '遥控器与操作', [
                    _navRow(
                      context,
                      Icons.settings_remote_rounded,
                      '按键映射',
                      _remoteKeyLabel(app),
                      () => showRemoteKeySettings(context),
                      focusRole: 'settingsEntry',
                    ),
                    _navRow(
                      context,
                      Icons.fast_forward_rounded,
                      '遥控快进步长',
                      seekSteps[prefs.seekStepSeconds] ?? '${prefs.seekStepSeconds} 秒',
                      () => _pick(
                        context,
                        '遥控快进步长',
                        seekSteps,
                        prefs.seekStepSeconds,
                        (v) => app.setPreferences(prefs.copyWith(seekStepSeconds: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.speed_rounded,
                      '长按快进倍速',
                      longPressSpeedOptions[prefs.longPressSpeed] ?? '${prefs.longPressSpeed}x',
                      () => _pick(
                        context,
                        '长按快进倍速',
                        longPressSpeedOptions,
                        prefs.longPressSpeed,
                        (v) => app.setPreferences(prefs.copyWith(longPressSpeed: v)),
                      ),
                    ),
                    _switchRow(
                      context,
                      Icons.volume_down_rounded,
                      '按键音效反馈',
                      '遥控器移动焦点时播放清脆提示音',
                      prefs.tvFocusSound,
                      (v) => app.setPreferences(prefs.copyWith(tvFocusSound: v)),
                    ),
                  ]),
                  _group(context, '外观与主题', [
                    _navRow(
                      context,
                      Icons.dark_mode_outlined,
                      '外观模式',
                      appearances[prefs.appearance]!,
                      () => _pick(
                        context,
                        '外观模式',
                        appearances,
                        prefs.appearance,
                        (v) => app.setPreferences(prefs.copyWith(appearance: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.palette_outlined,
                      '主题配色',
                      accentColors[prefs.accentColorKey] ?? '经典玫红',
                      () => _pick(
                        context,
                        '主题配色',
                        accentColors,
                        prefs.accentColorKey,
                        (v) => app.setPreferences(prefs.copyWith(accentColorKey: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.grid_view_rounded,
                      '剧库网格列数',
                      tvColumnOptions[prefs.tvColumns] ?? '自适应',
                      () => _pick(
                        context,
                        '剧库网格列数',
                        tvColumnOptions,
                        prefs.tvColumns,
                        (v) => app.setPreferences(prefs.copyWith(tvColumns: v)),
                      ),
                    ),
                    _switchRow(
                      context,
                      Icons.blur_on_rounded,
                      '界面毛玻璃特效',
                      '关闭可跳过实时模糊着色，大幅减免老旧电视 GPU 负载与掉帧',
                      prefs.playerGlassEffect,
                      (v) => app.setPreferences(prefs.copyWith(playerGlassEffect: v)),
                    ),
                    _switchRow(
                      context,
                      Icons.text_fields_rounded,
                      '大号文字',
                      '放大界面文字，适合远距离观看',
                      prefs.largeText,
                      (v) => app.setPreferences(
                        prefs.copyWith(largeText: v),
                      ),
                    ),
                  ]),
                  _group(context, '音画与解码性能', [
                    _navRow(
                      context,
                      Icons.memory_rounded,
                      '硬件解码',
                      hwdecOptions[prefs.hardwareDecoding] ?? '自动硬解',
                      () => _pick(
                        context,
                        '硬件解码模式',
                        hwdecOptions,
                        prefs.hardwareDecoding,
                        (v) => app.setPreferences(prefs.copyWith(hardwareDecoding: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.storage_rounded,
                      '播放缓冲容量',
                      bufferSizeOptions[prefs.playerBufferSizeMb] ?? '${prefs.playerBufferSizeMb} MB',
                      () => _pick(
                        context,
                        '播放缓冲容量',
                        bufferSizeOptions,
                        prefs.playerBufferSizeMb,
                        (v) => app.setPreferences(prefs.copyWith(playerBufferSizeMb: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.volume_up_rounded,
                      '声音与人声增强',
                      audioBoostOptions[prefs.audioBoost] ?? '原始音量',
                      () => _pick(
                        context,
                        '声音与人声增强',
                        audioBoostOptions,
                        prefs.audioBoost,
                        (v) => app.setPreferences(prefs.copyWith(audioBoost: v)),
                      ),
                    ),
                  ]),
                  _group(context, '播放个性化', [
                    _navRow(
                      context,
                      Icons.timer_outlined,
                      '控制栏自动隐藏',
                      autoHideOptions[prefs.controlsAutoHideSeconds] ?? '${prefs.controlsAutoHideSeconds} 秒',
                      () => _pick(
                        context,
                        '控制栏自动隐藏时间',
                        autoHideOptions,
                        prefs.controlsAutoHideSeconds,
                        (v) => app.setPreferences(prefs.copyWith(controlsAutoHideSeconds: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.aspect_ratio_rounded,
                      '画面填充比例',
                      fitModes[prefs.videoFitMode] ?? '原始比例',
                      () => _pick(
                        context,
                        '画面填充比例',
                        fitModes,
                        prefs.videoFitMode,
                        (v) => app.setPreferences(prefs.copyWith(videoFitMode: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.skip_next_rounded,
                      '自动跳过片头',
                      skipIntroOptions[prefs.skipIntroSeconds] ?? '${prefs.skipIntroSeconds} 秒',
                      () => _pick(
                        context,
                        '自动跳过片头时长',
                        skipIntroOptions,
                        prefs.skipIntroSeconds,
                        (v) => app.setPreferences(prefs.copyWith(skipIntroSeconds: v)),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.fast_forward_rounded,
                      '自动跳过片尾',
                      skipOutroOptions[prefs.skipOutroSeconds] ?? '${prefs.skipOutroSeconds} 秒',
                      () => _pick(
                        context,
                        '自动跳过片尾时长',
                        skipOutroOptions,
                        prefs.skipOutroSeconds,
                        (v) => app.setPreferences(prefs.copyWith(skipOutroSeconds: v)),
                      ),
                    ),
                    _switchRow(
                      context,
                      Icons.playlist_play_rounded,
                      '自动播放下一集',
                      '单集播完后自动加载并播放下一集',
                      prefs.autoNext,
                      (v) => app.setPreferences(
                        prefs.copyWith(autoNext: v),
                      ),
                    ),
                    _switchRow(
                      context,
                      Icons.history_rounded,
                      '记忆观看进度',
                      '下次打开自动跳到上次看到的位置',
                      prefs.rememberProgress,
                      (v) => app.setPreferences(
                        prefs.copyWith(rememberProgress: v),
                      ),
                    ),
                    _switchRow(
                      context,
                      Icons.download_done_rounded,
                      '优先缓存下一集',
                      '当前集缓存完成后自动预加载下一集，切换更顺滑',
                      prefs.prefetchNextEpisode,
                      (v) => app.setPreferences(
                        prefs.copyWith(prefetchNextEpisode: v),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.speed_rounded,
                      '默认倍速',
                      '${prefs.speed}x',
                      () => _pick(
                        context,
                        '默认倍速',
                        {
                          0.5: '0.5x',
                          0.75: '0.75x',
                          1.0: '1.0x',
                          1.25: '1.25x',
                          1.5: '1.5x',
                          2.0: '2.0x',
                        },
                        prefs.speed,
                        (v) => app.setPreferences(
                          prefs.copyWith(speed: v),
                        ),
                      ),
                    ),
                  ]),
                  _group(context, '存储与系统', [
                    FutureBuilder<int>(
                      future: _cache,
                      builder: (context, snapshot) => _navRow(
                        context,
                        Icons.cached_rounded,
                        '清除缓存',
                        snapshot.hasData
                            ? '${_mb(snapshot.data!)} MB'
                            : '计算中…',
                        snapshot.hasData && snapshot.data! > 0
                            ? () => _clearCache(app)
                            : null,
                      ),
                    ),
                    _switchRow(
                      context,
                      Icons.system_update_rounded,
                      '启动时自动检查更新',
                      '应用启动后在后台静默检测最新版本',
                      prefs.autoCheckUpdate,
                      (v) => app.setPreferences(
                        prefs.copyWith(autoCheckUpdate: v),
                      ),
                    ),
                    _navRow(
                      context,
                      Icons.update_rounded,
                      '检查新版本',
                      _checkingUpdate ? '正在检查…' : '检查更新与升级',
                      _checkingUpdate ? null : _manualCheckUpdate,
                    ),
                    FutureBuilder<PackageInfo?>(
                      future: _packageInfo,
                      builder: (context, snapshot) {
                        final info = snapshot.data;
                        return _infoRow(
                          context,
                          Icons.info_outline_rounded,
                          '当前版本',
                          info != null
                              ? 'v${info.version} (${info.buildNumber})'
                              : '—',
                        );
                      },
                    ),
                    _infoRow(
                      context,
                      Icons.tv_rounded,
                      '设备',
                      'Android TV',
                    ),
                  ]),
                  const SizedBox(height: 24),
                  Center(
                    child: Text(
                      'MiniReel TV · 好故事，随时开场',
                      style: TextStyle(
                        color: context.muted,
                        fontSize: 12.5,
                      ),
                    ),
                  ),
                ],
              ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _group(BuildContext context, String title, List<Widget> children) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(left: 4, bottom: 10),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.muted,
                ),
              ),
            ),
            Container(
              decoration: BoxDecoration(
                color: context.colors.surface,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    children[i],
                    if (i < children.length - 1)
                      Divider(
                        height: 1,
                        indent: 56,
                        color: Theme.of(context).dividerColor,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
      );

  Widget _navRow(
    BuildContext context,
    IconData icon,
    String title,
    String value,
    VoidCallback? onTap, {
    String? focusRole,
  }) => TVFocusable(
    radius: 16,
    onTap: onTap,
    focusRole: focusRole,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          Icon(icon, size: 22, color: context.muted),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          Text(
            value,
            style: TextStyle(fontSize: 14, color: context.muted),
          ),
          const SizedBox(width: 6),
          Icon(
            Icons.chevron_right_rounded,
            size: 20,
            color: context.muted,
          ),
        ],
      ),
    ),
  );

  Widget _switchRow(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> onChanged,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    child: Row(
      children: [
        Icon(icon, size: 22, color: context.muted),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: TextStyle(fontSize: 12, color: context.muted),
              ),
            ],
          ),
        ),
        TVFocusable(
          radius: 20,
          onTap: () => onChanged(!value),
          child: Switch(
            value: value,
            onChanged: onChanged,
          ),
        ),
      ],
    ),
  );

  Widget _infoRow(
    BuildContext context,
    IconData icon,
    String title,
    String value,
  ) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      children: [
        Icon(icon, size: 22, color: context.muted),
        const SizedBox(width: 14),
        Expanded(
          child: Text(
            title,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
          ),
        ),
        Text(
          value,
          style: TextStyle(fontSize: 14, color: context.muted),
        ),
      ],
    ),
  );

  Future<void> _pick<T>(
    BuildContext context,
    String title,
    Map<T, String> options,
    T value,
    ValueChanged<T> onSelected,
  ) async {
    final result = await showReelSheet<T>(
      context,
      builder: (context) => SheetFrame(
        title: title,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options.entries)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: TVFocusable(
                  radius: 12,
                  onTap: () => Navigator.of(context).pop(option.key),
                  child: ListTile(
                    title: Text(
                      option.value,
                      style: TextStyle(
                        fontSize: 15,
                        color: option.key == value
                            ? context.colors.primary
                            : null,
                      ),
                    ),
                    trailing: option.key == value
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
    if (result != null) onSelected(result);
  }

  Future<void> _clearCache(AppController app) async {
    await app.store.clearCache();
    setState(() => _cache = app.store.cacheBytes());
  }

  String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  /// 遥控器映射行的副标题：显示是否已自定义。
  String _remoteKeyLabel(AppController app) {
    final map = app.remoteKeyMap;
    final custom = app.preferences.remoteKeyMap;
    if (custom == null) return '默认';
    // 统计已绑定的动作数
    final bound = RemoteAction.values
        .where((a) => map.countOf(a) > 0)
        .length;
    return '已自定义 $bound/7';
  }
}
