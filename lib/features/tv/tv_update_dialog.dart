import 'package:dio/dio.dart';
import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../core/services/app_update_service.dart';
import 'tv_focus.dart';

/// 弹出 TV 端更新提示弹窗。
Future<void> showTVUpdateDialog(BuildContext context, AppUpdateInfo info) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => TVUpdateDialog(info: info),
  );
}

enum _UpdateState {
  ready,
  downloading,
  completed,
  error,
}

/// TV 版版本更新弹窗。
///
/// 特性：
/// 1. 深度适配遥控器（D-pad 焦点导航与高亮边框，默认聚焦确认/更新按钮）。
/// 2. 实时显示下载进度条、百分比与下载速度/体积。
/// 3. 下载完成后自动调起 Android 系统的应用安装器。
/// 4. 支持重试、取消与稍后提醒。
class TVUpdateDialog extends StatefulWidget {
  const TVUpdateDialog({super.key, required this.info});

  final AppUpdateInfo info;

  @override
  State<TVUpdateDialog> createState() => _TVUpdateDialogState();
}

class _TVUpdateDialogState extends State<TVUpdateDialog> {
  _UpdateState _state = _UpdateState.ready;
  double _progress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String _errorMessage = '';
  String? _savedPath;
  CancelToken? _cancelToken;

  @override
  void dispose() {
    _cancelToken?.cancel();
    super.dispose();
  }

