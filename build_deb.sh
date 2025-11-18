#!/bin/bash
set -e

PKGNAME="agentdvr-updater"
SRCDIR="src"
OUTDEB="${PKGNAME}.deb"

echo "🧹 Nettoyage ancien .deb..."
rm -f "$OUTDEB"

echo "🔍 Vérification structure..."
required_dirs=(
    "$SRCDIR/DEBIAN"
    "$SRCDIR/usr/local/bin"
    "$SRCDIR/etc"
)

for d in "${required_dirs[@]}"; do
    if [[ ! -d "$d" ]]; then
        echo "❌ Erreur : dossier manquant : $d"
        exit 1
    fi
done

if [[ ! -f "$SRCDIR/usr/local/bin/ispy_updater.sh" ]]; then
    echo "❌ Erreur : script introuvable : ispy_updater.sh"
    exit 1
fi

echo "🔧 Permissions..."
chmod 755 "$SRCDIR/usr/local/bin/ispy_updater.sh"
chmod 755 "$SRCDIR/DEBIAN/postinst"
chmod 755 "$SRCDIR/DEBIAN/prerm"
chmod 644 "$SRCDIR/DEBIAN/control"
chmod 644 "$SRCDIR/etc/agentdvr-updater.conf"

echo "📦 Construction du .deb..."
dpkg-deb --build "$SRCDIR" "$OUTDEB"

echo "✔ Paquet créé : $OUTDEB"
