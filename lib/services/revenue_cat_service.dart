import 'package:purchases_flutter/purchases_flutter.dart';

class RevenueCatService {
  // Senin verdiğin test anahtarı
  static const _apiKey = "test_kNPfZGzIfuysmflSOFAQIaezeJH"; 
  
  // ÖNEMLİ: RC Panelinde "Entitlements" kısmına verdiğin isimle aynı olmalı
  static const _entitlementId = "Find Lost Gadget By Lynra Pro";

  static Future<void> init() async {
    await Purchases.setLogLevel(LogLevel.debug);
    PurchasesConfiguration configuration = PurchasesConfiguration(_apiKey);
    await Purchases.configure(configuration);
  }

  // Kullanıcı parayı vermiş mi?
  static Future<bool> isPremium() async {
    try {
      CustomerInfo customerInfo = await Purchases.getCustomerInfo();
      return customerInfo.entitlements.all[_entitlementId]?.isActive ?? false;
    } catch (e) {
      return false;
    }
  }

  // Satın alımı geri yükle (Restore Button için)
  static Future<bool> restore() async {
    try {
      CustomerInfo customerInfo = await Purchases.restorePurchases();
      return customerInfo.entitlements.all[_entitlementId]?.isActive ?? false;
    } catch (e) {
      return false;
    }
  }
}