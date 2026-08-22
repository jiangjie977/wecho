/// Copyright (C) 2026 qumolangmo
///
/// This file is part of Wecho.
///
/// Wecho is free software: you can redistribute it and/or modify
/// it under the terms of the GNU General Public License as published by
/// the Free Software Foundation, either version 3 of the License, or
/// (at your option) any later version.
///
/// Wecho is distributed in the hope that it will be useful,
/// but WITHOUT ANY WARRANTY; without even the implied warranty of
/// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
/// GNU General Public License for more details.
///
/// You should have received a copy of the GNU General Public License
/// along with Wecho.  If not, see <https://www.gnu.org/licenses/>.

import 'dart:convert';
import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'audio_config.dart';

class ConfigManager {
  static const String _keyAutoOutputSwitch = 'autoOutputSwitch';
  static const String _keyConfigPrefix = 'config_'; // + sanitized deviceName or "disabled"
  static const String _keyScriptLibrary = 'scriptLibrary';
  static const String _keyScriptParamsPrefix = 'scriptParams_'; // + sanitized deviceName
  static const String _keyActiveScriptPrefix = 'activeScript_'; // + sanitized deviceName

  final SharedPreferences _prefs;
  String _currentDeviceKey = 'disabled';
  String _currentDeviceName = 'unknown';
  Future<void> Function(String deviceKey, AudioConfig config)? onConfigChanged;
  Function(String device)? onDeviceChanged;

  ConfigManager(this._prefs);

  bool get autoOutputSwitch => _prefs.getBool(_keyAutoOutputSwitch) ?? true;
  String get currentDeviceKey => _currentDeviceKey;
  String get currentDeviceName => _currentDeviceName;
  bool get isDisabled => _currentDeviceKey == 'disabled';

