# Better PowerShell/CMD

Configuration automatique d’un terminal Windows stylé : **Windows Terminal** (thème Catppuccin Mocha, transparence, Nerd Font) + **Fastfetch** au démarrage de **Windows PowerShell** (profil principal) et de l’**Invite de commandes** (onglet CMD dans le Terminal).

Inspiré du tutoriel de [SleepyCatHey](https://www.youtube.com/watch?v=z3NpVq-y6jU) — ce dépôt regroupe tout en un seul script cliquable.

> Le nom **Better PowerShell/CMD** reflète l’ordre des priorités : PowerShell est configuré en premier (profil, thème, fastfetch) ; CMD dans le Terminal reçoit le même rendu via `cmd-init.cmd`.

## Aperçu

![Aperçu du terminal configuré par Better PowerShell/CMD](./preview.png)

## Ce que fait le script

En lançant `Better-PowerShell-CMD.bat`, le script affiche une **interface console structurée** (panneaux, journal coloré, barre de progression) puis :

| Étape | Action |
|--------|--------|
| **winget** | Vérifie la présence de `winget` ; l’installe via App Installer si besoin |
| **Fastfetch** | Installe [Fastfetch](https://github.com/fastfetch-cli/fastfetch) et copie la config (`fastfetch/`) vers `%USERPROFILE%\.config\fastfetch` |
| **Polices** | Télécharge **JetBrains Mono Nerd Font** (variantes Mono) depuis GitHub si `fonts/` est vide, puis installe chaque `.ttf` / `.otf` pour l’utilisateur (copie, registre avec le **vrai nom** TTF, `AddFontResource`, rafraîchissement du cache). Barre de progression sur **une seule ligne** (verte à 100 %) |
| **Windows Terminal** | Copie `LocalState/settings.json` ; sauvegarde **une seule fois** ton ancien `settings.json` comme ancre (`settings-before-first-better-powershell-cmd.json`) s’il était **différent** du fichier du projet |
| **Suivi** | `%USERPROFILE%\.better-powershell-cmd\install-state.json` — les relances ne **re-copient** que ce qui a changé dans le dépôt (ou utilise **`-Force`**) |
| **PowerShell** | Déploie `Documents\WindowsPowerShell\profile.ps1` (UTF-8, fastfetch avec chemin de config explicite) |
| **CMD (dans le Terminal)** | Déploie `%USERPROFILE%\.better-powershell-cmd\cmd-init.cmd` et met à jour le profil CMD dans `settings.json` (`cmd /k` vers ce script) pour fastfetch au démarrage |
| **Relance** | Redémarre Windows Terminal pour appliquer les changements |

Données côté utilisateur :

- **`%USERPROFILE%\.better-powershell-cmd\`** — `cmd-init.cmd`, suivi d’installation
- **`%USERPROFILE%\.better-powershell-cmd-backups\`** — ancre WT et sauvegardes horodatées

## Prérequis

- **Windows 10/11**
- **[Windows Terminal](https://aka.ms/terminal)** (Microsoft Store)
- Connexion Internet recommandée (winget, Fastfetch, téléchargement des polices si `fonts/` est vide)
- **`tar.exe`** disponible (inclus sur Windows 11) pour extraire l’archive des polices
- Droits **administrateur** au premier lancement (élévation UAC de `Better-PowerShell-CMD.bat`)

## Installation

1. Clone ou télécharge ce dépôt.
2. Double-clique sur **`Better-PowerShell-CMD.bat`** et accepte l’élévation UAC.
3. Le script **télécharge automatiquement** les polices si `fonts/` est vide. Tu peux aussi placer tes propres `.ttf` / `.otf` dans `fonts/` avant de lancer.
4. Attends la fin du script — Windows Terminal se rouvre avec la nouvelle config.

### Ligne de commande

```powershell
# Installation (ne redéploie que ce qui a changé dans le dépôt)
.\Better-PowerShell-CMD.ps1

# Tout ré-appliquer depuis le dépôt
.\Better-PowerShell-CMD.ps1 -Force

# Désinstallation
.\Better-PowerShell-CMD.ps1 -Uninstall

# Désinstallation + suppression des sauvegardes (ancre incluse)
.\Better-PowerShell-CMD.ps1 -Uninstall -Purge
```

**Désinstallation sans PowerShell :** `Better-PowerShell-CMD-Uninstall.bat` — ajoute **`/Purge`** ou **`-Purge`** en argument pour effacer aussi les sauvegardes.

> **Note :** la désinstallation **ne retire pas** les polices copiées depuis `fonts/`. Le dossier fastfetch n’est supprimé que s’il contient le marqueur `.better-powershell-cmd-managed`.

> **Migration depuis l’ancien nom « Better CMD » :** au premier lancement, le script déplace `.better-cmd` → `.better-powershell-cmd` et les sauvegardes associées. Les fichiers `Better-CMD.bat` / `Better-CMD-Uninstall.bat` restent des **alias** vers les nouveaux lanceurs.

## Structure du projet

```
Better-CMD/                          # nom du dossier sur disque (historique)
├── Better-PowerShell-CMD.bat        # Lanceur (admin) — à utiliser en priorité
├── Better-PowerShell-CMD.ps1        # Script principal
├── Better-PowerShell-CMD-Uninstall.bat
├── Better-CMD.bat                   # Alias → Better-PowerShell-CMD.bat
├── Better-CMD-Uninstall.bat         # Alias désinstallation
├── cmd-init.cmd                     # Copié vers %USERPROFILE%\.better-powershell-cmd\
├── preview.png
├── fonts/                           # Polices (téléchargées auto ou ajoutées à la main)
├── fastfetch/
│   ├── config.jsonc
│   └── ascii.txt
├── LocalState/
│   └── settings.json                # Profils et apparence Windows Terminal
└── WindowsPowerShell/
    └── profile.ps1                  # Profil PowerShell 5.1 déployé
```

## PowerShell et CMD

- **Même rendu visuel** (police Nerd Font, couleurs Catppuccin, transparence) : les profils héritent de `profiles.defaults` dans `settings.json`.
- **Fastfetch au démarrage** : PowerShell via `profile.ps1` ; CMD via `cmd-init.cmd` dans l’onglet « Invite de commandes » du Terminal (pas l’invite Win+R seule).

Police par défaut dans Windows Terminal : **JetBrainsMono NFM** (nom Nerd Fonts v3.4+).

## Personnalisation

- **Terminal** : modifie `LocalState/settings.json`, puis relance `Better-PowerShell-CMD.bat`.
- **Fastfetch** : édite `fastfetch/config.jsonc` ou `fastfetch/ascii.txt`.
- **Polices** : ajoute ou retire des fichiers dans `fonts/`, puis relance le script.

## Dépannage

| Problème | Piste |
|----------|--------|
| `winget` introuvable | Relance le script après [App Installer](https://apps.microsoft.com/detail/9nblggh4nns1) |
| `fonts/` vide après clone | Internet + `tar.exe` ; le script télécharge JetBrains Mono Nerd Font (v3.4.0) |
| Icônes cassées dans Fastfetch | Relance le script : il corrige le registre des polices. Vérifie que `fonts/` n’est pas vide |
| Police absente dans WT | Relance avec `-Force`, ferme complètement Windows Terminal. Police attendue : **JetBrainsMono NFM** |
| CMD sans Fastfetch | Relance le script ; ouvre CMD **dans Windows Terminal**, pas via Win+R |
| Profil : scripts non signés | `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned` ou `Unblock-File` sur le profil |
| Restaurer l’ancien terminal | `Better-PowerShell-CMD-Uninstall.bat` |

## Crédits

- Tutoriel d’origine : **SleepyCatHey**
- [Fastfetch](https://github.com/fastfetch-cli/fastfetch)
- [JetBrains Mono Nerd Font](https://github.com/ryanoasis/nerd-fonts)
- Thème **Catppuccin Mocha**

## Licence

Projet fourni tel quel, sans garantie. Les polices et outils tiers restent soumis à leurs licences respectives.
