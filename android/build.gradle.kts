// Root build file — declares plugin versions once; applied per-module in app/build.gradle.kts.
// Keep these versions aligned with the shared contract:
//   JDK 25 build / JVM 17 bytecode · AGP 9.5.x · Kotlin 2.4.x · KSP 2.3.x · Compose Compiler shipped with Kotlin.
plugins {
    id("com.android.application") version "9.5.2" apply false
    // Kotlin 2.x ships the Compose compiler in the Kotlin Gradle plugin; the compiler
    // plugin version MUST match the Kotlin version exactly.
    id("org.jetbrains.kotlin.plugin.compose") version "2.4.21" apply false
    // KSP 2.x versions are independent of KGP; 2.3.14 supports KGP 2.3.20-2.4.x and AGP 9.x.
    id("com.google.devtools.ksp") version "2.3.14" apply false
}
