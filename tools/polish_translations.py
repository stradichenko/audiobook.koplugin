#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Post-edit translations for quality, placeholders, and glossary consistency."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import translations as tr

ROOT = Path(__file__).resolve().parents[1]
MSGIDS = json.loads((ROOT / "tools" / "_msgids.json").read_text(encoding="utf-8"))
ORDERED = [x["msgid"] for x in MSGIDS]


def placeholders(s: str) -> list[str]:
    return re.findall(r"%\d+", s)


def fix_nbsp(s: str) -> str:
    return s.replace("\xa0", " ")


# Exact overrides after MT
FR_FIX: dict[str, str] = {
    "Read aloud from here": "Lire à voix haute à partir d’ici",
    "Play aligned audiobook from here": "Lire le livre audio aligné à partir d’ici",
    "Toggle Read-Along": "Activer/désactiver la lecture synchronisée",
    "Stop Read-Along": "Arrêter la lecture synchronisée",
    "Start Text-to-Speech from current page": "Démarrer la synthèse vocale à la page actuelle",
    "Play aligned/enriched audiobook": "Lire un livre audio aligné/enrichi",
    "Start music playlist": "Démarrer une liste de lecture musicale",
    "Play unaligned audiobook": "Lire un livre audio non aligné",
    "Continue listening": "Continuer l’écoute",
    "Sync progress now": "Synchroniser la progression maintenant",
    "Browse libraries…": "Parcourir les bibliothèques…",
    "Downloaded items (none)": "Éléments téléchargés (aucun)",
    "Downloaded items (%1)": "Éléments téléchargés (%1)",
    "Delete from device": "Supprimer de l’appareil",
    "Open audio file...": "Ouvrir un fichier audio…",
    "Generate bug report": "Générer un rapport de bogue",
    "Check for updates": "Rechercher des mises à jour",
    "About / Debug info": "À propos / Infos de débogage",
    "Auto-advance pages": "Avance automatique des pages",
    "Highlight sentences": "Surligner les phrases",
    "Highlight style: %1": "Style de surlignage : %1",
    "Headset media buttons": "Boutons multimédia du casque",
    "Reconnect BT on track change": "Reconnecter le BT au changement de piste",
    "Return to read-aloud": "Retour à la lecture à voix haute",
    "Select voice": "Choisir une voix",
    "Auto (book language)": "Auto (langue du livre)",
    "Installed voices": "Voix installées",
    "Voice set to %1.": "Voix définie : %1.",
    "Loading voices…": "Chargement des voix…",
    "Session recorder settings": "Paramètres de l’enregistreur de session",
    "Start session recorder": "Démarrer l’enregistreur de session",
    "Stop session recorder": "Arrêter l’enregistreur de session",
    "Run device benchmark": "Lancer le test de performance",
    "Put device to sleep when timer ends": "Mettre l’appareil en veille à la fin du minuteur",
    "Keep playing when lid is closed": "Continuer la lecture couvercle fermé",
    "Hide control bar while playing (experimental)": "Masquer la barre de contrôle pendant la lecture (expérimental)",
    "Hide progress bar during read-along": "Masquer la barre de progression pendant la lecture synchronisée",
    "Follow narration page (aligned)": "Suivre la page de narration (aligné)",
    "Keep status bars during read-aloud": "Conserver les barres d’état pendant la lecture à voix haute",
    "Allow speaker playback without Bluetooth": "Autoriser le haut-parleur sans Bluetooth",
    "Include audio in video file": "Inclure l’audio dans le fichier vidéo",
    "Save separate audio files": "Enregistrer des fichiers audio séparés",
    "Forget (un-pair)": "Oublier (dissocier)",
    "Scan for new devices...": "Rechercher de nouveaux appareils…",
    "Turn Bluetooth on": "Activer le Bluetooth",
    "Turn Bluetooth off": "Désactiver le Bluetooth",
    "No chapters available.": "Aucun chapitre disponible.",
    "Loop enabled.": "Boucle activée.",
    "Loop disabled.": "Boucle désactivée.",
    "Playlist shuffled.": "Liste de lecture mélangée.",
    "Shuffle disabled.": "Mélange désactivé.",
    "Logging in…": "Connexion…",
    "Logged in successfully.": "Connexion réussie.",
    "Logged out from Audiobookshelf.": "Déconnecté d’Audiobookshelf.",
    "Loading libraries…": "Chargement des bibliothèques…",
    "Loading items…": "Chargement des éléments…",
    "Library Items": "Éléments de la bibliothèque",
    "Downloaded Items": "Éléments téléchargés",
    "Next page →": "Page suivante →",
    "← Previous page": "← Page précédente",
    "Unnamed Library": "Bibliothèque sans nom",
    "Server: not configured": "Serveur : non configuré",
    "Server: %1 (connected)": "Serveur : %1 (connecté)",
    "Server: %1 (not logged in)": "Serveur : %1 (non connecté)",
    "Cache size: %1": "Taille du cache : %1",
    "Audiobookshelf Server URL": "URL du serveur Audiobookshelf",
    "Enter the URL of your Audiobookshelf server.": "Saisissez l’URL de votre serveur Audiobookshelf.",
    "Server URL saved.": "URL du serveur enregistrée.",
    "Please configure the server URL first.": "Veuillez d’abord configurer l’URL du serveur.",
    "Log in to %1": "Se connecter à %1",
    "Login failed: ": "Échec de la connexion : ",
    "Download (%1 files, %2)": "Télécharger (%1 fichiers, %2)",
    "Chapters: %1  •  Duration: %2": "Chapitres : %1  •  Durée : %2",
    "No downloaded items.": "Aucun élément téléchargé.",
    "Delete %1 from device?\nThis will remove the downloaded audio files.": "Supprimer %1 de l’appareil ?\nCela effacera les fichiers audio téléchargés.",
    "Item deleted.": "Élément supprimé.",
    "this item": "cet élément",
    "Fetching details for %1…": "Récupération des détails pour %1…",
    "item": "élément",
    "Syncing progress…": "Synchronisation de la progression…",
    "Progress synced successfully.": "Progression synchronisée.",
    "Sync failed: ": "Échec de la synchronisation : ",
    "Speech rate: %1x": "Débit : %1×",
    "Pitch: %1": "Hauteur : %1",
    "Volume: %1%%": "Volume : %1 %%",
    "TTS engine: %1": "Moteur TTS : %1",
    "Piper voice: %1": "Voix Piper : %1",
    "Download Piper voice…": "Télécharger une voix Piper…",
    "Voice: %1": "Voix : %1",
    "Accent: %1": "Accent : %1",
    "Voice type: %1": "Type de voix : %1",
    "Low-resource mode (slow devices)": "Mode faibles ressources (appareils lents)",
    "Split sentences aggressively for Piper": "Découper agressivement les phrases pour Piper",
    "Quick start with espeak (while Piper loads)": "Démarrage rapide avec espeak (pendant le chargement de Piper)",
    "Android TTS language: %1": "Langue TTS Android : %1",
    "Auto-detect": "Détection automatique",
    "Auto-detect (script + book language)": "Détection automatique (écriture + langue du livre)",
    "Refresh voice list from internet": "Actualiser la liste des voix depuis Internet",
    "Select audio file": "Sélectionner un fichier audio",
    "Select a book": "Sélectionner un livre",
    "Resume from %1?": "Reprendre à partir de %1 ?",
    "Continue listening from %1?": "Continuer l’écoute à partir de %1 ?",
    "Start from current page": "Démarrer à la page actuelle",
    "Audio playback": "Lecture audio",
    "Transcoding to MP3...\nThis may take a minute.": "Transcodage en MP3…\nCela peut prendre une minute.",
    "Loading the built-in audiobook…": "Chargement du livre audio intégré…",
    "Loading the built-in audiobook…\n%1 / %2": "Chargement du livre audio intégré…\n%1 / %2",
    "Built-in audiobook ready": "Livre audio intégré prêt",
    "Could not load the built-in audiobook.": "Impossible de charger le livre audio intégré.",
    "This book has no built-in audiobook.": "Ce livre ne contient pas de livre audio intégré.",
    "This book has no built-in audiobook. Use Play unaligned audiobook or Start music playlist to play a separate audio file.": "Ce livre ne contient pas de livre audio intégré. Utilisez « Lire un livre audio non aligné » ou « Démarrer une liste de lecture musicale » pour lire un fichier audio séparé.",
    "Could not find the built-in audiobook audio.": "Impossible de trouver l'audio intégré de ce livre.",
    "Keep the audiobook bar": "Conserver la barre du livre audio",
    "Sleep timer set: %1": "Minuteur de veille défini : %1",
    "Sleep timer active.\nTime remaining: %1\n\nCancel the timer?": "Minuteur de veille actif.\nTemps restant : %1\n\nAnnuler le minuteur ?",
    "Sleep timer: playback paused.": "Minuteur de veille : lecture en pause.",
    "15 min": "15 min",
    "30 min": "30 min",
    "45 min": "45 min",
    "60 min": "60 min",
    "1 hour": "1 heure",
    "2 hours": "2 heures",
    "3 hours": "3 heures",
    "15 s": "15 s",
    "30 s": "30 s",
    "60 s": "60 s",
    "Female 1": "Femme 1",
    "Female 2": "Femme 2",
    "Female 3": "Femme 3",
    "Female 4 (breathy)": "Femme 4 (soufflée)",
    "Female 5": "Femme 5",
    "Male 1": "Homme 1",
    "Male 2": "Homme 2",
    "Male 3": "Homme 3",
    "Male 4": "Homme 4",
    "Male 5": "Homme 5",
    "Male 6": "Homme 6",
    "Male 7": "Homme 7",
    "Default (male)": "Par défaut (homme)",
    "Whisper": "Chuchotement",
    "Whisper (female)": "Chuchotement (femme)",
    "Croak": "Voix rauque",
    "Invert (best for e-ink)": "Inverser (idéal pour l’encre électronique)",
    "Background highlight": "Surlignage d’arrière-plan",
    "Box border": "Bordure de cadre",
    "Invert colors": "Inverser les couleurs",
    "Already up to date (v%1).": "Déjà à jour (v%1).",
    "Update available: v%1 (installed: v%2).\n\nDownload and install?": "Mise à jour disponible : v%1 (installée : v%2).\n\nTélécharger et installer ?",
    "Downloading update...": "Téléchargement de la mise à jour…",
    "Checking for updates...": "Recherche de mises à jour…",
    "Updated to v%1.\n\nRestart KOReader to apply the update.": "Mis à jour vers v%1.\n\nRedémarrez KOReader pour appliquer la mise à jour.",
    "No network connection. Please connect to Wi-Fi first.": "Pas de connexion réseau. Veuillez d’abord vous connecter au Wi-Fi.",
    "Starting...": "Démarrage…",
    " (default)": " (par défaut)",
    " (default / off)": " (par défaut / désactivé)",
    " (bundled)": " (inclus)",
    "Downloading ": "Téléchargement de ",
    "…\n(~": "…\n(~",
    " MB)": " Mo)",
    "espeak-ng": "espeak-ng",
    "Piper (neural)": "Piper (neural)",
    "Pico TTS": "Pico TTS",
    "Flite": "Flite",
    "Festival": "Festival",
    "Android": "Android",
    "Platform-native helper": "Assistant natif de la plateforme",
}

