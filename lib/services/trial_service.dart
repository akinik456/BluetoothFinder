import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';


class TrialService {
  static const String _key = 'first_launch_date';
  static const int trialDays = 2;
  
  static const bool debugForceExpire = false;

  // Uygulamanın ilk açılış tarihini kaydeder (Sadece bir kez çalışır)
  static Future<void> recordFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_key) == null) {
      prefs.setString(_key, DateTime.now().toIso8601String());
    }
  }

  static Future<bool> isExpired() async {
  if (debugForceExpire) return true;

  // 1. ÖNCE REVENUECAT'E SOR: Bu adam zaten Pro mu?
  // Eğer Pro ise süreye bakmaya bile gerek yok, asla 'expired' (süresi dolmuş) sayılmaz.
  /*bool isPremium = await RevenueCatService.isUserPremium();
  if (isPremium) {
    print("WATCHDOG: Kullanıcı Premium, kilitler açılıyor.");
    return false; // Süresi dolmuş sayılmaz, serbest bırak
  }*/
  return true;

  // 2. EĞER PREMIUM DEĞİLSE, ZAMANA BAK:
  final prefs = await SharedPreferences.getInstance();
  final dateStr = prefs.getString(_key);
  print("dateStr:$dateStr");
  if (dateStr == null) return false;

  final firstLaunch = DateTime.parse(dateStr);
  final now = DateTime.now();
  final difference = now.difference(firstLaunch).inMinutes; 
  
  print("difference:$difference");
  
  // Eğer süre dolmuşsa 'true' (yani kilitli), dolmamışsa 'false' dönecek
  return difference >= trialDays;
}
}