/// App root widget — configures theme, locale, and providers.
/// Uses HomeRouter to direct users through onboarding or to the main camera.
///
/// Also hosts the Android Share intent listener so shared files can be
/// received whether the app was closed (cold start) or already running
/// (warm start). A [GlobalKey<NavigatorState>] gives the listener access
/// to push routes from outside the widget tree.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'providers/app_state.dart';
import 'services/auth_service.dart';
import 'services/storage_config_service.dart';
import 'services/sync_engine.dart';
import 'screens/main_pager_screen.dart';
import 'screens/shared_import_screen.dart';
import 'screens/onboarding/google_connect_screen.dart';
import 'screens/onboarding/storage_setup_screen.dart';
import 'widgets/loading_indicator.dart';

/// Navigator key shared between ReceiptsApp and HomeRouter so the share
/// intent stream can push routes from anywhere.
final GlobalKey<NavigatorState> rootNavigatorKey = GlobalKey<NavigatorState>();

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
        navigatorKey: rootNavigatorKey,
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
          fontFamily: 'Rubik',

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

        home: const HomeRouter(),
      ),
    );
  }
}

/// Routes the user to the correct screen based on auth + storage config state.
///
/// Also handles Android Share intents:
///   - Cold start: checks for initial shared media before routing
///   - Warm start: listens to the media stream and pushes SharedImportScreen
///
/// Flow:
///   1. Not signed in → GoogleConnectScreen
///   2. Signed in, no folder/sheet IDs → StorageSetupScreen
///   3. Fully configured → MainPagerScreen (camera + statistics)
///   4. If shared files pending → SharedImportScreen on top
class HomeRouter extends StatefulWidget {
  const HomeRouter({super.key});

  @override
  State<HomeRouter> createState() => _HomeRouterState();
}

class _HomeRouterState extends State<HomeRouter> {
  bool _isChecking = true;
  Widget? _destination;
  StreamSubscription<List<SharedMediaFile>>? _shareSubscription;
  List<SharedMediaFile>? _pendingShareFiles;

  @override
  void initState() {
    super.initState();

    // Cold start: check if the app was opened via a share intent
    ReceiveSharingIntent.instance.getInitialMedia().then((files) {
      if (files.isNotEmpty) {
        _pendingShareFiles = files;
        ReceiveSharingIntent.instance.reset();
      }
    });

    // Warm start: listen for share intents arriving while the app is open
    _shareSubscription = ReceiveSharingIntent.instance
        .getMediaStream()
        .listen(_onShareReceived);

    _determineDestination();
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    super.dispose();
  }

  void _onShareReceived(List<SharedMediaFile> files) {
    if (files.isEmpty) return;
    ReceiveSharingIntent.instance.reset();

    final paths = _extractPaths(files);
    if (paths.isEmpty) return;

    final nav = rootNavigatorKey.currentState;
    if (nav == null) return;

    nav.push(MaterialPageRoute(
      builder: (_) => SharedImportScreen(filePaths: paths),
    ));
  }

  List<String> _extractPaths(List<SharedMediaFile> files) {
    return files
        .where((f) => f.path.isNotEmpty)
        .map((f) => f.path)
        .toList();
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

      // If the app was cold-started via a share intent, route to import now
      _handlePendingShare();
    }
  }

  void _handlePendingShare() {
    if (_pendingShareFiles == null || _pendingShareFiles!.isEmpty) return;

    final paths = _extractPaths(_pendingShareFiles!);
    _pendingShareFiles = null;
    if (paths.isEmpty) return;

    // Push after the current frame so the home screen is already in the stack
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final nav = rootNavigatorKey.currentState;
      if (nav == null) return;

      nav.push(MaterialPageRoute(
        builder: (_) => SharedImportScreen(filePaths: paths),
      ));
    });
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
