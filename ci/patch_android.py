#!/usr/bin/env python3
"""`flutter create` ile üretilen Android dosyalarını uygulamaya göre ayarlar.

- minSdk 24
- core library desugaring (flutter_local_notifications için)
- Kotlin eklentisi 2.1.0 (yeni eklentilerin Kotlin metadata'sı ile uyum)
- Sabit imza: APP_KEYSTORE_FILE ortam değişkeni varsa release APK o anahtarla imzalanır,
  yoksa debug anahtarıyla (yine kurulabilir) imzalanır.
- R8 küçültme kapalı (bildirim/ses kaynakları ve eklentiler güvenle çalışsın)
"""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent / "android"

# Uygulamanın kendi yerel (Java) kodunun ihtiyaç duyduğu kütüphaneler (arka plan servisi).
EXTRA_DEPS = [
    'implementation("androidx.core:core:1.13.1")',
    'implementation(platform("com.google.firebase:firebase-bom:33.1.2"))',
    'implementation("com.google.firebase:firebase-database")',
]


def find_block(text, header_regex):
    m = re.search(header_regex, text)
    if not m:
        return None
    start = m.start()
    i = text.index("{", m.start())
    depth = 0
    for j in range(i, len(text)):
        if text[j] == "{":
            depth += 1
        elif text[j] == "}":
            depth -= 1
            if depth == 0:
                return start, j + 1
    return None


def patch_kts(p):
    t = p.read_text()
    t = re.sub(r"minSdk\s*=\s*flutter\.minSdkVersion", "minSdk = 24", t)
    if "isCoreLibraryDesugaringEnabled" not in t:
        t = re.sub(r"compileOptions\s*\{", "compileOptions {\n        isCoreLibraryDesugaringEnabled = true", t, count=1)
    bt = find_block(t, r"\n\s*buildTypes\s*\{")
    new_bt = '''
    signingConfigs {
        val ksPath = System.getenv("APP_KEYSTORE_FILE")
        if (ksPath != null && file(ksPath).exists()) {
            create("fixed") {
                storeFile = file(ksPath)
                storePassword = System.getenv("APP_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("APP_KEY_ALIAS")
                keyPassword = System.getenv("APP_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            val ksPath = System.getenv("APP_KEYSTORE_FILE")
            signingConfig = if (ksPath != null && file(ksPath).exists())
                signingConfigs.getByName("fixed") else signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }'''
    if bt:
        t = t[: bt[0]] + "\n" + new_bt + t[bt[1]:]
    else:
        sys.exit("buildTypes bloğu bulunamadı")
    if "desugar_jdk_libs" not in t:
        t += '\ndependencies {\n    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")\n'
        for dep in EXTRA_DEPS:
            t += '    ' + dep + '\n'
        t += '}\n'
    p.write_text(t)


def patch_groovy(p):
    t = p.read_text()
    t = re.sub(r"minSdk(Version)?\s*=?\s*flutter\.minSdkVersion", "minSdkVersion 24", t)
    if "coreLibraryDesugaringEnabled" not in t:
        t = re.sub(r"compileOptions\s*\{", "compileOptions {\n        coreLibraryDesugaringEnabled true", t, count=1)
    bt = find_block(t, r"\n\s*buildTypes\s*\{")
    new_bt = '''
    signingConfigs {
        def ksPath = System.getenv("APP_KEYSTORE_FILE")
        if (ksPath != null && file(ksPath).exists()) {
            fixed {
                storeFile file(ksPath)
                storePassword System.getenv("APP_KEYSTORE_PASSWORD")
                keyAlias System.getenv("APP_KEY_ALIAS")
                keyPassword System.getenv("APP_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            def ksPath = System.getenv("APP_KEYSTORE_FILE")
            signingConfig = (ksPath != null && file(ksPath).exists()) ? signingConfigs.fixed : signingConfigs.debug
            minifyEnabled false
            shrinkResources false
        }
    }'''
    if bt:
        t = t[: bt[0]] + "\n" + new_bt + t[bt[1]:]
    if "desugar_jdk_libs" not in t:
        t += "\ndependencies {\n    coreLibraryDesugaring 'com.android.tools:desugar_jdk_libs:2.1.4'\n}\n"
    p.write_text(t)


def patch_settings():
    for name in ("settings.gradle.kts", "settings.gradle"):
        p = ROOT / name
        if p.exists():
            t = p.read_text()
            t = re.sub(r'(org\.jetbrains\.kotlin\.android"\)?\s+version\s+")[^"]+(")', r"\g<1>2.1.0\2", t)
            p.write_text(t)
            print("patched", p)


def main():
    kts = ROOT / "app" / "build.gradle.kts"
    groovy = ROOT / "app" / "build.gradle"
    if kts.exists():
        patch_kts(kts)
        print("patched", kts)
    elif groovy.exists():
        patch_groovy(groovy)
        print("patched", groovy)
    else:
        sys.exit("app/build.gradle(.kts) bulunamadı")
    patch_settings()
    props = ROOT / "gradle.properties"
    if props.exists():
        t = props.read_text()
        if "org.gradle.jvmargs" in t:
            t = re.sub(r"org\.gradle\.jvmargs=.*", "org.gradle.jvmargs=-Xmx4G -XX:MaxMetaspaceSize=1G -XX:+HeapDumpOnOutOfMemoryError", t)
        props.write_text(t)


if __name__ == "__main__":
    main()
