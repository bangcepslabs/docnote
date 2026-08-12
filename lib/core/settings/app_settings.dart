import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppThemeChoice { system, light, dark }

class AppSettings {
  const AppSettings({
    this.theme = AppThemeChoice.system,
    this.autoSave = true,
  });
  final AppThemeChoice theme;
  final bool autoSave;

  AppSettings copyWith({AppThemeChoice? theme, bool? autoSave}) => AppSettings(
        theme: theme ?? this.theme,
        autoSave: autoSave ?? this.autoSave,
      );
}

final appSettingsProvider =
    StateNotifierProvider<AppSettingsController, AppSettings>(
        (ref) => AppSettingsController()..restore());

class AppSettingsController extends StateNotifier<AppSettings> {
  AppSettingsController() : super(const AppSettings());
  static const _themeKey = 'docnote.settings.theme';
  static const _autoSaveKey = 'docnote.settings.autoSave';

  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final themeName = prefs.getString(_themeKey);
    final theme = AppThemeChoice.values.where((item) => item.name == themeName);
    state = state.copyWith(
        theme: theme.isEmpty ? AppThemeChoice.system : theme.first,
        autoSave: prefs.getBool(_autoSaveKey) ?? true);
  }

  Future<void> setTheme(AppThemeChoice value) async {
    state = state.copyWith(theme: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeKey, value.name);
  }

  Future<void> setAutoSave(bool value) async {
    state = state.copyWith(autoSave: value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSaveKey, value);
  }
}
