import 'dart:async';
import 'dart:math' as math;
import 'dart:io';
import 'dart:convert';

import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import 'core/app_settings.dart';
import 'widgets/radar_painter.dart';
import 'widgets/custom_components.dart';
import 'models/device_model.dart';
import 'services/storage_service.dart';
import 'services/audio_service.dart';
import 'services/trial_service.dart';
import 'services/revenue_cat_service.dart';

import 'pages/home_page.dart';
import 'pages/find_mode_page.dart';

void main() async {
  // Flutter binding'lerini hazırla (Async işlemler için şart)
  WidgetsBinding widgetsBinding = WidgetsFlutterBinding.ensureInitialized();
  // RevenueCat'i uyandıralım
  await RevenueCatService.init();
  // İlk açılış tarihini kaydet (Trial için)
  await TrialService.recordFirstLaunch();

  runApp(const FindLostGadgetApp());
}

class FindLostGadgetApp extends StatelessWidget {
  const FindLostGadgetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: "Find Lost Gadget",
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const HomePage(),
    );
  }
}



















