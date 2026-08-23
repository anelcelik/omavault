import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// OmaVault: back up this machine's Omarchy setup (bar/dock/search/theme
// settings, installed plugins, Hyprland config, terminal configs, optional
// dotfiles) to a folder tree -- typically a USB stick -- as plain,
// uncompressed, unencrypted files, then restore that same tree onto a
// fresh Omarchy install. All the real work (scanning, copying, checksums)
// happens in bin/*.sh; this file is just the bar chip + popup UI that
// drives those scripts and renders their JSON output. See bin/lib.sh for
// the category registry shared by every script.
BarWidget {
  id: root

  moduleName: "io.github.anelcelik.omavault"

  readonly property string pluginDir: Quickshell.env("HOME") + "/.config/omarchy/plugins/io.github.anelcelik.omavault"
  readonly property string binDir: root.pluginDir + "/bin"

  property bool popupOpen: false
  property string activeTab: "export" // "export" | "import"

  // ---- Export state ----
  property var categories: []           // [{id,label,description,defaultOn,fileCount,bytes}], from list-categories.sh
  property var selectedCategories: ({}) // id -> bool, seeded from each category's defaultOn once loaded
  property var drives: []               // [{path,label,freeBytes,sizeBytes,hasVault,snapshots}], from list-drives.sh
  property string destPath: ""
  property string customDestText: ""
  property string exportMode: "new"     // "new" | "latest"
  property bool scanningCategories: false
  property bool scanningDrives: false
  property bool exporting: false
  property var exportResult: null
  property string exportError: ""
  property bool exportEncrypt: false
  property string exportPassphrase: ""
  property string exportPassphraseConfirm: ""

  // ---- Import state ----
  property string importSourcePath: ""   // the snapshot dir as chosen (may be encrypted)
  property string importWorkingPath: ""  // what inspect/import actually read: importSourcePath, or a decrypted temp dir
  property string customImportText: ""
  property var importInspect: null      // inspect-snapshot.sh result, always against importWorkingPath
  property var importSelectedCategories: ({})
  property bool inspecting: false
  property bool importing: false
  property var importResult: null
  property string importError: ""
  property bool confirmingImport: false
  property bool importUnlocked: false    // true once a locked snapshot's passphrase has been verified
  property string importUnlockPassphrase: ""
  property bool unlocking: false
  property string unlockError: ""

  // ---- In-popup folder browser (Browse... buttons) ----
  // Deliberately not a native GTK/portal file dialog -- that reliably
  // crashed the whole Quickshell process in testing (GVFS aborting inside
  // libgtk-3's directory-monitor D-Bus call the moment the dialog opened).
  // This stays entirely in-process: just `ls` plus a QML list.
  property string browsingTarget: "" // "" | "export" | "import"
  property string browsePath: ""
  property string browseParent: ""
  property var browseEntries: []
  property string browseError: ""
  property string browseFilter: ""

  function visibleBrowseEntries() {
    var q = root.browseFilter.trim().toLowerCase()
    if (!q) return root.browseEntries
    return root.browseEntries.filter(function(e) { return e.name.toLowerCase().indexOf(q) !== -1 })
  }

  implicitWidth: chip.implicitWidth
  implicitHeight: chip.implicitHeight

  function popupForeground() { return root.bar ? root.bar.barForeground : Color.foreground }

  // ---- In-popup folder browser ----

  function openBrowser(target) {
    root.browsingTarget = target
    var start = target === "export" ? root.destPath : root.importSourcePath
    // A restored backup didn't necessarily arrive on a USB stick -- it
    // could just as well be a folder someone downloaded (cloud sync,
    // email attachment, etc.), so Import starts its browser in Downloads
    // rather than assuming a mounted drive. list-dir.sh falls back to
    // $HOME on its own if Downloads doesn't exist.
    var fallback = target === "import" ? Quickshell.env("HOME") + "/Downloads" : Quickshell.env("HOME")
    root.loadBrowseDir(start || fallback)
  }

  function closeBrowser() {
    root.browsingTarget = ""
    root.browseFilter = ""
  }

  function loadBrowseDir(path) {
    if (browseProc.running) return
    root.browseFilter = ""
    browseProc.command = ["bash", root.binDir + "/list-dir.sh", path]
    browseProc.running = true
  }

  function handleBrowseResult(text) {
    try {
      var result = JSON.parse(String(text || "{}"))
      if (result.ok) {
        root.browsePath = result.path
        root.browseParent = result.parent || ""
        root.browseEntries = result.entries || []
        root.browseError = ""
      } else {
        root.browseError = result.error || "Could not read that folder."
      }
    } catch (e) {
      root.browseError = "Could not read that folder."
    }
  }

  function confirmBrowse() {
    if (root.browsingTarget === "export") {
      root.destPath = root.browsePath
      root.customDestText = root.browsePath
    } else if (root.browsingTarget === "import") {
      root.customImportText = root.browsePath
      root.openImportSource(root.browsePath)
    }
    root.closeBrowser()
  }

  function formatBytes(n) {
    var v = Number(n) || 0
    if (v < 1024) return v + " B"
    if (v < 1024 * 1024) return (v / 1024).toFixed(1) + " KB"
    return (v / (1024 * 1024)).toFixed(1) + " MB"
  }

  // ---- Popup open/close ----

  function togglePopup() {
    if (root.popupOpen) {
      root.close()
    } else {
      root.popupOpen = true
      root.refreshCategories()
      root.refreshDrives()
    }
  }

  function close() {
    root.popupOpen = false
    root.confirmingImport = false
    // Don't leave a decrypted backup's plaintext sitting around once the
    // popup isn't even open any more.
    root.cleanupImportWorkingCopy()
  }

  // KeyboardPanel's outside-click dismissal calls owner.close() -- see the
  // same contract noted in OmaHarbor.qml / opentv's BarWidget.qml.
  QtObject {
    id: popupOwner
    function close() { root.close() }
  }

  // ---- Category selection ----

  function isCategoryOn(id) {
    return root.selectedCategories[id] === true
  }

  function toggleCategory(id) {
    var next = {}
    for (var k in root.selectedCategories) next[k] = root.selectedCategories[k]
    next[id] = !root.isCategoryOn(id)
    root.selectedCategories = next
  }

  function selectedCategoryIds() {
    var ids = []
    for (var i = 0; i < root.categories.length; i++) {
      var c = root.categories[i]
      if (root.isCategoryOn(c.id)) ids.push(c.id)
    }
    return ids
  }

  function isImportLocked() {
    return !!(root.importInspect && root.importInspect.manifest && root.importInspect.manifest.encrypted) && !root.importUnlocked
  }

  function isImportCategoryOn(id) {
    return root.importSelectedCategories[id] === true
  }

  function toggleImportCategory(id) {
    var next = {}
    for (var k in root.importSelectedCategories) next[k] = root.importSelectedCategories[k]
    next[id] = !root.isImportCategoryOn(id)
    root.importSelectedCategories = next
  }

  function selectedImportCategoryIds() {
    var ids = []
    var cats = (root.importInspect && root.importInspect.manifest && root.importInspect.manifest.categories) || []
    for (var i = 0; i < cats.length; i++) {
      if (root.isImportCategoryOn(cats[i].id)) ids.push(cats[i].id)
    }
    return ids
  }

  // ---- Backend calls ----

  function refreshCategories() {
    if (categoriesProc.running) return
    root.scanningCategories = true
    categoriesProc.command = ["bash", root.binDir + "/list-categories.sh"]
    categoriesProc.running = true
  }

  function handleCategoriesResult(text) {
    root.scanningCategories = false
    try {
      var list = JSON.parse(String(text || "[]"))
      var sel = {}
      for (var i = 0; i < list.length; i++) {
        var id = list[i].id
        // Preserve an existing choice across a rescan; otherwise seed from
        // the script's own defaultOn.
        sel[id] = (id in root.selectedCategories) ? root.selectedCategories[id] : !!list[i].defaultOn
      }
      root.categories = list
      root.selectedCategories = sel
    } catch (e) {
      root.categories = []
    }
  }

  function refreshDrives() {
    if (drivesProc.running) return
    root.scanningDrives = true
    drivesProc.command = ["bash", root.binDir + "/list-drives.sh"]
    drivesProc.running = true
  }

  function handleDrivesResult(text) {
    root.scanningDrives = false
    try {
      root.drives = JSON.parse(String(text || "[]"))
    } catch (e) {
      root.drives = []
    }
  }

  function exportPassphraseValid() {
    if (!root.exportEncrypt) return true
    return root.exportPassphrase.length > 0 && root.exportPassphrase === root.exportPassphraseConfirm
  }

  function doExport() {
    if (exportProc.running) return
    var ids = root.selectedCategoryIds()
    var dest = root.destPath
    if (ids.length === 0 || !dest || !root.exportPassphraseValid()) return
    root.exportResult = null
    root.exportError = ""
    root.exporting = true
    var args = ["bash", root.binDir + "/export.sh", ids.join(","), dest, root.exportMode]
    if (root.exportEncrypt) args.push("encrypt")
    exportProc.command = args
    // Passphrase goes over stdin, never argv -- see exportProc's
    // stdinEnabled/onStarted below. Cleared from QML state the instant
    // it's handed off so it isn't sitting in a property afterwards.
    exportProc.pendingPassphrase = root.exportEncrypt ? root.exportPassphrase : ""
    root.exportPassphrase = ""
    root.exportPassphraseConfirm = ""
    exportProc.running = true
  }

  function handleExportResult(text) {
    root.exporting = false
    try {
      var result = JSON.parse(String(text || "{}"))
      if (result.ok) {
        root.exportResult = result
        root.exportError = ""
        root.exportEncrypt = false
        root.refreshDrives()
      } else {
        root.exportResult = null
        root.exportError = result.error || "Export failed."
      }
    } catch (e) {
      root.exportResult = null
      root.exportError = "Export failed -- could not read the script's output."
    }
  }

  // Cleans up a decrypted temp copy (see decrypt-snapshot.sh) if one is
  // currently held. Safe to call unconditionally -- cleanup-temp.sh itself
  // is scoped defensively, and this is a no-op when importWorkingPath is
  // just importSourcePath (an unencrypted snapshot, nothing decrypted).
  function cleanupImportWorkingCopy() {
    if (root.importWorkingPath && root.importWorkingPath !== root.importSourcePath) {
      Quickshell.execDetached(["bash", root.binDir + "/cleanup-temp.sh", root.importWorkingPath])
    }
    root.importWorkingPath = ""
  }

  function openImportSource(path) {
    if (inspectProc.running || !path) return
    root.cleanupImportWorkingCopy()
    root.importSourcePath = path
    root.importInspect = null
    root.importResult = null
    root.importError = ""
    root.importUnlocked = false
    root.importUnlockPassphrase = ""
    root.unlockError = ""
    root.inspecting = true
    inspectProc.command = ["bash", root.binDir + "/inspect-snapshot.sh", path]
    inspectProc.running = true
  }

  function handleInspectResult(text) {
    root.inspecting = false
    try {
      var result = JSON.parse(String(text || "{}"))
      if (!result.ok) {
        root.importInspect = null
        root.importError = result.error || "Could not read that snapshot."
        return
      }
      root.importInspect = result
      var locked = !!(result.manifest && result.manifest.encrypted) && !root.importUnlocked
      if (locked) {
        // Categories/labels are still visible (they're in the plain outer
        // manifest.json), but checksum/restore wait for the passphrase.
        return
      }
      root.importWorkingPath = root.importWorkingPath || root.importSourcePath
      var sel = {}
      var cats = (result.manifest && result.manifest.categories) || []
      for (var i = 0; i < cats.length; i++) sel[cats[i].id] = true
      root.importSelectedCategories = sel
    } catch (e) {
      root.importInspect = null
      root.importError = "Could not read that snapshot."
    }
  }

  function doUnlock() {
    if (decryptProc.running || !root.importUnlockPassphrase) return
    root.unlocking = true
    root.unlockError = ""
    decryptProc.command = ["bash", root.binDir + "/decrypt-snapshot.sh", root.importSourcePath]
    decryptProc.pendingPassphrase = root.importUnlockPassphrase
    root.importUnlockPassphrase = ""
    decryptProc.running = true
  }

  function handleDecryptResult(text) {
    root.unlocking = false
    try {
      var result = JSON.parse(String(text || "{}"))
      if (!result.ok) {
        root.unlockError = result.error || "Could not unlock that backup."
        return
      }
      root.importUnlocked = true
      root.importWorkingPath = result.tempDir
      root.unlockError = ""
      // Re-inspect against the now-decrypted copy for the real checksum
      // status and to unlock the restore checklist.
      root.inspecting = true
      inspectProc.command = ["bash", root.binDir + "/inspect-snapshot.sh", result.tempDir]
      inspectProc.running = true
    } catch (e) {
      root.unlockError = "Could not unlock that backup."
    }
  }

  function requestImport() {
    if (root.selectedImportCategoryIds().length === 0) return
    root.confirmingImport = true
  }

  function doImport() {
    if (importProc.running) return
    var ids = root.selectedImportCategoryIds()
    var path = root.importWorkingPath || root.importSourcePath
    if (ids.length === 0 || !path) return
    root.importResult = null
    root.importError = ""
    root.importing = true
    importProc.command = ["bash", root.binDir + "/import.sh", path, ids.join(",")]
    importProc.running = true
  }

  function handleImportResult(text) {
    root.importing = false
    try {
      var result = JSON.parse(String(text || "{}"))
      if (result.ok) {
        root.importResult = result
        root.importError = ""
      } else {
        root.importResult = null
        root.importError = result.error || "Restore failed."
      }
    } catch (e) {
      root.importResult = null
      root.importError = "Restore failed -- could not read the script's output."
    }
    // Wipe the decrypted plaintext (if any) now that the restore attempt
    // is done, success or not -- nothing left decrypted sitting in tmpfs.
    root.cleanupImportWorkingCopy()
  }

  // Passphrases travel over each process's stdin, never argv (never
  // visible in `ps`), and are cleared from QML state the instant they're
  // written -- see doExport()/doUnlock() above.
  Process {
    id: exportProc
    property string pendingPassphrase: ""
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleExportResult(text) }
    onStarted: {
      if (pendingPassphrase !== "") { write(pendingPassphrase + "\n"); pendingPassphrase = "" }
    }
  }
  Process {
    id: decryptProc
    property string pendingPassphrase: ""
    stdinEnabled: true
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleDecryptResult(text) }
    onStarted: {
      if (pendingPassphrase !== "") { write(pendingPassphrase + "\n"); pendingPassphrase = "" }
    }
  }
  Process { id: categoriesProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleCategoriesResult(text) } }
  Process { id: drivesProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleDrivesResult(text) } }
  Process { id: inspectProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleInspectResult(text) } }
  Process { id: importProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleImportResult(text) } }
  Process { id: browseProc; stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.handleBrowseResult(text) } }

  WidgetButton {
    id: chip
    bar: root.bar
    text: "OV"
    foreground: "#4fd1c5"
    labelVisible: true
    hasVisualContent: true
    tooltipText: "OmaVault -- back up / restore your Omarchy setup"
    fixedWidth: root.vertical ? root.barSize : Style.space(30)
    fixedHeight: root.barSize
    onPressed: function(button) { root.togglePopup() }
  }

  KeyboardPanel {
    id: panel

    anchorItem: chip
    bar: root.bar
    owner: popupOwner
    open: root.popupOpen
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Math.min(mainColumn.implicitHeight, Style.space(580)))
    padding: Style.space(10)

    Item {
      anchors.fill: parent

      Flickable {
        id: flick
        anchors.fill: parent
        contentWidth: width
        contentHeight: mainColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: mainColumn
          width: flick.width
          spacing: Style.space(10)

          // ---- Header: title + tab switcher ----
          Row {
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: "OmaVault"
              color: root.popupForeground()
              font.family: Style.font.family
              font.pixelSize: Style.font.subtitle
              font.bold: true
              width: parent.width - tabRow.implicitWidth - parent.spacing
              elide: Text.ElideRight
            }

            Row {
              id: tabRow
              spacing: Style.space(4)

              Button {
                text: "Export"
                selected: root.activeTab === "export"
                foreground: root.popupForeground()
                fontSize: Style.font.caption
                onClicked: root.activeTab = "export"
              }
              Button {
                text: "Import"
                selected: root.activeTab === "import"
                foreground: root.popupForeground()
                fontSize: Style.font.caption
                onClicked: root.activeTab = "import"
              }
            }
          }

          Text {
            width: parent.width
            text: root.activeTab === "export"
              ? "Copies the config files you pick into a plain folder tree -- no compression, no encryption, every file stays individually readable. Nothing is written until you press Export."
              : "Reads a backup made by OmaVault (checksummed first) and copies its files back into place. Anything about to be overwritten is saved first, so nothing existing is ever lost."
            color: Qt.darker(root.popupForeground(), 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.popupForeground() }

          // =====================================================
          // EXPORT TAB
          // =====================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.activeTab === "export"

            PanelSectionHeader { text: "WHAT TO BACK UP"; foreground: root.popupForeground() }

            Text {
              visible: root.scanningCategories
              text: "Scanning..."
              color: Qt.darker(root.popupForeground(), 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.categories

              Toggle {
                id: catToggle
                required property var modelData
                width: parent.width
                label: modelData.label + "  ·  " + modelData.fileCount + " files, " + root.formatBytes(modelData.bytes)
                description: modelData.description
                checked: root.isCategoryOn(modelData.id)
                foreground: root.popupForeground()
                titleSize: Style.font.caption
                descriptionSize: Style.font.caption
                onClicked: root.toggleCategory(modelData.id)
              }
            }

            PanelSeparator { foreground: root.popupForeground() }
            PanelSectionHeader { text: "DESTINATION"; foreground: root.popupForeground() }

            Repeater {
              model: root.drives

              Rectangle {
                id: driveRow
                required property var modelData
                width: parent.width
                height: Style.space(30)
                radius: Style.space(4)
                color: root.destPath === modelData.path
                  ? Util.alpha(root.popupForeground(), 0.16)
                  : (driveHover.hovered ? Util.alpha(root.popupForeground(), 0.08) : "transparent")

                HoverHandler { id: driveHover }
                TapHandler { onTapped: { root.destPath = driveRow.modelData.path; root.customDestText = "" } }

                Text {
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(8)
                  anchors.rightMargin: Style.space(8)
                  text: driveRow.modelData.label + "  (" + driveRow.modelData.path + ")  ·  "
                    + root.formatBytes(driveRow.modelData.freeBytes) + " free"
                    + (driveRow.modelData.hasVault ? "  ·  has OmaVault backups" : "")
                  color: root.popupForeground()
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }
            }

            Text {
              visible: root.drives.length === 0 && !root.scanningDrives
              width: parent.width
              text: "No removable drive detected. Plug in a USB stick, or type any folder path below."
              color: Qt.darker(root.popupForeground(), 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                width: parent.width - browseDestButton.width - parent.spacing
                placeholderText: "...or type/paste a folder path"
                foreground: root.popupForeground()
                text: root.customDestText
                onTextChanged: {
                  if (text === root.customDestText) return
                  root.customDestText = text
                  if (text.length > 0) root.destPath = text
                }
              }

              Button {
                id: browseDestButton
                text: "Browse..."
                foreground: root.popupForeground()
                bordered: true
                fontSize: Style.font.caption
                onClicked: root.openBrowser("export")
              }
            }

            PanelSeparator { foreground: root.popupForeground() }
            PanelSectionHeader { text: "SNAPSHOT MODE"; foreground: root.popupForeground() }

            Dropdown {
              width: parent.width
              showLabel: false
              foreground: root.popupForeground()
              value: root.exportMode
              options: [
                { value: "new", label: "New timestamped snapshot (keeps history)" },
                { value: "latest", label: "Overwrite the single \"latest\" backup" }
              ]
              onChanged: function(value) { root.exportMode = value }
            }

            PanelSeparator { foreground: root.popupForeground() }

            Toggle {
              width: parent.width
              label: "Encrypt this backup with a password"
              description: "AES-256 via gpg. Off by default -- see the note above about staying plain text. The passphrase is never written to disk or shown in the process list, and isn't remembered anywhere."
              checked: root.exportEncrypt
              foreground: root.popupForeground()
              titleSize: Style.font.caption
              descriptionSize: Style.font.caption
              onClicked: root.exportEncrypt = !root.exportEncrypt
            }

            Column {
              width: parent.width
              spacing: Style.space(6)
              visible: root.exportEncrypt

              TextField {
                width: parent.width
                placeholderText: "Passphrase"
                password: true
                foreground: root.popupForeground()
                text: root.exportPassphrase
                onTextChanged: if (text !== root.exportPassphrase) root.exportPassphrase = text
              }
              TextField {
                width: parent.width
                placeholderText: "Confirm passphrase"
                password: true
                foreground: root.popupForeground()
                text: root.exportPassphraseConfirm
                onTextChanged: if (text !== root.exportPassphraseConfirm) root.exportPassphraseConfirm = text
              }
              Text {
                visible: root.exportPassphrase !== "" && root.exportPassphraseConfirm !== "" && !root.exportPassphraseValid()
                width: parent.width
                text: "Passphrases don't match."
                color: Color.urgent
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
              }
              Text {
                width: parent.width
                text: "There is no password recovery -- if this passphrase is lost, the backup is unreadable."
                color: Qt.darker(root.popupForeground(), 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Button {
              width: parent.width
              text: root.exporting ? "Exporting..." : "Export"
              foreground: root.popupForeground()
              bordered: true
              enabled: !root.exporting && root.destPath !== "" && root.selectedCategoryIds().length > 0 && root.exportPassphraseValid()
              onClicked: root.doExport()
            }

            Text {
              visible: root.exportError !== ""
              width: parent.width
              text: root.exportError
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              visible: root.exportResult !== null
              width: parent.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.exportResult
                  ? ("Backed up " + root.exportResult.totalFiles + " files ("
                     + root.formatBytes(root.exportResult.totalBytes) + ")"
                     + (root.exportResult.encrypted ? ", encrypted" : "") + " to:\n" + root.exportResult.path)
                  : ""
                color: root.popupForeground()
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
              Text {
                visible: root.exportResult && root.exportResult.skippedBinaryCount > 0
                width: parent.width
                text: root.exportResult ? (root.exportResult.skippedBinaryCount + " non-text file(s) were left out -- see README.txt in the backup.") : ""
                color: Qt.darker(root.popupForeground(), 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }

          // =====================================================
          // IMPORT TAB
          // =====================================================
          Column {
            width: parent.width
            spacing: Style.space(8)
            visible: root.activeTab === "import"

            PanelSectionHeader { text: "SOURCE"; foreground: root.popupForeground() }

            Repeater {
              model: root.drives

              Column {
                id: driveVaultBlock
                required property var modelData
                width: parent.width
                spacing: Style.space(2)
                visible: driveVaultBlock.modelData.hasVault

                Text {
                  text: driveVaultBlock.modelData.label + " (" + driveVaultBlock.modelData.path + ")"
                  color: Qt.darker(root.popupForeground(), 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Repeater {
                  model: driveVaultBlock.modelData.snapshots

                  Rectangle {
                    id: snapRow
                    required property var modelData
                    width: parent.width
                    height: Style.space(30)
                    radius: Style.space(4)
                    color: root.importSourcePath === snapRow.modelData.path
                      ? Util.alpha(root.popupForeground(), 0.16)
                      : (snapHover.hovered ? Util.alpha(root.popupForeground(), 0.08) : "transparent")

                    HoverHandler { id: snapHover }
                    TapHandler { onTapped: root.openImportSource(snapRow.modelData.path) }

                    Text {
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(8)
                      text: (snapRow.modelData.encrypted ? "🔒 " : "") + snapRow.modelData.name
                        + (snapRow.modelData.hostname ? "  ·  from " + snapRow.modelData.hostname : "")
                        + (snapRow.modelData.categories && snapRow.modelData.categories.length
                           ? "  ·  " + snapRow.modelData.categories.join(", ") : "")
                      color: root.popupForeground()
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }
                }
              }
            }

            Text {
              visible: !root.drives.some(function(d) { return d.hasVault })
              width: parent.width
              text: "No plugged-in USB stick with an OmaVault backup detected -- that's fine, it doesn't have to be one. Browse to any folder below: Downloads, a cloud-synced folder, wherever the backup landed."
              color: Qt.darker(root.popupForeground(), 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              width: parent.width
              spacing: Style.space(6)

              TextField {
                width: parent.width - browseImportButton.width - parent.spacing
                placeholderText: "...or paste a snapshot folder path, then press Enter"
                foreground: root.popupForeground()
                text: root.customImportText
                onTextChanged: if (text !== root.customImportText) root.customImportText = text
                onAccepted: root.openImportSource(text)
              }

              Button {
                id: browseImportButton
                text: "Browse..."
                foreground: root.popupForeground()
                bordered: true
                fontSize: Style.font.caption
                onClicked: root.openBrowser("import")
              }
            }

            Text {
              visible: root.inspecting
              text: "Reading and verifying..."
              color: Qt.darker(root.popupForeground(), 1.4)
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            Text {
              visible: root.importError !== ""
              width: parent.width
              text: root.importError
              color: Color.urgent
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Column {
              width: parent.width
              spacing: Style.space(8)
              visible: root.importInspect !== null

              PanelSeparator { foreground: root.popupForeground() }

              // ---- Locked: passphrase prompt, nothing else shown until it checks out ----
              Column {
                width: parent.width
                spacing: Style.space(6)
                visible: root.isImportLocked()

                Text {
                  width: parent.width
                  text: "🔒 This backup is encrypted."
                  color: root.popupForeground()
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  TextField {
                    width: parent.width - unlockButton.width - parent.spacing
                    placeholderText: "Passphrase"
                    password: true
                    foreground: root.popupForeground()
                    text: root.importUnlockPassphrase
                    onTextChanged: if (text !== root.importUnlockPassphrase) root.importUnlockPassphrase = text
                    onAccepted: root.doUnlock()
                  }
                  Button {
                    id: unlockButton
                    text: root.unlocking ? "..." : "Unlock"
                    foreground: root.popupForeground()
                    bordered: true
                    fontSize: Style.font.caption
                    enabled: !root.unlocking && root.importUnlockPassphrase !== ""
                    onClicked: root.doUnlock()
                  }
                }

                Text {
                  visible: root.unlockError !== ""
                  width: parent.width
                  text: root.unlockError
                  color: Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              // ---- Unlocked (or never locked): checksum status + checklist ----
              Column {
                width: parent.width
                spacing: Style.space(8)
                visible: !root.isImportLocked()

                Text {
                  width: parent.width
                  text: root.importInspect && root.importInspect.checksumOk
                    ? ("✓ Checksums verified (" + root.importInspect.checksumTotal + " files) -- this backup is intact.")
                    : "✗ Checksum verification failed -- this backup may be corrupted or altered. Restore is blocked."
                  color: root.importInspect && root.importInspect.checksumOk ? "#4fd1c5" : Color.urgent
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                PanelSectionHeader { text: "WHAT TO RESTORE"; foreground: root.popupForeground() }

                Repeater {
                  model: (root.importInspect && root.importInspect.manifest && root.importInspect.manifest.categories) || []

                  Toggle {
                    required property var modelData
                    width: parent.width
                    label: modelData.label + "  ·  " + modelData.fileCount + " files"
                    description: ""
                    checked: root.isImportCategoryOn(modelData.id)
                    foreground: root.popupForeground()
                    titleSize: Style.font.caption
                    onClicked: root.toggleImportCategory(modelData.id)
                  }
                }

                Text {
                  width: parent.width
                  text: "Existing files this would overwrite are copied to ~/.local/state/omavault/pre-restore-<timestamp>/ first. Restoring only adds/overwrites -- it never deletes anything already on this machine."
                  color: Qt.darker(root.popupForeground(), 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }

                Button {
                  width: parent.width
                  text: root.importing ? "Restoring..." : "Restore selected"
                  foreground: root.popupForeground()
                  bordered: true
                  enabled: !root.importing && root.importInspect && root.importInspect.checksumOk
                    && root.selectedImportCategoryIds().length > 0
                  onClicked: root.requestImport()
                }
              }
            }

            Column {
              visible: root.importResult !== null
              width: parent.width
              spacing: Style.space(2)

              Text {
                width: parent.width
                text: root.importResult
                  ? ("Restored " + (root.importResult.categories || []).reduce(function(acc, c) { return acc + c.fileCount }, 0)
                     + " files. Safety copy of anything overwritten: " + root.importResult.backupDir)
                  : ""
                color: root.popupForeground()
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WrapAnywhere
              }
              Text {
                visible: root.importResult && root.importResult.needsRestart
                width: parent.width
                text: "Run \"omarchy-restart-shell\" for the restored bar/plugin settings to take effect."
                color: Qt.darker(root.popupForeground(), 1.4)
                font.family: Style.font.family
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }
          }
        }
      }

      ConfirmDialog {
        anchors.fill: parent
        opened: root.confirmingImport
        message: "Restore " + root.selectedImportCategoryIds().length + " categor"
          + (root.selectedImportCategoryIds().length === 1 ? "y" : "ies")
          + " onto this machine? A safety copy of anything overwritten is made first."
        confirmText: "Restore"
        cancelText: "Cancel"
        foreground: root.popupForeground()
        background: Color.background
        onCanceled: root.confirmingImport = false
        onConfirmed: { root.confirmingImport = false; root.doImport() }
      }

      // In-popup folder browser -- covers the whole popup while active. See
      // the note by browsingTarget's declaration for why this isn't a
      // native file dialog.
      Rectangle {
        id: browserOverlay
        anchors.fill: parent
        visible: root.browsingTarget !== ""
        color: Color.background

        Column {
          id: browserHeader
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(4)

          Text {
            width: parent.width
            text: root.browsingTarget === "export" ? "Choose where to export" : "Choose a snapshot folder"
            color: root.popupForeground()
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Row {
            spacing: Style.space(6)

            Button {
              text: "‹ Up"
              foreground: root.popupForeground()
              bordered: true
              fontSize: Style.font.caption
              enabled: root.browseParent !== ""
              onClicked: root.loadBrowseDir(root.browseParent)
            }
            Button {
              text: "Home"
              foreground: root.popupForeground()
              bordered: true
              fontSize: Style.font.caption
              onClicked: root.loadBrowseDir(Quickshell.env("HOME"))
            }
            Button {
              text: "Downloads"
              foreground: root.popupForeground()
              bordered: true
              fontSize: Style.font.caption
              // A restore source is just as likely to be a folder someone
              // downloaded (cloud sync, email attachment, ...) as an
              // actual USB stick -- this isn't limited to detected drives.
              onClicked: root.loadBrowseDir(Quickshell.env("HOME") + "/Downloads")
            }
          }

          Text {
            width: parent.width
            text: root.browsePath
            color: Qt.darker(root.popupForeground(), 1.4)
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            elide: Text.ElideMiddle
          }

          TextField {
            width: parent.width
            placeholderText: "Search this folder..."
            foreground: root.popupForeground()
            text: root.browseFilter
            onTextChanged: if (text !== root.browseFilter) root.browseFilter = text
          }

          Text {
            visible: root.browseError !== ""
            width: parent.width
            text: root.browseError
            color: Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.popupForeground() }
        }

        Text {
          anchors.top: browserHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.topMargin: Style.space(10)
          visible: root.visibleBrowseEntries().length === 0 && root.browseError === ""
          horizontalAlignment: Text.AlignHCenter
          text: root.browseFilter ? "No matching folders." : "No subfolders here."
          color: Qt.darker(root.popupForeground(), 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        ListView {
          id: browseList
          anchors.top: browserHeader.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: browserFooter.top
          anchors.topMargin: Style.space(4)
          anchors.bottomMargin: Style.space(4)
          clip: true
          model: root.visibleBrowseEntries()

          delegate: Rectangle {
            id: browseRow
            required property var modelData
            width: browseList.width
            height: Style.space(28)
            radius: Style.space(4)
            color: browseRowHover.hovered ? Util.alpha(root.popupForeground(), 0.08) : "transparent"

            HoverHandler { id: browseRowHover }
            TapHandler { onTapped: root.loadBrowseDir(browseRow.modelData.path) }

            Text {
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(8)
              anchors.rightMargin: Style.space(8)
              text: "📁 " + browseRow.modelData.name
              color: root.popupForeground()
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }

        Row {
          id: browserFooter
          anchors.bottom: parent.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          spacing: Style.space(6)

          Button {
            text: "Cancel"
            foreground: root.popupForeground()
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.closeBrowser()
          }
          Button {
            text: "Use this folder"
            foreground: root.popupForeground()
            bordered: true
            fontSize: Style.font.caption
            onClicked: root.confirmBrowse()
          }
        }
      }
    }
  }
}
