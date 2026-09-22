plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.videocall.video_call"
    compileSdk = 36
    ndkVersion = "28.2.13676358"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.videocall.video_call"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 36
        buildToolsVersion = "36.1.0"
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters.add("arm64-v8a")
        }
        externalNativeBuild {
            cmake {
                abiFilters.clear()
                abiFilters.add("arm64-v8a")
                arguments += listOf(
                    "-DANDROID_STL=c++_shared",
                    "-DMAGIC_SR_ROOT=${rootProject.projectDir.resolve("../..").normalize()}/third_party/magic_sr",
                    "-DMC_STREAMING_ROOT=${rootProject.projectDir.resolve("../..").normalize()}/third_party/mc_streaming",
                )
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
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

dependencies {
    compileOnly("io.github.webrtc-sdk:android:144.7559.09")
}

val repoRoot = rootProject.projectDir.resolve("../..").normalize()
val magicModelDir = repoRoot.resolve("third_party/magic_sr/model")
val magicCombinedModel = magicModelDir.resolve("magic_sr_gpu_params.bin")
tasks.register<Copy>("copyMagicSrModels") {
    doFirst {
        check(magicCombinedModel.exists()) {
            "Missing MagicSR combined model: ${magicCombinedModel.absolutePath}"
        }
        check(magicCombinedModel.length() >= 3_000_000L) {
            "MagicSR combined model too small: ${magicCombinedModel.length()}"
        }
    }
    from(magicModelDir) {
        include("magic_sr_gpu_params.bin")
    }
    into(layout.projectDirectory.dir("src/main/assets/model"))
    doLast {
        val dest = layout.projectDirectory.dir("src/main/assets/model").asFile
        dest.listFiles()?.forEach { file ->
            if (file.name != "magic_sr_gpu_params.bin") {
                file.delete()
            }
        }
    }
}
tasks.named("preBuild").configure { dependsOn("copyMagicSrModels", "hookFlutterWebrtcStreaming") }

tasks.register("hookFlutterWebrtcStreaming") {
    val src = layout.projectDirectory.file("webrtc_patches/SimulcastVideoEncoderFactoryWrapper.kt")
    doLast {
        check(src.asFile.exists()) { "Missing ${src.asFile}" }
        val hosted = file("${System.getProperty("user.home")}/.pub-cache/hosted")
        var patched = 0
        hosted.listFiles()?.forEach { host ->
            host.listFiles()?.filter { it.isDirectory && it.name.startsWith("flutter_webrtc-") }?.forEach { pkg ->
                val dest = pkg.resolve("android/src/main/java/com/cloudwebrtc/webrtc/SimulcastVideoEncoderFactoryWrapper.kt")
                if (dest.parentFile.exists()) {
                    src.asFile.copyTo(dest, overwrite = true)
                    patched += 1
                }
            }
        }
        check(patched > 0) { "flutter_webrtc SimulcastVideoEncoderFactoryWrapper.kt not found in pub-cache" }
    }
}

