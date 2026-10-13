// Gradle ở gốc repo để JitPack build Android SDK từ tag GitHub (xem jitpack.yml).
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "tingpush-sdk"

include(":tingpush")
project(":tingpush").projectDir = file("android/tingpush")
