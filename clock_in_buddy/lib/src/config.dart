import 'env.dart' as env;

class AppConfig {
  /// Override at build time with --dart-define=SUPABASE_URL=...
  static const String supabaseUrl =
      String.fromEnvironment('SUPABASE_URL', defaultValue: env.supabaseUrl);

  /// Override at build time with --dart-define=SUPABASE_KEY=...
  static const String supabaseKey =
      String.fromEnvironment('SUPABASE_KEY', defaultValue: env.supabaseKey);

  static bool get isConfigured => supabaseUrl.isNotEmpty && supabaseKey.isNotEmpty;

  /// Private storage bucket for verification photos.
  static const String photoBucket = 'attendance-photos';

  /// Location fixes worse than this are flagged for review.
  static const double goodAccuracyMeters = 100;
}
