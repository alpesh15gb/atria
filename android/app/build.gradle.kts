import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing, read from android/key.properties when it exists.
//
// The template ships release builds signed with the *debug* key, which is fine
// for `flutter run --release` and unacceptable for a shop: a debug-signed APK
// cannot be updated by a release-signed one, Play rejects it outright, and
// anybody who has the (public, well-known) debug keystore can sign a build that
// Android will accept as an update to the installed app.
//
// key.properties is deliberately not committed. Create it with:
//
//   storeFile=C:/keys/atria-upload.jks
//   storePassword=...
//   keyAlias=upload
//   keyPassword=...
//
// and keep the .jks somewhere backed up: losing it means no existing install
// can ever be updated in place.
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKeystore = keystorePropertiesFile.exists()
if (hasReleaseKeystore) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.atria.atria"
    // file_picker 8.x ships AAR metadata requiring compileSdk 36; the Flutter
    // template default (flutter.compileSdkVersion) is lower. Raising compileSdk
    // only affects available APIs, not runtime behavior (that's targetSdk).
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.atria.atria"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = file(keystoreProperties["storeFile"] as String)
                storePassword = keystoreProperties["storePassword"] as String
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Falls back to the debug key when key.properties is absent, so a
            // developer can still `flutter build apk --release` without the
            // shop's keystore — loudly, in the build log, rather than silently.
            if (hasReleaseKeystore) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                signingConfig = signingConfigs.getByName("debug")
                logger.warn(
                    "Atria: android/key.properties not found — the release APK is "
                        + "signed with the debug key and must not be distributed."
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