  String _formatBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _startDownload() async {
    setState(() {
      _state = _UpdateState.downloading;
      _progress = 0.0;
      _receivedBytes = 0;
      _totalBytes = widget.info.apkSize;
      _errorMessage = '';
    });

    _cancelToken = CancelToken();

    try {
      final path = await AppUpdateService.downloadApk(
        widget.info.downloadUrl,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            if (total > 0) _totalBytes = total;
            if (_totalBytes > 0) {
              _progress = (_receivedBytes / _totalBytes).clamp(0.0, 1.0);
            }
          });
        },
        cancelToken: _cancelToken,
      );

      if (!mounted) return;
      setState(() {
        _savedPath = path;
        _state = _UpdateState.completed;
      });

      // 下载完成立即调起系统安装界面
      await AppUpdateService.installApk(path);
    } catch (e) {
      if (!mounted) return;
      if (_cancelToken?.isCancelled ?? false) {
        setState(() => _state = _UpdateState.ready);
      } else {
        setState(() {
          _state = _UpdateState.error;
          _errorMessage = e.toString().replaceFirst(RegExp(r'^Exception:\s*'), '');
        });
      }
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel();
    setState(() => _state = _UpdateState.ready);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final info = widget.info;

    return PopScope(
      canPop: _state != _UpdateState.downloading,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _state == _UpdateState.downloading) {
          _cancelDownload();
        }
      },
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: Container(
          width: 540,
          padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1F24),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white.withOpacity(0.12), width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Colors.black87,
                blurRadius: 32,
                spreadRadius: 8,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(context, colors, info),
              const SizedBox(height: 18),
              _buildContent(context, colors, info),
              const SizedBox(height: 24),
              _buildActions(context, colors),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colors, AppUpdateInfo info) {
    final IconData iconData;
    final Color iconColor;
    final String title;

    switch (_state) {
      case _UpdateState.ready:
        iconData = Icons.system_update_rounded;
        iconColor = colors.primary;
        title = '发现新版本 (v${info.latestVersion})';
      case _UpdateState.downloading:
        iconData = Icons.cloud_download_rounded;
        iconColor = colors.primary;
        title = '正在下载更新包…';
      case _UpdateState.completed:
        iconData = Icons.check_circle_outline_rounded;
        iconColor = const Color(0xFF4CAF50);
        title = '更新包已下载完成';
      case _UpdateState.error:
        iconData = Icons.error_outline_rounded;
        iconColor = const Color(0xFFEF5350);
        title = '更新下载失败';
    }

    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: iconColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(iconData, color: iconColor, size: 26),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '当前版本: v${info.currentVersion} (${info.currentBuild}) · 大小: ${_formatBytes(info.apkSize)}',
                style: const TextStyle(
                  color: Color(0xFF9E9E9E),
                  fontSize: 12.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(BuildContext context, ColorScheme colors, AppUpdateInfo info) {
    switch (_state) {
      case _UpdateState.ready:
        final notes = info.notes.trim();
        return Container(
          constraints: const BoxConstraints(maxHeight: 140),
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.white.withOpacity(0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.white.withOpacity(0.06)),
          ),
          child: SingleChildScrollView(
            child: Text(
              notes.isNotEmpty ? notes : '本次更新包含体验优化、Bug 修复及性能提升。',
              style: const TextStyle(
                color: Color(0xFFD4D4D8),
                fontSize: 13.5,
                height: 1.45,
              ),
            ),
          ),
        );

      case _UpdateState.downloading:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: _progress > 0 ? _progress : null,
                minHeight: 10,
                backgroundColor: Colors.white12,
                valueColor: AlwaysStoppedAnimation<Color>(colors.primary),
              ),
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '${(_progress * 100).toStringAsFixed(1)}%',
                  style: TextStyle(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                Text(
                  '${_formatBytes(_receivedBytes)} / ${_formatBytes(_totalBytes)}',
                  style: const TextStyle(
                    color: Color(0xFFA1A1AA),
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ],
        );

      case _UpdateState.completed:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF4CAF50).withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF4CAF50).withOpacity(0.2)),
          ),
          child: const Text(
            '安装包已就绪并已调起系统安装器。\n若电视弹出“未知来源应用安装”权限授权提示，请选择【允许】后完成升级。',
            style: TextStyle(
              color: Color(0xFFE4E4E7),
              fontSize: 13.5,
              height: 1.5,
            ),
          ),
        );

      case _UpdateState.error:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFEF5350).withOpacity(0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFFEF5350).withOpacity(0.2)),
          ),
          child: Text(
            _errorMessage.isNotEmpty ? _errorMessage : '网络连接超时或无法连接到更新服务器，请重试。',
            style: const TextStyle(
              color: Color(0xFFFFCDD2),
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
        );
    }
  }

  Widget _buildActions(BuildContext context, ColorScheme colors) {
    switch (_state) {
      case _UpdateState.ready:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _TVDialogButton(
              label: '稍后提醒',
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 14),
            _TVDialogButton(
              label: '立即更新',
              primary: true,
              autofocus: true,
              onTap: _startDownload,
            ),
          ],
        );

      case _UpdateState.downloading:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _TVDialogButton(
              label: '取消下载',
              autofocus: true,
              onTap: _cancelDownload,
            ),
          ],
        );

      case _UpdateState.completed:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _TVDialogButton(
              label: '关闭',
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 14),
            _TVDialogButton(
              label: '再次安装',
              primary: true,
              autofocus: true,
              onTap: () {
                if (_savedPath != null) {
                  AppUpdateService.installApk(_savedPath!);
                }
              },
            ),
          ],
        );

      case _UpdateState.error:
        return Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            _TVDialogButton(
              label: '取消',
              onTap: () => Navigator.of(context).pop(),
            ),
            const SizedBox(width: 14),
            _TVDialogButton(
              label: '重新下载',
              primary: true,
              autofocus: true,
              onTap: _startDownload,
            ),
          ],
        );
    }
  }
}

/// 专为电视遥控器打造的弹窗操作按钮。
class _TVDialogButton extends StatelessWidget {
  const _TVDialogButton({
    required this.label,
    required this.onTap,
    this.primary = false,
    this.autofocus = false,
  });

  final String label;
  final VoidCallback onTap;
  final bool primary;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final bg = primary ? colors.primary : Colors.white12;

    return TVFocusable(
      autofocus: autofocus,
      onTap: onTap,
      radius: 8,
      scale: 1.05,
      borderWidth: 2,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 10),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: Colors.white,
            fontSize: 14.5,
            fontWeight: primary ? FontWeight.bold : FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
