import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
}

// Optional release signing. Credentials live in `keystore.properties` (git-ignored, never
// committed); when it's absent — clones, CI without secrets — release falls back to the debug
// key so `assembleRelease` always produces an installable APK. See docs/BUILD.md.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}
val isStagingRelease = project.hasProperty("stagingRelease")
val requestedReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}

android {
    namespace = "com.noop"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.noop.whoop"
        minSdk = 26
        targetSdk = 34
        versionCode = 307
        versionName = "9.3.1"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    signingConfigs {
        getByName("debug") {
            val forkDebugKeystore = rootProject.file("fork-debug.keystore")
            if (forkDebugKeystore.exists()) {
                storeFile = forkDebugKeystore
                storePassword = "android"
                keyAlias = "androiddebugkey"
                keyPassword = "android"
            }
        }
        create("release") {
            if (keystorePropsFile.exists()) {
                storeFile = rootProject.file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // Shipped UNMINIFIED for reliability. R8 minification crashes this app at runtime: full-mode
            // over-strips reflective paths, and even with full-mode OFF + broad keeps (com.noop.** +
            // Tink/Worker/ViewModel) a minified build STILL died right after the terms gate on a real
            // device — a library reflective path we couldn't pin without a device to trace. Offline app,
            // a ~18 MB APK is fine. Re-enabling minify needs the exact crash trace + device verification.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (!keystorePropsFile.exists() && !isStagingRelease && requestedReleaseBuild) {
                throw GradleException(
                    "Refusing to build a real release without keystore.properties. " +
                        "Use -PstagingRelease for debug-key staging artifacts only."
                )
            }
            // Real release key when keystore.properties is present. The debug-key fallback is allowed
            // only for explicit fork/staging artifacts that install under their own application id.
            signingConfig = if (keystorePropsFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // Fork staging release: built with -PstagingRelease (the fork testing-build CI only), the
            // release APK gets its own id/name so it installs BESIDE both the official app and the
            // .debug staging build. A real release (no property) keeps the true com.noop.whoop id.
            if (isStagingRelease) {
                applicationIdSuffix = ".staging"
                versionNameSuffix = "-staging"
            }
        }
    }

    // Two clearly-distinct apps that install side-by-side:
    //   • full → "NOOP"      (com.noop.whoop)     — the real app, starts empty, pair a strap / import.
    //   • demo → "NOOP Demo"  (com.noop.whoop.demo) — preloaded with 120 days of synthetic data and
    //                          a visible DEMO badge, so anyone can explore every screen with no strap.
    // Build e.g. ./gradlew assembleFullRelease assembleDemoRelease.
    flavorDimensions += "tier"
    productFlavors {
        create("full") {
            dimension = "tier"
            buildConfigField("String", "TIER", "\"full\"")
            buildConfigField("boolean", "ENABLE_DEMO", "false")
        }
        create("demo") {
            dimension = "tier"
            applicationIdSuffix = ".demo"
            versionNameSuffix = "-demo"
            buildConfigField("String", "TIER", "\"demo\"")
            buildConfigField("boolean", "ENABLE_DEMO", "true")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        // Compose Compiler extension matched to Kotlin 1.9.24 (see the official
        // Compose-to-Kotlin compatibility map). Bumping Kotlin requires bumping this.
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

// Room schema JSON export — the Android half of the Room<->GRDB schema parity oracle (#775).
//
// Room's KSP processor writes one JSON file per @Database version describing the EXACT `CREATE TABLE`
// it generates: every column in declaration order with its affinity / NOT NULL / default, plus the
// primary key and indices. That file is the only way a plain JVM test (no device, no Robolectric) can
// see Android's real schema, so `SchemaOracleTest` reads it and compares it against the shared
// `schema_oracle.json` that the Swift `SchemaOracleTests` compares GRDB's `PRAGMA table_info` to.
//
// Exported into the BUILD directory, deliberately NOT committed. The committed artifact is the shared
// oracle fixture; Room's JSON is a DERIVED answer regenerated by KSP on every build, exactly like the
// decoded values the decoder oracle compares. Committing it would create a second copy of the same
// facts to keep in sync, and repo churn on every migration.
val roomSchemaDir = layout.buildDirectory.dir("generated/roomSchemas")
ksp {
    arg("room.schemaLocation", roomSchemaDir.get().asFile.absolutePath)
}
// Room writes the export as a SIDE EFFECT of annotation processing, at a path Gradle knows nothing
// about. Left undeclared, a KSP task that is UP-TO-DATE or restored FROM-CACHE leaves whatever the last
// real execution wrote — so an entity edit that is later reverted keeps the stale export on disk and the
// parity test grades the wrong schema. (Observed directly while building this: after reverting four
// deliberately-broken entities, `kspFullDebugKotlin` reported UP-TO-DATE and `25.json` still described
// the broken shape.) Declaring the directory as a task output puts it under Gradle's snapshot/restore,
// so it is rewritten or restored in lockstep with the rest of KSP's output.
//
// Every MAIN-source-set variant shares this one directory, which is safe because the schema depends only
// on the entities — not on flavor or build type — so two variants in the same build write byte-identical
// content and neither invalidates the other's snapshot.
//
// The `UnitTest`/`AndroidTest` KSP tasks are excluded deliberately, and the exclusion is load-bearing:
// those source sets contain no `@Database`, so the round writes no schema, while Gradle still CLEARS a
// task's declared output directory before executing it. With them included, `kspFullDebugUnitTestKotlin`
// wiped the export that `kspFullDebugKotlin` had just restored, and the test failed on a clean build with
// a warm cache with the directory missing entirely.
fun isMainSourceSetKspTask(name: String) =
    name.startsWith("ksp") && name.endsWith("Kotlin") &&
        !name.contains("UnitTest") && !name.contains("AndroidTest")

tasks.matching { isMainSourceSetKspTask(it.name) }.configureEach {
    outputs.dir(roomSchemaDir).withPropertyName("roomSchemaExport")
    // SELF-HEALING. Declaring the output is not sufficient on its own: the export can still go missing
    // between builds (Gradle's stale-output cleanup removes it after the task graph is reconfigured —
    // a rebase that touches this file is enough) while the task's own inputs are unchanged, so it stays
    // UP-TO-DATE and never rewrites it. Observed exactly that: three oracle tests failed with the
    // directory absent, and only `--rerun-tasks` brought it back. Treat an empty or missing export as
    // out-of-date so the next build regenerates it instead of grading nothing.
    outputs.upToDateWhen {
        roomSchemaDir.get().asFile.walkTopDown().any { it.isFile && it.extension == "json" }
    }
}
// The tests read a SNAPSHOT of the export, not the export itself. KSP's directory has several writers
// across variants and source sets, and it is subject to Gradle's stale-output cleanup, so it can be
// emptied between the KSP round that fills it and the test task that reads it — which is exactly what
// happened after a rebase touched this file: `kspFullDebugKotlin` executed, yet the oracle tests still
// found the directory gone. This Sync task is the SOLE writer of its own output directory, so once the
// copy is made nothing else can remove it, and Gradle snapshots/restores it like any other task output.
val roomSchemaSnapshotDir = layout.buildDirectory.dir("roomSchemaOracle")
val syncRoomSchemaSnapshot = tasks.register<Sync>("syncRoomSchemaSnapshot") {
    description = "Snapshots Room's exported schema JSON for the Room<->GRDB parity oracle (#775)."
    from(roomSchemaDir)
    into(roomSchemaSnapshotDir)
    // ONE variant is enough, and deliberately so: the schema comes from the entities alone, so every
    // variant's KSP round writes byte-identical JSON. Depending on all of them would make a single
    // `testFullDebugUnitTest` run four KSP rounds instead of one.
    dependsOn(tasks.matching { it.name == "kspFullDebugKotlin" })
    // Unit-test KSP can clear the snapshot after Sync has copied it; order Sync after those tasks.
    mustRunAfter(tasks.matching { it.name.startsWith("ksp") && it.name.contains("UnitTest") })
}

tasks.withType<Test>().configureEach {
    // How SchemaOracleTest finds the schema. Depending on the Sync task gives both ORDERING (the compile
    // chain alone only guarantees the app CLASSES exist, which a cache hit can satisfy without the
    // schema being materialised) and a stable, singly-owned directory to read.
    dependsOn(syncRoomSchemaSnapshot)
    systemProperty("room.schemaLocation", roomSchemaSnapshotDir.get().asFile.absolutePath)
    inputs.dir(roomSchemaSnapshotDir).withPropertyName("roomSchemas").optional()
}

// Resolve every external module to the exact version recorded in app/gradle.lockfile. Direct
// dependencies are already pinned below; this also freezes the transitive graph selected through
// AndroidX POMs and the Compose BOM. Update intentionally with `./gradlew :app:dependencies
// --write-locks` and review the lockfile diff alongside the dependency declaration change (#658).
dependencyLocking {
    lockAllConfigurations()
}

dependencies {
    // --- Compose (BOM pins all Compose artifact versions in lockstep) ---
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // --- Home-screen widget (1.1.x: last line compatible with compileSdk 34) ---
    implementation("androidx.glance:glance-appwidget:1.1.1")
    // Glance's own POM pins work-runtime 2.7.1 (Oct 2021) — pre-Android-14. Pin a current one
    // explicitly so the widget scheduler runs on a WorkManager that's maintained for targetSdk 34.
    // (2.10+ needs compileSdk 35; 2.9.x is the ceiling for this module.)
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // --- Activity / lifecycle / navigation ---
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.2") // collectAsStateWithLifecycle
    implementation("androidx.navigation:navigation-compose:2.7.7")

    // --- Coroutines ---
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // --- Room (local-only persistence; on-device, nothing leaves the phone) ---
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    ksp("androidx.room:room-compiler:$roomVersion")

    // --- AI Coach (opt-in, bring-your-own-key). HTTP client + Keystore-backed key storage. ---
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // --- Health Connect (optional native Android import of steps/HR/HRV/sleep/etc.) ---
    // Pinned to alpha07: alpha11+ require compileSdk 35; this module is compileSdk 34.
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")

    // --- Unit / instrumentation tests ---
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    testImplementation("org.json:json:20240303") // real org.json for JVM unit tests (android.jar ships throwing stubs)
    testImplementation("net.sf.kxml:kxml2:2.3.0") // real XmlPullParser for JVM tests (android.util.Xml is a throwing stub)
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")

    // --- Compose tooling (debug-only) ---
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