  /// Sanitizes a device name into a safe key segment: lowercase + non
  /// alphanumeric chars replaced with '_'. Must match the Kotlin-side
  /// ConfigApplier.sanitizeDeviceName rule exactly.
  static String sanitizeDeviceName(String deviceName) {
    return deviceName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '_');
  }

  Future<void> initialize() async {}

  Future<void> setAutoOutputSwitch(bool enabled) async {
    await _prefs.setBool(_keyAutoOutputSwitch, enabled);
  }

  /// *****************************************Script Library****************************************

  Map<String, String> loadScriptLibrary() {
    final json = _prefs.getString(_keyScriptLibrary);
    if (json == null) return {};
    return Map<String, String>.from(jsonDecode(json));
  }

  Future<void> saveScriptLibrary(Map<String, String> library) async {
    await _prefs.setString(_keyScriptLibrary, jsonEncode(library));
  }

  Future<void> saveScriptToLibrary(String desc, String code) async {
    final library = loadScriptLibrary();
    library[desc] = code;
    await saveScriptLibrary(library);
  }

  Future<void> deleteScriptFromLibrary(String desc) async {
    final library = loadScriptLibrary();
    library.remove(desc);
    await saveScriptLibrary(library);
    // Also remove params for this script from all device keys
    final keys = _prefs
        .getKeys()
        .where((key) => key.startsWith(_keyScriptParamsPrefix))
        .toList();
    for (final key in keys) {
      final json = _prefs.getString(key);
      if (json == null) continue;
      final map = jsonDecode(json) as Map<String, dynamic>;
      if (map.containsKey(desc)) {
        map.remove(desc);
        await _prefs.setString(key, jsonEncode(map));
      }
    }
  }

  /// *****************************************Script params****************************************

  Map<String, List<ScriptParam>> loadScriptParams(String deviceKey) {
    final key = '$_keyScriptParamsPrefix$deviceKey';
    final json = _prefs.getString(key);
    if (json == null) return {};
    final map = jsonDecode(json) as Map<String, dynamic>;
    return map.map((k, v) => MapEntry(
          k,
          (v as List)
              .map((e) => ScriptParam.fromJson(e as Map<String, dynamic>))
              .toList(),
        ));
  }

  Future<void> saveScriptParams(
      String deviceKey, Map<String, List<ScriptParam>> paramsMap) async {
    final key = '$_keyScriptParamsPrefix$deviceKey';
    final encoded = jsonEncode(paramsMap
        .map((k, v) => MapEntry(k, v.map((p) => p.toJson()).toList())));
    await _prefs.setString(key, encoded);
  }

  Future<void> saveScriptParamsForDesc(
      String deviceKey, String desc, List<ScriptParam> params) async {
    final paramsMap = loadScriptParams(deviceKey);
    paramsMap[desc] = params;
    await saveScriptParams(deviceKey, paramsMap);
  }

  List<ScriptParam> loadScriptParamsForDesc(String deviceKey, String desc) {
    final paramsMap = loadScriptParams(deviceKey);
    return paramsMap[desc] ?? [];
  }

  /// *****************************************Active script****************************************

  String getActiveScriptDesc(String deviceKey) {
    return _prefs.getString('$_keyActiveScriptPrefix$deviceKey') ?? '';
  }

  Future<void> setActiveScriptDesc(String deviceKey, String desc) async {
    await _prefs.setString('$_keyActiveScriptPrefix$deviceKey', desc);
  }

  /// *****************************************General Config****************************************

  Future<void> saveConfig(String deviceKey, AudioConfig config) async {
    final key = '$_keyConfigPrefix$deviceKey';
    await _prefs.setString(key, config.toJsonString());
  }

  AudioConfig loadConfig(String deviceKey) {
    final key = '$_keyConfigPrefix$deviceKey';
    final jsonString = _prefs.getString(key);
    if (jsonString != null && jsonString.isNotEmpty) {
      return AudioConfig.fromJsonString(jsonString);
    }
    return AudioConfig();
  }

  AudioConfig getCurrentConfig() {
    return loadConfig(_currentDeviceKey);
  }

  Future<void> updateOutputDevice(String device) async {
    _currentDeviceName = device;

    final newDeviceKey = autoOutputSwitch ? sanitizeDeviceName(device) : 'disabled';

    if (newDeviceKey != _currentDeviceKey) {
      _currentDeviceKey = newDeviceKey;
      final config = getCurrentConfig();
      await onConfigChanged?.call(_currentDeviceKey, config);
    }

    onDeviceChanged?.call(device);
  }

  /// *****************************************Config Management****************************************

  static const String _keyLastSelectedConfig = 'lastSelectedConfig';

  Future<Directory> _getConfigsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final configsDir = Directory('${appDir.path}/wecho_configs');
    if (!await configsDir.exists()) {
      await configsDir.create(recursive: true);
    }
    return configsDir;
  }

  Future<void> saveConfigWithName(String name, AudioConfig config) async {
    final configsDir = await _getConfigsDirectory();
    final file = File('${configsDir.path}/$name.json');
    await file.writeAsString(config.toJsonString());
  }

  Future<AudioConfig?> loadConfigByName(String name) async {
    try {
      final configsDir = await _getConfigsDirectory();
      final file = File('${configsDir.path}/$name.json');
      if (!await file.exists()) {
        return null;
      }
      final jsonString = await file.readAsString();
      return AudioConfig.fromJsonString(jsonString);
    } catch (e) {
      return null;
    }
  }

  Future<void> saveLastSelectedConfig(String? name) async {
    if (name == null) {
      await _prefs.remove(_keyLastSelectedConfig);
    } else {
      await _prefs.setString(_keyLastSelectedConfig, name);
    }
  }

  String? getLastSelectedConfig() {
    return _prefs.getString(_keyLastSelectedConfig);
  }

  Future<List<String>> loadSavedConfigNames() async {
    final configsDir = await _getConfigsDirectory();
    if (!await configsDir.exists()) {
      return [];
    }
    final files = await configsDir.list().toList();
    return files
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((name) => name.endsWith('.json'))
        .map((name) => name.substring(0, name.length - 5))
        .toList();
  }

  Future<void> deleteConfigByName(String name) async {
    final configsDir = await _getConfigsDirectory();
    final file = File('${configsDir.path}/$name.json');
    if (await file.exists()) {
      await file.delete();
    }
  }
}
