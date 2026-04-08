import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import 'package:audioplayers/audioplayers.dart';


class BeepGuard {
  static int gen = 0;
  static bool enabled = true;

  static AudioPlayer? activePlayer;

  static void register(AudioPlayer p) {
    activePlayer = p;
  }

  static void killNow() {
    enabled = false;
    gen++;
    // Çalanı da anında kes
    try { activePlayer?.stop(); } catch (_) {}
    try { activePlayer?.seek(Duration.zero); } catch (_) {}
  }

  static void arm() {
    enabled = true;
    gen++;
  }
}