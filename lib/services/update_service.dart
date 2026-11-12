// In-app updates (Android, LoomChat server mode). The server hands out the
// newest CI build; this file compares build numbers and opens the installer.

import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class AppUpdate {
  final String version;
  final int build;
  final String notes;
  const AppUpdate(
      {required this.version, required this.build, this.notes = ''});

  String get label => version.isEmpty ? 'build $build' : '$version ($build)';
}

class UpdateService {
  static const _channel = MethodChannel('com.local.local_llm_chat/update');

  /// Only Android can install an APK from inside the app.
  static bool get supported => !kIsWeb && Platform.isAndroid;

  static PackageInfo? _info;

  static Future<PackageInfo> info() async =>
      _info ??= await PackageInfo.fromPlatform();

  static Future<int> currentBuild() async =>
      int.tryParse((await info()).buildNumber) ?? 0;

  /// "1.1.0 (118)"
  static Future<String> currentLabel() async {
    final i = await info();
    return i.buildNumber.isEmpty
        ? i.version
        : '${i.version} (${i.buildNumber})';
  }

  /// Where the APK is downloaded. Must match res/xml/update_paths.xml.
  static Future<File> apkFile() async {
    final dir = Directory('${(await getTemporaryDirectory()).path}/updates');
    await dir.create(recursive: true);
    return File('${dir.path}/loomchat-update.apk');
  }

  /// Opens the system installer. Returns false when Android first needs the
  /// "install unknown apps" permission (its settings page is opened instead).
  static Future<bool> install(File apk) async {
    final res =
        await _channel.invokeMethod<String>('installApk', {'path': apk.path});
    return res == 'ok';
  }
}
