import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    `maven-publish`
}

android {
    namespace = "com.tingpush.sdk"
    compileSdk = 35

    defaultConfig {
        minSdk = 23
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    publishing {
        singleVariant("release") {
            withSourcesJar()
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(platform("com.google.firebase:firebase-bom:33.7.0"))
    implementation("com.google.firebase:firebase-messaging")
    // NotificationCompat.CallStyle cần core 1.9+.
    implementation("androidx.core:core-ktx:1.13.1")
}

// JitPack chạy publishToMavenLocal; groupId được JitPack đổi thành com.github.<user>.<repo>.
publishing {
    publications {
        register<MavenPublication>("release") {
            groupId = "com.tingpush"
            artifactId = "tingpush"
            version = "1.0.0"
            afterEvaluate { from(components["release"]) }
        }
    }
}
