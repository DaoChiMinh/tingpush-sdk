group = "com.tingpush.flutter"
version = "1.1.0"

buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

// Viết bằng Java để chạy được với cả AGP 8 (Kotlin plugin riêng) và AGP 9 (Kotlin tích hợp).
android {
    namespace = "com.tingpush.flutter"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        minSdk = 24
    }
}

dependencies {
    implementation("androidx.core:core:1.13.1")
}
