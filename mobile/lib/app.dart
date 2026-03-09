/// App root widget — configures theme, locale, and providers.
/// Uses HomeRouter to direct users through onboarding or to the main camera.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'providers/app_state.dart';
import 'services/auth_service.dart';
import 'services/storage_config_service.dart';
import 'services/sync_engine.dart';
import 'screens/camera_capture_screen.dart';
import 'screens/main_pager_screen.dart';
import 'screens/onboarding/google_connect_screen.dart';
import 'screens/onboarding/storage_setup_screen.dart';
import 'widgets/loading_indicator.dart';

class ReceiptsApp extends StatelessWidget {
  const ReceiptsApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppState()),
        ChangeNotifierProvider.value(value: AuthService.instance),
        ChangeNotifierProvider.value(value: SyncEngine.instance),
        ChangeNotifierProvider.value(value: StorageConfigService.instance),
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

        // Route through HomeRouter instead of directly to camera
        home: const HomeRouter(),
      ),
    );
  }
}

/// Routes the user to the correct screen based on auth + storage config state.
///
/// Flow:
///   1. Not signed in → GoogleConnectScreen
///   2. Signed in, no folder/sheet IDs → StorageSetupScreen
///   3. Fully configured → CameraCaptureScreen
class HomeRouter extends StatefulWidget {
  const HomeRouter({super.key});

  @override
  State<HomeRouter> createState() => _HomeRouterState();
}

class _HomeRouterState extends State<HomeRouter> {
  bool _isChecking = true;
  Widget? _destination;

  @override
  void initState() {
    super.initState();
    _determineDestination();
  }

  Future<void> _determineDestination() async {
    final auth = AuthService.instance;
    final config = StorageConfigService.instance;

    // Step 1: Not signed in?
    if (!auth.isSignedIn) {
      if (mounted) {
        setState(() {
          _destination = const GoogleConnectScreen();
          _isChecking = false;
        });
      }
      return;
    }

    // Step 2: Signed in but no storage configured?
    if (!config.isFullyConfigured) {
      if (mounted) {
        setState(() {
          _destination = const StorageSetupScreen();
          _isChecking = false;
        });
      }
      return;
    }

    // Step 3: Fully configured — validate access
    final validation = await config.validateAccess();
    if (!validation.allOk) {
      if (mounted) {
        setState(() {
          _destination = const StorageSetupScreen(isRelink: true);
          _isChecking = false;
        });
      }
      return;
    }

    // All good — go to main pager (camera + statistics)
    if (mounted) {
      setState(() {
        _destination = const MainPagerScreen();
        _isChecking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isChecking) {
      return const Scaffold(
        body: Center(child: LoadingIndicator()),
      );
    }

    return _destination!;
  }
}
