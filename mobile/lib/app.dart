/// App root widget — configures theme, locale, and providers.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'services/auth_service.dart';
import 'services/sync_engine.dart';
import 'screens/camera_capture_screen.dart';

class ReceiptsApp extends StatelessWidget {
  const ReceiptsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider.value(value: AuthService.instance),
        ChangeNotifierProvider.value(value: SyncEngine.instance),
      ],
      child: MaterialApp(
        title: 'קבלות',
        debugShowCheckedModeBanner: false,

        // RTL support for Hebrew
        locale: const Locale('he', 'IL'),
        supportedLocales: const [
          Locale('he', 'IL'),
          Locale('en', 'US'),
        ],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],

        // Modern Material 3 theme
        theme: ThemeData(
          useMaterial3: true,
          colorSchemeSeed: Colors.blue,
          brightness: Brightness.light,
          fontFamily: 'Rubik', // Good Hebrew font; falls back to system if unavailable

          appBarTheme: const AppBarTheme(
            centerTitle: true,
            elevation: 0,
          ),

          cardTheme: CardThemeData(
            elevation: 1,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),

          inputDecorationTheme: InputDecorationTheme(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            filled: true,
          ),
        ),

        // Camera opens immediately — the default launch screen
        home: const CameraCaptureScreen(),
      ),
    );
  }
}

