#!/usr/bin/env bash
# Arma el APK de Android a partir de la app web de ../docs.
# Requiere (Ubuntu/Debian): apt install aapt apksigner zipalign dalvik-exchange android-sdk-platform-23 default-jdk
# Firma: usa la clave de $KEYSTORE (por defecto firma/consulta-cuit.jks). Guardala bien:
# sin la MISMA clave no se puede actualizar la app en el teléfono sin desinstalarla.
set -euo pipefail
cd "$(dirname "$0")"
ANDROID_JAR=${ANDROID_JAR:-/usr/lib/android-sdk/platforms/android-23/android.jar}
KEYSTORE=${KEYSTORE:-firma/consulta-cuit.jks}
KS_PASS=${KS_PASS:-consulta-cuit}
SALIDA=${SALIDA:-salida/Consulta-CUIT-BCRA.apk}

rm -rf obj && mkdir -p obj/clases obj/assets/www obj/gen "$(dirname "$SALIDA")"

# 1) Copiar la app web (sin service worker: dentro del APK no hace falta)
cp ../docs/index.html ../docs/manifest.webmanifest ../docs/*.png obj/assets/www/
sed -i "s/if ('serviceWorker' in navigator \&\& /if (false \&\& /" obj/assets/www/index.html
grep -q "if (false && location.protocol" obj/assets/www/index.html || { echo "No se pudo desactivar el service worker" >&2; exit 1; }

# 2) Recursos y R.java
aapt package -f -m -J obj/gen -M AndroidManifest.xml -S res -I "$ANDROID_JAR"

# 3) Compilar Java y pasar a DEX
javac -nowarn -Xlint:-options -source 8 -target 8 -encoding UTF-8 -bootclasspath "$ANDROID_JAR" \
  -d obj/clases $(find src obj/gen -name '*.java')
dalvik-exchange --dex --output=obj/classes.dex obj/clases

# 4) Empaquetar, alinear y firmar
aapt package -f -M AndroidManifest.xml -S res -A obj/assets -I "$ANDROID_JAR" -F obj/sin-firmar.apk
(cd obj && aapt add sin-firmar.apk classes.dex >/dev/null)
zipalign -f -p 4 obj/sin-firmar.apk obj/alineado.apk
if [ ! -f "$KEYSTORE" ]; then
  mkdir -p "$(dirname "$KEYSTORE")"
  keytool -genkeypair -keystore "$KEYSTORE" -storepass "$KS_PASS" -keypass "$KS_PASS" -alias consulta-cuit \
    -keyalg RSA -keysize 2048 -validity 10000 -dname "CN=Consulta CUIT BCRA, O=afelixc, C=AR"
fi
apksigner sign --ks "$KEYSTORE" --ks-pass "pass:$KS_PASS" --out "$SALIDA" obj/alineado.apk
apksigner verify "$SALIDA"
echo "Listo: $SALIDA"
