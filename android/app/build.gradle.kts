plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}


dependencies {
    // Bundle the Latin and Devanagari recognition models for offline OCR.
    implementation("com.google.mlkit:text-recognition:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
}

android {
    namespace = "com.example.aurelia_pms"
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
        applicationId = "com.example.aurelia_pms"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // A debug APK must remain buildable without production signing secrets.
    // Release builds still require all four private signing environment values.
    val releaseStore = System.getenv("ANDROID_KEYSTORE_PATH")
    val releaseStorePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
    val releaseAlias = System.getenv("ANDROID_KEY_ALIAS")
    val releaseKeyPassword = System.getenv("ANDROID_KEY_PASSWORD")
    val releaseSigningConfigured = !releaseStore.isNullOrBlank() &&
        !releaseStorePassword.isNullOrBlank() &&
        !releaseAlias.isNullOrBlank() &&
        !releaseKeyPassword.isNullOrBlank()

    if (releaseSigningConfigured) {
        signingConfigs {
            create("release") {
                storeFile = file(releaseStore!!)
                storePassword = releaseStorePassword!!
                keyAlias = releaseAlias!!
                keyPassword = releaseKeyPassword!!
            }
        }
    }

    buildTypes {
        release {
            if (releaseSigningConfigured) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                // Fail explicitly only when someone requests a release variant.
                if (gradle.startParameter.taskNames.any { it.contains("Release", ignoreCase = true) }) {
                    throw GradleException("Release APK requires ANDROID_KEYSTORE_PATH, ANDROID_KEYSTORE_PASSWORD, ANDROID_KEY_ALIAS, and ANDROID_KEY_PASSWORD")
                }
            }
        }
    }
}

flutter {
    source = "../.."
}
