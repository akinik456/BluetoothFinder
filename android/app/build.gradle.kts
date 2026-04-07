plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.akinik.findlostgadget"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
		// Kendi benzersiz ID'ni buraya yaz (Örn: com.akinik.findlostgadget)
		// Play Store'a çıktıktan sonra bu DEĞİŞTİRİLEMEZ.
		applicationId = "com.akinik.findlostgadget" 

		minSdk = 28          // Android 9.0 (Pie) desteği için sabitledik
		targetSdk = 34       // Google Play Store'un 2024 sonu itibariyle istediği güncel sürüm
		
		versionCode = flutter.versionCode
		versionName = flutter.versionName
	}

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
