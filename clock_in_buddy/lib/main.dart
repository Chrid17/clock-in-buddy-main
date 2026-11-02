import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show Supabase;

import 'src/api/attendance_api.dart';
import 'src/config.dart';
import 'src/state/attendance_controller.dart';
import 'src/state/session.dart';
import 'src/ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!AppConfig.isConfigured) {
    runApp(const ClockInApp());
    return;
  }

  await Supabase.initialize(
    url: AppConfig.supabaseUrl,
    publishableKey: AppConfig.supabaseKey,
  );
  final auth = Supabase.instance.client.auth;

  final api = AttendanceApi(
    baseUrl: AppConfig.supabaseUrl,
    apiKey: AppConfig.supabaseKey,
    tokenProvider: () => Session.accessTokenFor(auth),
  );
  final session = Session(auth, api);
  final attendance = AttendanceController(api: api);

  // Load the right person's attendance whenever someone signs in or out.
  void bind() => attendance.bindUser(session.userId);
  session.addListener(bind);
  bind();

  runApp(
    MultiProvider(
      providers: [
        Provider<AttendanceApi>.value(value: api),
        ChangeNotifierProvider<Session>.value(value: session),
        ChangeNotifierProvider<AttendanceController>.value(value: attendance),
      ],
      child: const ClockInApp(),
    ),
  );
}
