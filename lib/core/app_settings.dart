import 'package:flutter/material.dart';

// Global mute across Find Mode pages
// Artık bir dosyanın içine girdiği için başına '_' koymuyoruz ki her yerden erişilsin.
final ValueNotifier<bool> globalMute = ValueNotifier(false);

// Cihazların kalibre edilmiş max sinyal değerlerini tutan map
final Map<String, int> calibratedMaxById = {};