ES_FIX: dict[str, str] = {
    "Read aloud from here": "Leer en voz alta desde aquí",
    "Play aligned audiobook from here": "Reproducir audiolibro alineado desde aquí",
    "Toggle Read-Along": "Activar/desactivar lectura sincronizada",
    "Stop Read-Along": "Detener lectura sincronizada",
    "Start Text-to-Speech from current page": "Iniciar texto a voz en la página actual",
    "Play aligned/enriched audiobook": "Reproducir audiolibro alineado/enriquecido",
    "Start music playlist": "Iniciar lista de reproducción musical",
    "Play unaligned audiobook": "Reproducir audiolibro no alineado",
    "Continue listening": "Continuar escuchando",
    "Sync progress now": "Sincronizar progreso ahora",
    "Browse libraries…": "Explorar bibliotecas…",
    "Downloaded items (none)": "Elementos descargados (ninguno)",
    "Downloaded items (%1)": "Elementos descargados (%1)",
    "Delete from device": "Eliminar del dispositivo",
    "Open audio file...": "Abrir archivo de audio…",
    "Generate bug report": "Generar informe de error",
    "Check for updates": "Buscar actualizaciones",
    "About / Debug info": "Acerca de / Información de depuración",
    "Auto-advance pages": "Avance automático de páginas",
    "Highlight sentences": "Resaltar oraciones",
    "Highlight style: %1": "Estilo de resaltado: %1",
    "Headset media buttons": "Botones multimedia de auriculares",
    "Reconnect BT on track change": "Reconectar BT al cambiar de pista",
    "Return to read-aloud": "Volver a la lectura en voz alta",
    "Session recorder settings": "Configuración del grabador de sesión",
    "Start session recorder": "Iniciar grabador de sesión",
    "Stop session recorder": "Detener grabador de sesión",
    "Run device benchmark": "Ejecutar prueba de rendimiento",
    "Put device to sleep when timer ends": "Suspender el dispositivo al terminar el temporizador",
    "Keep playing when lid is closed": "Seguir reproduciendo con la tapa cerrada",
    "Hide control bar while playing (experimental)": "Ocultar barra de control durante la reproducción (experimental)",
    "Hide progress bar during read-along": "Ocultar barra de progreso durante la lectura sincronizada",
    "Follow narration page (aligned)": "Seguir la página de narración (alineado)",
    "Keep status bars during read-aloud": "Conservar barras de estado durante la lectura en voz alta",
    "Allow speaker playback without Bluetooth": "Permitir reproducción por altavoz sin Bluetooth",
    "Include audio in video file": "Incluir audio en el archivo de video",
    "Save separate audio files": "Guardar archivos de audio por separado",
    "Forget (un-pair)": "Olvidar (desemparejar)",
    "Scan for new devices...": "Buscar dispositivos nuevos…",
    "Turn Bluetooth on": "Activar Bluetooth",
    "Turn Bluetooth off": "Desactivar Bluetooth",
    "No chapters available.": "No hay capítulos disponibles.",
    "Loop enabled.": "Bucle activado.",
    "Loop disabled.": "Bucle desactivado.",
    "Playlist shuffled.": "Lista de reproducción mezclada.",
    "Shuffle disabled.": "Mezcla desactivada.",
    "Logging in…": "Iniciando sesión…",
    "Logged in successfully.": "Sesión iniciada correctamente.",
    "Logged out from Audiobookshelf.": "Sesión cerrada en Audiobookshelf.",
    "Loading libraries…": "Cargando bibliotecas…",
    "Loading items…": "Cargando elementos…",
    "Library Items": "Elementos de la biblioteca",
    "Downloaded Items": "Elementos descargados",
    "Next page →": "Página siguiente →",
    "← Previous page": "← Página anterior",
    "Unnamed Library": "Biblioteca sin nombre",
    "Server: not configured": "Servidor: no configurado",
    "Server: %1 (connected)": "Servidor: %1 (conectado)",
    "Server: %1 (not logged in)": "Servidor: %1 (sin sesión)",
    "Cache size: %1": "Tamaño de caché: %1",
    "Audiobookshelf Server URL": "URL del servidor Audiobookshelf",
    "Enter the URL of your Audiobookshelf server.": "Introduce la URL de tu servidor Audiobookshelf.",
    "Server URL saved.": "URL del servidor guardada.",
    "Please configure the server URL first.": "Configura primero la URL del servidor.",
    "Log in to %1": "Iniciar sesión en %1",
    "Login failed: ": "Error de inicio de sesión: ",
    "Download (%1 files, %2)": "Descargar (%1 archivos, %2)",
    "Chapters: %1  •  Duration: %2": "Capítulos: %1  •  Duración: %2",
    "No downloaded items.": "No hay elementos descargados.",
    "Delete %1 from device?\nThis will remove the downloaded audio files.": "¿Eliminar %1 del dispositivo?\nEsto borrará los archivos de audio descargados.",
    "Item deleted.": "Elemento eliminado.",
    "this item": "este elemento",
    "Fetching details for %1…": "Obteniendo detalles de %1…",
    "item": "elemento",
    "Syncing progress…": "Sincronizando progreso…",
    "Progress synced successfully.": "Progreso sincronizado correctamente.",
    "Sync failed: ": "Error de sincronización: ",
    "Speech rate: %1x": "Velocidad de habla: %1×",
    "Pitch: %1": "Tono: %1",
    "Volume: %1%%": "Volumen: %1 %%",
    "TTS engine: %1": "Motor TTS: %1",
    "Piper voice: %1": "Voz Piper: %1",
    "Download Piper voice…": "Descargar voz Piper…",
    "Voice: %1": "Voz: %1",
    "Accent: %1": "Acento: %1",
    "Voice type: %1": "Tipo de voz: %1",
    "Low-resource mode (slow devices)": "Modo de bajos recursos (dispositivos lentos)",
    "Split sentences aggressively for Piper": "Dividir oraciones de forma agresiva para Piper",
    "Quick start with espeak (while Piper loads)": "Inicio rápido con espeak (mientras carga Piper)",
    "Android TTS language: %1": "Idioma TTS de Android: %1",
    "Auto-detect": "Detectar automáticamente",
    "Auto-detect (script + book language)": "Detectar automáticamente (escritura + idioma del libro)",
    "Refresh voice list from internet": "Actualizar lista de voces desde Internet",
    "Select audio file": "Seleccionar archivo de audio",
    "Select a book": "Seleccionar un libro",
    "Resume from %1?": "¿Continuar desde %1?",
    "Continue listening from %1?": "¿Continuar escuchando desde %1?",
    "Start from current page": "Iniciar en la página actual",
    "Audio playback": "Reproducción de audio",
    "Transcoding to MP3...\nThis may take a minute.": "Transcodificando a MP3…\nEsto puede tardar un minuto.",
    "Loading the built-in audiobook…": "Cargando el audiolibro integrado…",
    "Loading the built-in audiobook…\n%1 / %2": "Cargando el audiolibro integrado…\n%1 / %2",
    "Built-in audiobook ready": "Audiolibro integrado listo",
    "Could not load the built-in audiobook.": "No se pudo cargar el audiolibro integrado.",
    "This book has no built-in audiobook.": "Este libro no tiene audiolibro integrado.",
    "This book has no built-in audiobook. Use Play unaligned audiobook or Start music playlist to play a separate audio file.": "Este libro no tiene audiolibro integrado. Use «Reproducir audiolibro no alineado» o «Iniciar lista de reproducción musical» para reproducir un archivo de audio aparte.",
    "Could not find the built-in audiobook audio.": "No se encontró el audio integrado de este libro.",
    "Keep the audiobook bar": "Conservar la barra del audiolibro",
    "Sleep timer set: %1": "Temporizador de sueño: %1",
    "Sleep timer active.\nTime remaining: %1\n\nCancel the timer?": "Temporizador de sueño activo.\nTiempo restante: %1\n\n¿Cancelar el temporizador?",
    "Sleep timer: playback paused.": "Temporizador de sueño: reproducción en pausa.",
    "15 min": "15 min",
    "30 min": "30 min",
    "45 min": "45 min",
    "60 min": "60 min",
    "1 hour": "1 hora",
    "2 hours": "2 horas",
    "3 hours": "3 horas",
    "15 s": "15 s",
    "30 s": "30 s",
    "60 s": "60 s",
    "Female 1": "Mujer 1",
    "Female 2": "Mujer 2",
    "Female 3": "Mujer 3",
    "Female 4 (breathy)": "Mujer 4 (susurrada)",
    "Female 5": "Mujer 5",
    "Male 1": "Hombre 1",
    "Male 2": "Hombre 2",
    "Male 3": "Hombre 3",
    "Male 4": "Hombre 4",
    "Male 5": "Hombre 5",
    "Male 6": "Hombre 6",
    "Male 7": "Hombre 7",
    "Default (male)": "Predeterminado (hombre)",
    "Whisper": "Susurro",
    "Whisper (female)": "Susurro (mujer)",
    "Croak": "Voz ronca",
    "Invert (best for e-ink)": "Invertir (ideal para tinta electrónica)",
    "Background highlight": "Resaltado de fondo",
    "Box border": "Borde de cuadro",
    "Invert colors": "Invertir colores",
    "Already up to date (v%1).": "Ya está actualizado (v%1).",
    "Update available: v%1 (installed: v%2).\n\nDownload and install?": "Actualización disponible: v%1 (instalada: v%2).\n\n¿Descargar e instalar?",
    "Downloading update...": "Descargando actualización…",
    "Checking for updates...": "Buscando actualizaciones…",
    "Updated to v%1.\n\nRestart KOReader to apply the update.": "Actualizado a v%1.\n\nReinicia KOReader para aplicar la actualización.",
    "No network connection. Please connect to Wi-Fi first.": "Sin conexión de red. Conéctate primero al Wi-Fi.",
    "Starting...": "Iniciando…",
    " (default)": " (predeterminado)",
    " (default / off)": " (predeterminado / desactivado)",
    " (bundled)": " (incluido)",
    "Downloading ": "Descargando ",
    "…\n(~": "…\n(~",
    " MB)": " MB)",
    "espeak-ng": "espeak-ng",
    "Piper (neural)": "Piper (neural)",
    "Pico TTS": "Pico TTS",
    "Flite": "Flite",
    "Festival": "Festival",
    "Android": "Android",
    "Platform-native helper": "Asistente nativo de la plataforma",
    # LatAm-neutral replacements for common MT slips
}

