import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';


import '../models/device_model.dart';


class SavedStore {
  static const String _key = 'bluetoothfinder_saved_devices_v1';

  static Future<Map<String, SavedDevice>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null || raw.trim().isEmpty) return {};

    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return {};

      final out = <String, SavedDevice>{};
      for (final item in decoded) {
        if (item is! Map) continue;
        final m = Map<String, dynamic>.from(item as Map);
        final d = SavedDevice.fromJson(m);
        if (d.id.isNotEmpty) out[d.id] = d;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  static Future<void> save(Map<String, SavedDevice> map) async {
    final prefs = await SharedPreferences.getInstance();
    final list = map.values
        .map((d) => d.toJson())
        .toList(growable: false);

    await prefs.setString(_key, jsonEncode(list));
  }
}