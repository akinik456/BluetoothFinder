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
  
  static Future<bool> purchasePro() async {
  try {
    Offerings offerings = await Purchases.getOfferings();
    if (offerings.current != null && offerings.current!.monthly != null) {
      // Değişen kısım burası: CustomerInfo yerine PurchaseResult geliyor
      var purchaseResult = await Purchases.purchasePackage(offerings.current!.monthly!);
      
      // Satın alma sonucundaki customerInfo'yu alıp kontrol ediyoruz
      return purchaseResult.customerInfo.entitlements.all["pro"]?.isActive ?? false;
    }
  } catch (e) {
    print("Satın alma hatası: $e");
  }
  return false;
}

static Future<bool> isUserPremium() async {
  try {
    CustomerInfo customerInfo = await Purchases.getCustomerInfo();
    
    // Panelindeki tüm aktif yetkileri loglayalım ki adını kesin görelim
    print("WATCHDOG: Aktif Yetkiler: ${customerInfo.entitlements.active.keys}");

    // Eğer yetki listesi boş değilse, bu adam ödeme yapmıştır
    if (customerInfo.entitlements.active.isNotEmpty) {
      return true; 
    }

    // Veya paneldeki tam ismi buraya yaz (Genelde ID ismidir)
    // return customerInfo.entitlements.all["Find Lost Gadget By Lynra Pro"]?.isActive ?? false;
    
    return false;
  } catch (e) {
    print("Hata: $e");
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