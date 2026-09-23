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
val vCode = (versionProps.getProperty("versionCode") ?: "1").toInt()
val vName = versionProps.getProperty("versionName") ?: "1.0"

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
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }
    kotlinOptions {
        jvmTarget = "1.8"
    }
    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    applicationVariants.all {
        outputs.forEach {
            (it as com.android.build.gradle.internal.api.BaseVariantOutputImpl).outputFileName =
                "ClipboardMerger-v${vName}-${vCode}.apk"
        }
    }
}

tasks.register("incrementVersion") {
    doLast {
        val vf = rootProject.file("version.properties")
        val props = Properties()
        if (vf.exists()) {
            props.load(vf.inputStream())
        }
        val oldCode = (props.getProperty("versionCode") ?: "1").toInt()
        val newCode = oldCode + 1
        val parts = (props.getProperty("versionName") ?: "1.0").split(".")
        val minor = parts.getOrElse(1) { "0" }.toInt() + 1
        val newName = "${parts[0]}.${minor}"
        props.setProperty("versionCode", newCode.toString())
        props.setProperty("versionName", newName)
        vf.writer().use { props.store(it, null) }
        println("Version: code ${oldCode} -> ${newCode}, name -> ${newName}")
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