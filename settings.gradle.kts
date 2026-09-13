rootProject.name = "XhuTimetable"
enableFeaturePreview("TYPESAFE_PROJECT_ACCESSORS")

pluginManagement {
    resolutionStrategy {
        eachPlugin {
            if (requested.id.id == "com.huawei.agconnect") {
                useModule("com.huawei.agconnect:agcp:${requested.version}")
            }
        }
    }
    repositories {
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        mavenCentral()
        maven {
            url = uri("https://developer.huawei.com/repo/")
            content {
                includeGroupAndSubgroups("com.huawei")
            }
        }
        gradlePluginPortal()
    }
}

// 本机配置优先，CI 等未提供本机配置的环境继续使用环境变量。
val localProperties = java.util.Properties().apply {
    val propertiesFile = file("local.properties")
    if (propertiesFile.isFile) {
        propertiesFile.inputStream().use { load(it) }
    }
}

dependencyResolutionManagement {
    repositories {
        maven {
            url = uri("https://maven.pkg.github.com/Mystery00/sheets-compose-dialogs")
            content {
                includeGroup("vip.mystery0.sheets-compose-dialogs")
            }
            credentials {
                username = localProperties.getProperty("GITHUB_USERNAME")
                    ?.takeIf { it.isNotBlank() }
                    ?: providers.environmentVariable("GITHUB_USERNAME").orNull
                password = localProperties.getProperty("GITHUB_PASSWORD")
                    ?.takeIf { it.isNotBlank() }
                    ?: providers.environmentVariable("GITHUB_PASSWORD").orNull
            }
        }
        google {
            mavenContent {
                includeGroupAndSubgroups("androidx")
                includeGroupAndSubgroups("com.android")
                includeGroupAndSubgroups("com.google")
            }
        }
        maven {
            url = uri("https://developer.huawei.com/repo/")
            content {
                includeGroupAndSubgroups("com.huawei")
            }
        }
        mavenCentral()
    }
}

include(":composeApp")

include(":androidApp")
