import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

val versionProps = Properties()
val versionFile = rootProject.file("version.properties")
if (versionFile.exists()) {
    versionProps.load(versionFile.inputStream())
}
val vName = versionProps.getProperty("versionName") ?: "1.0.0"
val nameParts = vName.split(".")
val vCode = nameParts.getOrElse(0) { "1" }.toInt() * 10000 +
            nameParts.getOrElse(1) { "0" }.toInt() * 100 +
            nameParts.getOrElse(2) { "0" }.toInt()

// 构建信息（写进 BuildConfig，供“关于”弹框展示）
val buildTime = SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault()).format(Date())
val gitCommit = try {
    val process = ProcessBuilder("git", "rev-parse", "--short", "HEAD")
        .directory(rootProject.projectDir)
        .redirectErrorStream(true)
        .start()
    val out = process.inputStream.bufferedReader().use { it.readText() }.trim()
    process.waitFor()
    out.ifBlank { "unknown" }
} catch (e: Exception) {
    "unknown"
}

android {
    namespace = "com.example.clipboardmerger"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.example.clipboardmerger"
        minSdk = 26
        targetSdk = 34
        versionCode = vCode
        versionName = vName

        buildConfigField("String", "BUILD_TIME", "\"$buildTime\"")
        buildConfigField("String", "GIT_COMMIT", "\"$gitCommit\"")

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
    // JVM 目标 17，与 `org.gradle.java.home` 的 JDK 17 统一。
    // 注意：目标 ≥ 9 时 AGP 会用 jlink 造 jdkImage（JdkImageTransform），而 JDK 21 的 jlink
    // 会拒收 AGP 生成的 java.base.jmod（`ModuleTarget is malformed: ... android`）⇒ 必须用 JDK 17。
    // Java / Kotlin 的 JVM 目标必须一致，否则 AGP 8 报 "Inconsistent JVM-target compatibility"。
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions {
        jvmTarget = "17"
    }
    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    applicationVariants.all {
        outputs.forEach {
            (it as com.android.build.gradle.internal.api.BaseVariantOutputImpl).outputFileName =
                "JianJi-v${vName}-${vCode}.apk"
        }
    }
}

layout.buildDirectory = file("${rootProject.projectDir}/build")

dependencies {
    implementation("androidx.core:core-ktx:1.12.0")
    implementation("androidx.appcompat:appcompat:1.6.1")
    implementation("com.google.android.material:material:1.10.0")
    implementation("androidx.constraintlayout:constraintlayout:2.1.4")
    implementation("androidx.recyclerview:recyclerview:1.3.1")
    implementation("androidx.swiperefreshlayout:swiperefreshlayout:1.1.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.6.2")
    implementation("androidx.lifecycle:lifecycle-livedata-ktx:2.6.2")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.7.3")
    implementation("androidx.activity:activity-ktx:1.8.0")
}