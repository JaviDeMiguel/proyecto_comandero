import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Firma de publicación: android/key.properties (ignorado por git) con storePassword,
// keyPassword, keyAlias y storeFile (ruta absoluta del .jks, fuera del repositorio).
// Ver INSTALACION.md, «Actualizar a una versión nueva».
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    FileInputStream(keystorePropertiesFile).use { keystoreProperties.load(it) }
}

android {
    namespace = "es.tpvcomandero.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "es.tpvcomandero.app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode y versionName salen de `version:` en pubspec.yaml.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (keystorePropertiesFile.exists()) {
            create("release") {
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
                storeFile = keystoreProperties.getProperty("storeFile")?.let { file(it) }
                storePassword = keystoreProperties.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // Nunca se firma un release con la clave de depuración: sin key.properties
            // la compilación release falla (ver la comprobación de más abajo).
            signingConfig = signingConfigs.findByName("release")
        }
    }
}

// Falla con un mensaje claro si se intenta empaquetar un release sin la clave de
// publicación, en vez de producir un APK sin firmar o firmado con la de depuración.
gradle.taskGraph.whenReady {
    val empaquetaRelease = allTasks.any {
        it.project == project && it.name.contains("Release") &&
            (it.name.startsWith("package") || it.name.startsWith("assemble") ||
                it.name.startsWith("bundle"))
    }
    if (!empaquetaRelease) return@whenReady
    if (!keystorePropertiesFile.exists()) {
        throw GradleException(
            "Falta android/key.properties: el APK de publicación debe firmarse con la clave " +
                "de TPV Comandero (ver INSTALACION.md). No se firma con la clave de depuración.",
        )
    }
    val claves = listOf("storePassword", "keyPassword", "keyAlias", "storeFile")
    val faltan = claves.filter { keystoreProperties.getProperty(it).isNullOrBlank() }
    if (faltan.isNotEmpty()) {
        throw GradleException("android/key.properties incompleto, faltan: ${faltan.joinToString()}")
    }
    val almacen = file(keystoreProperties.getProperty("storeFile"))
    if (!almacen.exists()) {
        throw GradleException("No se encuentra el almacén de claves de publicación: $almacen")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
