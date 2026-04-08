import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TrialService {
  static const String _key = 'first_launch_date';
  static const int trialDays = 15;
  
  static const bool debugForceExpire = false;

  // Uygulamanın ilk açılış tarihini kaydeder (Sadece bir kez çalışır)
  static Future<void> recordFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key) == null) {
      prefs.setString(_key, DateTime.now().toIso8601String());
    }
  }

  // Deneme süresi doldu mu?
  static Future<bool> isExpired() async {
    if (debugForceExpire) return true;
  
    final prefs = await SharedPreferences.getInstance();
    final dateStr = prefs.getString(_key);
    
    if (dateStr == null) return false;

    final firstLaunch = DateTime.parse(dateStr);
    final now = DateTime.now();
    final difference = now.difference(firstLaunch).inDays;

    return difference >= trialDays;
  }
}