ES_REPLACE = [
    ("ordenador", "computadora"),
    ("Ordenador", "Computadora"),
    ("móvil", "teléfono"),
    ("Móvil", "Teléfono"),
    ("vosotros", "ustedes"),
    ("coger ", "tomar "),
    ("Coger ", "Tomar "),
    ("celular", "teléfono"),
    ("fichero", "archivo"),
    ("Fichero", "Archivo"),
    ("carpeta de archivos", "carpeta"),
    ("reproductor de medios", "reproductor multimedia"),
]


def preserve_leading_newlines(src: str, dst: str) -> str:
    m = re.match(r"^(\n+)", src)
    if not m:
        return dst
    prefix = m.group(1)
    if dst.startswith(prefix):
        return dst
    return prefix + dst.lstrip("\n")


def main() -> None:
    fr = dict(tr.TRANSLATIONS_FR)
    es = dict(tr.TRANSLATIONS_ES)

    for mid, val in FR_FIX.items():
        if mid in fr:
            fr[mid] = val
    for mid, val in ES_FIX.items():
        if mid in es:
            es[mid] = val

    for mid in ORDERED:
        if mid in fr:
            fr[mid] = fix_nbsp(fr[mid])
            fr[mid] = preserve_leading_newlines(mid, fr[mid])
        if mid in es:
            s = fix_nbsp(es[mid])
            for a, b in ES_REPLACE:
                s = s.replace(a, b)
            es[mid] = preserve_leading_newlines(mid, s)

    # Placeholder checks
    bad = 0
    for mid in ORDERED:
        for lang, d in (("fr", fr), ("es", es)):
            if placeholders(mid) != placeholders(d[mid]):
                # try to not fail hard for %% vs % — Volume: %1%%
                if sorted(placeholders(mid)) != sorted(placeholders(d[mid])):
                    print(f"PH mismatch {lang}: {mid[:60]!r}")
                    print(f"  -> {d[mid][:60]!r}")
                    bad += 1

    # Rewrite translations.py
    def py_str(s: str) -> str:
        return json.dumps(s, ensure_ascii=False)

    lines = [
        "# -*- coding: utf-8 -*-",
        "# Generated/edited by tools/build_translations.py + polish_translations.py",
        "TRANSLATIONS_FR = {",
    ]
    for mid in ORDERED:
        lines.append(f"    {py_str(mid)}: {py_str(fr[mid])},")
    lines.append("}")
    lines.append("")
    lines.append("TRANSLATIONS_ES = {")
    for mid in ORDERED:
        lines.append(f"    {py_str(mid)}: {py_str(es[mid])},")
    lines.append("}")
    lines.append("")
    out = ROOT / "tools" / "translations.py"
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote {out}; placeholder mismatches reported: {bad}")


if __name__ == "__main__":
    main()
