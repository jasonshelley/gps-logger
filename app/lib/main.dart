import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'data/database.dart';
import 'data/repository.dart';
import 'sync/sync_controller.dart';
import 'ui/home_screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  final db = await openAppDatabase();
  final docs = await getApplicationDocumentsDirectory();
  final repo = Repository(db, logDir: Directory(p.join(docs.path, 'logs')));
  runApp(CatchLogApp(services: AppServices(repo: repo, httpClient: http.Client())));
}

/// The app's long-lived objects, reachable from any widget with [AppScope.of].
class AppServices {
  AppServices({required this.repo, required this.httpClient}) : sync = SyncController(repo);
  final Repository repo;
  final http.Client httpClient;
  final SyncController sync;
}

class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});
  final AppServices services;

  static AppServices of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<AppScope>()!.services;

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}

class CatchLogApp extends StatelessWidget {
  const CatchLogApp({super.key, required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    return AppScope(
      services: services,
      child: MaterialApp(
        title: 'Catch Log',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const HomeScreen(),
      ),
    );
  }
}
