import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

/// 应用更新信息。
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.currentBuild,
    required this.latestVersion,
    required this.latestBuild,
    required this.tagName,
    required this.title,
    required this.notes,
    required this.downloadUrl,
    required this.apkName,
    required this.apkSize,
    required this.hasUpdate,
  });

  final String currentVersion;
  final int currentBuild;
  final String latestVersion;
  final int latestBuild;
  final String tagName;
  final String title;
  final String notes;
  final String downloadUrl;
  final String apkName;
  final int apkSize;
  final bool hasUpdate;
}

/// 检查更新与下载安装服务。
class AppUpdateService {
  AppUpdateService._();

  static const MethodChannel _deviceChannel = MethodChannel('minireel/device');

  /// 获取当前设备的 CPU ABI（TV 盒子通常为 armeabi-v7a 或 arm64-v8a）。
  static Future<String> getDeviceAbi() async {
    if (!Platform.isAndroid) return 'armeabi-v7a';
    try {
      final abi = await _deviceChannel.invokeMethod<String>('getAbi');
      return abi ?? 'armeabi-v7a';
    } catch (_) {
      return 'armeabi-v7a';
    }
  }

  /// 检查 GitHub Releases 最新版本。
  static Future<AppUpdateInfo?> checkForUpdate() async {
    try {
      final info = await PackageInfo.fromPlatform().catchError(
        (_) => PackageInfo(
          appName: 'MiniReel',
          packageName: 'app.minireel.minireel.tv',
          version: '0.2.1',
          buildNumber: '3',
          buildSignature: '',
        ),
      );

      final currentVersion = info.version;
      final currentBuild = int.tryParse(info.buildNumber) ?? 0;

      final release = await _fetchLatestRelease();
      if (release == null) return null;

      final tagName = (release['tag_name'] as String?) ?? '';
      final title = (release['name'] as String?) ?? tagName;
      final notes = (release['body'] as String?) ?? '';

      final match = RegExp(
        r'^v?(\d+\.\d+\.\d+)(?:-tv-build-(\d+))?',
      ).firstMatch(tagName);
      if (match == null) return null;

      final latestVersion = match.group(1)!;
      final latestBuild = int.tryParse(match.group(2) ?? '0') ?? 0;

      final hasUpdate = _isNewer(
        latestVersion,
        latestBuild,
        currentVersion,
        currentBuild,
      );

      final assets = (release['assets'] as List<dynamic>?) ?? [];
      final abi = await getDeviceAbi();
      final asset = _selectAsset(assets, abi);
      if (asset == null) return null;

      final downloadUrl = (asset['browser_download_url'] as String?) ?? '';
      final apkName = (asset['name'] as String?) ?? 'update.apk';
      final apkSize = (asset['size'] as int?) ?? 0;

      return AppUpdateInfo(
        currentVersion: currentVersion,
        currentBuild: currentBuild,
        latestVersion: latestVersion,
        latestBuild: latestBuild,
        tagName: tagName,
        title: title,
        notes: notes,
        downloadUrl: downloadUrl,
        apkName: apkName,
        apkSize: apkSize,
        hasUpdate: hasUpdate,
      );
    } catch (e) {
      debugPrint('AppUpdateService.checkForUpdate error: $e');
      return null;
    }
  }

  /// 获取 GitHub Releases 最新发布数据（支持直连与代理镜像自动回退）。
  static Future<Map<String, dynamic>?> _fetchLatestRelease() async {
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 10),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
          'User-Agent': 'MiniReel-TV',
        },
      ),
    );

    final urls = [
      'https://api.github.com/repos/yixuexiaoao/minireel-tv/releases/latest',
      'https://ghproxy.net/https://api.github.com/repos/yixuexiaoao/minireel-tv/releases/latest',
    ];

    for (final url in urls) {
      try {
        final response = await dio.get<dynamic>(url);
        if (response.statusCode == 200 && response.data != null) {
          if (response.data is Map<String, dynamic>) {
            return response.data as Map<String, dynamic>;
          } else if (response.data is String) {
            final decoded = jsonDecode(response.data as String);
            if (decoded is Map<String, dynamic>) {
              return decoded;
            }
          }
        }
      } catch (_) {
        // 继续尝试下一个源
      }
    }
    return null;
  }

  /// 比较版本号：主版本号更高，或主版本号相同且构建号更高。
  static bool _isNewer(
    String latestVer,
    int latestBuild,
    String curVer,
    int curBuild,
  ) {
    final lParts = latestVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final cParts = curVer.split('.').map((e) => int.tryParse(e) ?? 0).toList();

    for (int i = 0; i < 3; i++) {
      final l = i < lParts.length ? lParts[i] : 0;
      final c = i < cParts.length ? cParts[i] : 0;
      if (l > c) return true;
      if (l < c) return false;
    }
    return latestBuild > curBuild;
  }

  /// 根据设备架构选择对应的 APK 资源。
  static Map<String, dynamic>? _selectAsset(
    List<dynamic> assets,
    String abi,
  ) {
    final typedAssets = assets.whereType<Map<String, dynamic>>().toList();
    final is64 = abi.contains('64') || abi.contains('arm64');

    if (is64) {
      final a64 = typedAssets.firstWhere(
        (a) => (a['name'] as String? ?? '').contains('arm64-v8a'),
        orElse: () => const {},
      );
      if (a64.isNotEmpty) return a64;
    }

    final av7 = typedAssets.firstWhere(
      (a) => (a['name'] as String? ?? '').contains('armeabi-v7a'),
      orElse: () => const {},
    );
    if (av7.isNotEmpty) return av7;

    return typedAssets.firstWhere(
      (a) => (a['name'] as String? ?? '').endsWith('.apk'),
      orElse: () => const {},
    );
  }

  /// 下载 APK 安装包到缓存目录，支持进度通知与取消。
  static Future<String> downloadApk(
    String downloadUrl, {
    required void Function(int received, int total) onProgress,
    CancelToken? cancelToken,
  }) async {
    final Directory baseDir;
    if (Platform.isAndroid) {
      final extDirs = await getExternalCacheDirectories();
      if (extDirs != null && extDirs.isNotEmpty) {
        baseDir = extDirs.first;
      } else {
        baseDir = await getTemporaryDirectory();
      }
    } else {
      baseDir = await getTemporaryDirectory();
    }
    final filePath = '${baseDir.path}/update.apk';
    final file = File(filePath);
    if (await file.exists()) {
      try {
        await file.delete();
      } catch (_) {}
    }

    final urlsToTry = [
      downloadUrl,
      'https://ghproxy.net/$downloadUrl',
    ];

    DioException? lastError;
    final dio = Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 15),
        receiveTimeout: const Duration(seconds: 120),
        followRedirects: true,
        maxRedirects: 5,
      ),
    );

    for (final url in urlsToTry) {
      try {
        await dio.download(
          url,
          filePath,
          onReceiveProgress: (received, total) {
            if (total > 0) {
              onProgress(received, total);
            }
          },
          cancelToken: cancelToken,
          deleteOnError: true,
        );
        return filePath;
      } on DioException catch (e) {
        if (cancelToken?.isCancelled ?? false) rethrow;
        lastError = e;
      } catch (e) {
        if (cancelToken?.isCancelled ?? false) rethrow;
      }
    }

    throw lastError ?? Exception('下载更新包失败，请检查网络');
  }

  /// 调起系统安装器安装 APK。
  static Future<void> installApk(String filePath) async {
    if (!Platform.isAndroid) return;
    await _deviceChannel.invokeMethod<bool>(
      'installApk',
      {'filePath': filePath},
    );
  }
}
