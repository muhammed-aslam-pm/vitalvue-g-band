group = "com.example.veepoo_sdk"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.3.20"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.0.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
        // Allow local AARs in libs/ to be referenced as module dependencies
        flatDir {
            dirs("libs")
        }
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.example.veepoo_sdk"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
            jniLibs.srcDirs("src/main/jniLibs")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()

                it.outputs.upToDateWhen { false }

                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Local AARs from libs/ - referenced via flatDir repository (required by AGP for library modules)
    implementation(":vpprotocol-2.3.71.15@aar")
    implementation(":vpbluetooth-1.20@aar")
    implementation(":libble-0.5@aar")
    implementation(":libdfu-1.5@aar")
    implementation(":libfastdfu-0.5@aar")
    implementation(":abpartool-release@aar")
    implementation(":BmpConvert_V1.6.0_10604-release@aar")
    implementation(":jl_bt_ota_V1.10.0_10931-release@aar")
    implementation(":jl_rcsp_V0.7.2_527-release@aar")
    implementation(":JL_Watch_V1.13.1_11214-release@aar")
    // Local JARs (these are fine as fileTree - not AARs)
    implementation(fileTree("libs") { include("*.jar"); exclude("gson-*.jar") })

    // Use a single explicit gson version (exclude the bundled gson-2.2.4.jar above)
    implementation("com.google.code.gson:gson:2.8.9")
    implementation("androidx.localbroadcastmanager:localbroadcastmanager:1.1.0")
    
    // Nordic OTA Upgrade (Required by SDK)
    implementation("no.nordicsemi.android:mcumgr-core:2.7.4")
    implementation("no.nordicsemi.android:mcumgr-ble:2.7.4")
    // Nordic BLE Scanner Compat (Required by SDK)
    implementation("no.nordicsemi.android.support.v18:scanner:1.4.2")

    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}

configurations.all {
    resolutionStrategy {
        // Force a single gson version across all dependencies to prevent conflicts
        force("com.google.code.gson:gson:2.8.9")
    }
}
