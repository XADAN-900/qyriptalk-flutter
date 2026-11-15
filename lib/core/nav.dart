import 'package:flutter/material.dart';

/// Bildirimlerden ve arama servisinden ekran açabilmek için global gezgin.
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

BuildContext? get rootContext => navigatorKey.currentContext;
