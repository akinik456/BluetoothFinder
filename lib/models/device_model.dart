import 'dart:async';
import 'package:flutter/material.dart';

// ===================== SAVED DEVICES (PERSISTENT) =====================

class SavedDevice {
  final String id;
  final String? name;
  final int savedAtMs;

  const SavedDevice({
    required this.id,
    required this.savedAtMs,
    this.name,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'savedAtMs': savedAtMs,
      };

  static SavedDevice fromJson(Map<String, dynamic> j) {
    return SavedDevice(
      id: (j['id'] ?? '').toString(),
      name: (j['name'] as String?)?.toString(),
      savedAtMs: (j['savedAtMs'] is int)
          ? (j['savedAtMs'] as int)
          : int.tryParse('${j['savedAtMs']}') ?? 0,
    );
  }
}