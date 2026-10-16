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

    signingConfigs {
        create("release") {
            val releaseStore = System.getenv("ANDROID_KEYSTORE_PATH")
                ?: throw GradleException("ANDROID_KEYSTORE_PATH is required for release signing")
            storeFile = file(releaseStore)
            storePassword = System.getenv("ANDROID_KEYSTORE_PASSWORD")
                ?: throw GradleException("ANDROID_KEYSTORE_PASSWORD is required for release signing")
            keyAlias = System.getenv("ANDROID_KEY_ALIAS")
                ?: throw GradleException("ANDROID_KEY_ALIAS is required for release signing")
            keyPassword = System.getenv("ANDROID_KEY_PASSWORD")
                ?: throw GradleException("ANDROID_KEY_PASSWORD is required for release signing")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}
