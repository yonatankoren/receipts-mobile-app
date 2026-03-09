/// Entry point for the Receipts app.
///
/// Initialization order:
///   1. Flutter bindings
///   2. Firebase (crash reporting)
///   3. Google Sign-In (silent, non-blocking)
///   4. Storage config (load cached IDs)
///   5. Sync engine (connectivity monitor + job processor)
///   6. Periodic cleanup (silent, non-blocking)
///   7. Launch app → HomeRouter decides first screen

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'firebase_options.dart';
import 'services/auth_service.dart';
import 'services/cleanup_service.dart';
import 'services/custom_category_service.dart';
import 'services/storage_config_service.dart';
import 'services/sync_engine.dart';
import 'app.dart';

void main() async {
  // Run everything inside a zone to catch async errors too
  runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Lock to portrait for consistent receipt capture
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
    ]);

    // Initialize Firebase
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Send all uncaught Flutter framework errors to Crashlytics
    FlutterError.onError = FirebaseCrashlytics.instance.recordFlutterFatalError;

    // Initialize services (non-blocking)
    await AuthService.instance.init();
    await StorageConfigService.instance.init();
    await CustomCategoryService.instance.init();
    SyncEngine.instance.init();

    // Run periodic cleanup (silent, non-blocking)
    CleanupService.instance.runPeriodicCleanupIfNeeded();

    runApp(const ReceiptsApp());
  }, (error, stack) {
    // Catch any errors that escape the Flutter framework (async gaps, isolates)
    FirebaseCrashlytics.instance.recordError(error, stack, fatal: true);
  });
}
