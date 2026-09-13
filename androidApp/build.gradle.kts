import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    alias(libs.plugins.androidApplication)
    alias(libs.plugins.composeCompiler)
    alias(libs.plugins.huaweiAgconnect)
}

val packageName = "vip.mystery0.xhu.timetable"
val gitVersionCode: Int = providers.exec {
    commandLine(
        "git",
        "rev-list",
        "HEAD",
        "--count"
    )
}.standardOutput.asText.get().trim().toInt()
val gitVersionName: String =
    providers.exec {
        commandLine(
            "git",
            "rev-parse",
            "--short=8",
            "HEAD"
        )
    }.standardOutput.asText.get().trim()
val appVersionName = libs.versions.app.version.get()

base {
    archivesName.set("XhuTimetable-$appVersionName")
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_21)
    }
}

android {
    namespace = packageName
    compileSdk = libs.versions.android.compileSdk.get().toInt()

    defaultConfig {
        applicationId = packageName
        minSdk = libs.versions.android.minSdk.get().toInt()
        targetSdk = libs.versions.android.targetSdk.get().toInt()
        versionCode = gitVersionCode
        versionName = appVersionName

        ndk {
            abiFilters.add("armeabi-v7a")
            abiFilters.add("arm64-v8a")
        }
        manifestPlaceholders["JPUSH_PKGNAME"] = packageName
        manifestPlaceholders["JPUSH_CHANNEL"] = libs.versions.pushChannel.get()
        manifestPlaceholders["HUAWEI_APPID"] = libs.versions.huaweiPushAppId.get()
        manifestPlaceholders["OPPO_APPKEY"] = libs.versions.oppoPushAppKey.get()
        manifestPlaceholders["OPPO_APPID"] = libs.versions.oppoPushAppId.get()
        manifestPlaceholders["OPPO_APPSECRET"] = libs.versions.oppoPushAppSecret.get()
        manifestPlaceholders["VIVO_APPID"] = libs.versions.vivoPushAppId.get()
        manifestPlaceholders["VIVO_APPKEY"] = libs.versions.vivoPushAppKey.get()
    }
    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
            excludes += "THIRD-PARTY.txt"
        }
    }
    signingConfigs {
        create("sign")
    }

    flavorDimensions += "channel"
    productFlavors {
        create("standard") {
            dimension = "channel"
            buildConfigField("boolean", "ENABLE_UPDATE_CHECK", "true")
        }
        create("store") {
            dimension = "channel"
            buildConfigField("boolean", "ENABLE_UPDATE_CHECK", "false")
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            manifestPlaceholders["JPUSH_APPKEY"] = libs.versions.debugPushAppKey.get()
            resValue(
                "string",
                "feature_api_key",
                "65041db9-520c-4962-a512-34fd055abeae/41eFdAIdx5mMavrd4UYjJtpaz4UJEQWvFMTTmVhJ"
            )
            resValue("string", "app_name", "西瓜课表-debug")
            resValue("string", "app_version_code", gitVersionCode.toString())
            resValue(
                "string",
                "app_version_name",
                "${defaultConfig.versionName}.d$gitVersionCode.$gitVersionName"
            )
            resValue("color", "ic_launcher_background", "#FFEB3B")
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            versionNameSuffix = ".d$gitVersionCode.$gitVersionName"
        }
        release {
            val nightly = System.getenv("NIGHTLY")?.toBoolean() == true

            manifestPlaceholders["JPUSH_APPKEY"] = libs.versions.releasePushAppKey.get()
            resValue(
                "string",
                "feature_api_key",
                "491cab74-338f-4cfa-8192-3d7f985ed8b5/41eFdAIdx5mMavrd4UYjJtpaz4UJEQWvFMTTmVhJ"
            )
            resValue("string", "app_name", "西瓜课表")
            resValue("string", "app_version_code", gitVersionCode.toString())
            if (nightly) {
                resValue(
                    "string",
                    "app_version_name",
                    "${defaultConfig.versionName}.n$gitVersionCode.nightly"
                )
                resValue("color", "ic_launcher_background", "#00BCD4")
                isMinifyEnabled = false
                proguardFiles(
                    getDefaultProguardFile("proguard-android-optimize.txt"),
                    "proguard-rules.pro"
                )
                versionNameSuffix = ".n$gitVersionCode.nightly"
            } else {
                resValue(
                    "string",
                    "app_version_name",
                    "${defaultConfig.versionName}.r$gitVersionCode.$gitVersionName"
                )
                isMinifyEnabled = true
                proguardFiles(
                    getDefaultProguardFile("proguard-android-optimize.txt"),
                    "proguard-rules.pro"
                )
                versionNameSuffix = ".r$gitVersionCode.$gitVersionName"
            }
            signingConfig = signingConfigs.getByName("sign")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_21
        targetCompatibility = JavaVersion.VERSION_21
    }
    buildFeatures {
        buildConfig = true
        resValues = true
    }
    @Suppress("UnstableApiUsage")
    androidResources {
        localeFilters.add("zh-rCN")
    }
    externalNativeBuild {
        cmake {
            path = file("src/main/jni/CMakeLists.txt")
        }
    }
    ndkVersion = "29.0.14206865"
}

dependencies {
    implementation(project(":composeApp"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.viewmodel)
    implementation(platform(libs.koin.bom))
    implementation(libs.koin.android)
}

apply(from = rootProject.file("signing.gradle"))
