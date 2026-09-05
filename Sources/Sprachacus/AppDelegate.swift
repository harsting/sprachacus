import AppKit
import Combine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let hotkey = HotkeyMonitor()
    private let dictation = DictationController()
    private var accessibilityPollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupMainMenu()

        dictation.onStateChange = { [weak self] state in
            self?.updateIcon(for: state)
        }

        // The status icon also reflects an active meeting recording.
        MeetingController.shared.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIcon(for: self.dictation.state)
            }
            .store(in: &cancellables)

        hotkey.onToggle = { [weak self] in
            guard let self else { return }
            // Dictation and meeting recording both own the microphone.
            guard !MeetingController.shared.isRecording else {
                self.dictation.overlay.flash(.error("Meeting läuft — Diktat pausiert"), duration: 1.5)
                return
            }
            self.dictation.toggle()
        }
        hotkey.onCancel = { [weak self] in self?.dictation.cancel() }
        hotkey.isBusyProvider = { [weak self] in
            guard let state = self?.dictation.state else { return false }
            return state == .recording || state == .processing
        }

        // Autostart: keep the login item registered — and its path current,
        // e.g. after the app was renamed or moved — unless the user disabled it.
        if Settings.shared.launchAtLogin {
            do {
                try SMAppService.mainApp.register()
            } catch {
                NSLog("Login-Item-Registrierung fehlgeschlagen: \(error.localizedDescription)")
            }
        }

        Task { await self.runOnboarding() }

        // Diagnostic hooks (see README → Diagnose):
        //   defaults write com.marvinharst.sprachacus runSystemAudioSpike -bool YES
        //   defaults write com.marvinharst.sprachacus openTabOnLaunch -string meetings
        if UserDefaults.standard.bool(forKey: "runSystemAudioSpike") {
            Task { await SystemAudioSpike.run() }
        }
        if let path = UserDefaults.standard.string(forKey: "diarizerTestFile") {
            Task { await DiarizerSelfTest.run(path: path) }
        }
        if UserDefaults.standard.bool(forKey: "showOverlayDemo") {
            UserDefaults.standard.set(false, forKey: "showOverlayDemo")
            dictation.overlay.runDemo()
        }
        if let target = UserDefaults.standard.string(forKey: "openTabOnLaunch") {
            if target == "assist" {
                let instruction = UserDefaults.standard.string(forKey: "assistDemoInstruction") ?? ""
                AssistPanelController.shared.show(
                    context: NSPasteboard.general.string(forType: .string),
                    instruction: instruction,
                    generateImmediately: !instruction.isEmpty)
            } else {
                MainWindowController.shared.show(tab: target == "meetings" ? .meetings
                                                    : target == "settings" ? .settings : .history)
            }
        }
    }

    /// Double-clicking the app in Finder/Spotlight while it is already
    /// running opens the main window (a menu-bar app has nothing else to show).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindowController.shared.show()
        return true
    }

    /// Minimal main menu so standard shortcuts (⌘C/⌘V in the prompt editor,
    /// ⌘W, ⌘Q) work inside our own window.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Bearbeiten")
        editMenu.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Fenster")
        windowMenu.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Onboarding

    private func runOnboarding() async {
        if Permissions.accessibilityGranted {
            hotkey.start()
        } else {
            Permissions.requestAccessibility()
            // Poll until the user flips the toggle in System Settings —
            // avoids requiring an app relaunch.
            accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
                guard Permissions.accessibilityGranted else { return }
                timer.invalidate()
                Task { @MainActor in
                    guard let self else { return }
                    self.accessibilityPollTimer = nil
                    self.hotkey.start()
                    self.updateIcon(for: self.dictation.state)
                }
            }
        }

        await Permissions.requestSpeechRecognition()
        await Permissions.requestMicrophone()

        // Pre-download the speech model so the first dictation starts instantly.
        let locale = dictation.locale
        if !(await Transcriber.isModelInstalled(locale: locale)) {
            dictation.overlay.show(phase: .downloading(0))
            do {
                try await Transcriber.ensureModel(locale: locale) { [weak self] progress in
                    Task { @MainActor in self?.dictation.overlay.setPhase(.downloading(progress)) }
                }
                dictation.overlay.flash(.success)
            } catch {
                dictation.overlay.flash(.error("Modell-Download fehlgeschlagen"), duration: 2.5)
            }
        }
        updateIcon(for: dictation.state)
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon(for: .idle)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self // rebuild on every open so checkmarks stay current
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        populateMenu(menu)
    }

    private func updateIcon(for state: DictationController.State) {
        guard let button = statusItem?.button else { return }
        let (symbol, description): (String, String)
        switch state {
        case .idle:
            symbol = Permissions.accessibilityGranted ? "mic" : "mic.slash"
            description = "Bereit"
        case .recording:
            symbol = "mic.fill"
            description = "Aufnahme"
        case .processing:
            symbol = "waveform"
            description = "Verarbeitung"
        }
        if MeetingController.shared.isRecording {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Meeting läuft")
            return
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
    }

    private func populateMenu(_ menu: NSMenu) {
        let toggleItem = NSMenuItem(title: "Diktat starten/stoppen (rechte ⌥)", action: #selector(menuToggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)

        let assistItem = NSMenuItem(title: "Assist öffnen… (rechte ⌥ doppelt)", action: #selector(openAssist), keyEquivalent: "")
        assistItem.target = self
        menu.addItem(assistItem)

        if dictation.state != .idle {
            let abortItem = NSMenuItem(title: dictation.state == .recording
                                        ? "Aufnahme abbrechen (esc)"
                                        : "Verarbeitung abbrechen (esc)",
                                       action: #selector(abortDictation), keyEquivalent: "")
            abortItem.target = self
            menu.addItem(abortItem)
            menu.addItem(.separator())
        }

        let recording = MeetingController.shared.isRecording
        let meetingItem = NSMenuItem(
            title: recording ? "Meeting beenden & zusammenfassen" : "Meeting aufzeichnen…",
            action: #selector(toggleMeeting),
            keyEquivalent: ""
        )
        meetingItem.target = self
        menu.addItem(meetingItem)
        if recording {
            let showItem = NSMenuItem(title: "Meeting-Fenster zeigen", action: #selector(showMeetingWindow), keyEquivalent: "")
            showItem.target = self
            menu.addItem(showItem)
        }

        let windowItem = NSMenuItem(title: "Verlauf & Einstellungen…", action: #selector(openMainWindow), keyEquivalent: "")
        windowItem.target = self
        menu.addItem(windowItem)
        menu.addItem(.separator())

        // Refiner picker
        let refinerMenu = NSMenu()
        for choice in RefinerChoice.allCases {
            let item = NSMenuItem(title: choice.title, action: #selector(selectRefiner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = choice.rawValue
            item.state = Settings.shared.refiner == choice ? .on : .off
            refinerMenu.addItem(item)
        }
        let refinerItem = NSMenuItem(title: "KI-Optimierung", action: nil, keyEquivalent: "")
        refinerItem.submenu = refinerMenu
        menu.addItem(refinerItem)

        // Language picker
        let langMenu = NSMenu()
        for (id, title) in [("de-DE", "Deutsch"), ("en-US", "Englisch")] {
            let item = NSMenuItem(title: title, action: #selector(selectLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = id
            item.state = Settings.shared.localeIdentifier == id ? .on : .off
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Sprache", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)

        menu.addItem(.separator())

        let loginItem = NSMenuItem(title: "Bei Anmeldung starten", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let permItem = NSMenuItem(title: "Berechtigungen prüfen…", action: #selector(checkPermissions), keyEquivalent: "")
        permItem.target = self
        menu.addItem(permItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Sprachacus komplett beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)
    }

    /// Clean shutdown: stop microphone/overlay if a recording is in flight.
    func applicationWillTerminate(_ notification: Notification) {
        dictation.cancel()
        hotkey.stop()
    }

    // MARK: - Menu actions

    @objc private func menuToggle() {
        dictation.toggle()
    }

    @objc private func selectRefiner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let choice = RefinerChoice(rawValue: raw) else { return }
        Settings.shared.refiner = choice
    }

    @objc private func selectLanguage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Settings.shared.localeIdentifier = id
        // Make sure the model for the new language is present.
        Task { @MainActor in
            let locale = Locale(identifier: id)
            if !(await Transcriber.isModelInstalled(locale: locale)) {
                dictation.overlay.show(phase: .downloading(0))
                try? await Transcriber.ensureModel(locale: locale) { [weak self] progress in
                    Task { @MainActor in self?.dictation.overlay.setPhase(.downloading(progress)) }
                }
                dictation.overlay.hide()
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                Settings.shared.launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                Settings.shared.launchAtLogin = true
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Konnte Login-Item nicht ändern"
            alert.informativeText = "\(error.localizedDescription)\n\nTipp: Das klappt am zuverlässigsten, wenn die App in /Applications liegt (make install)."
            alert.runModal()
        }
    }

    @objc private func openMainWindow() {
        MainWindowController.shared.show()
    }

    @objc private func abortDictation() {
        dictation.cancel()
    }

    @objc private func toggleMeeting() {
        if MeetingController.shared.isRecording {
            MeetingController.shared.stopAndSummarize()
        } else {
            MeetingController.shared.start()
        }
    }

    @objc private func showMeetingWindow() {
        MeetingWindowController.shared.show()
    }

    /// Text route into assist mode: clipboard is the context, the user types
    /// the instruction instead of dictating it.
    @objc private func openAssist() {
        AssistPanelController.shared.show(context: NSPasteboard.general.string(forType: .string),
                                          instruction: "",
                                          generateImmediately: false)
    }

    @objc private func checkPermissions() {
        Task { @MainActor in
            var lines: [String] = []
            lines.append("Bedienungshilfen: \(Permissions.accessibilityGranted ? "✅" : "❌ (Systemeinstellungen → Datenschutz → Bedienungshilfen)")")
            lines.append("Mikrofon: \(Permissions.microphoneGranted ? "✅" : "❌")")
            let installed = await Transcriber.isModelInstalled(locale: dictation.locale)
            lines.append("Sprachmodell (\(Settings.shared.localeIdentifier)): \(installed ? "✅" : "❌ wird beim nächsten Diktat geladen")")
            let fmAvailable = await FoundationModelsRefiner().isAvailable()
            lines.append("Apple Intelligence: \(fmAvailable ? "✅" : "❌ (in Systemeinstellungen aktivieren)")")
            let claudeAvailable = await ClaudeCLIRefiner().isAvailable()
            lines.append("Claude CLI: \(claudeAvailable ? "✅" : "❌ nicht gefunden")")
            lines.append("Bildschirm- & Systemaudio (für Meetings): \(SystemAudioCapture.hasPermission ? "✅" : "❌ wird beim ersten Meeting angefragt")")

            if !Permissions.accessibilityGranted { Permissions.requestAccessibility() }
            if !Permissions.microphoneGranted { await Permissions.requestMicrophone() }

            let alert = NSAlert()
            alert.messageText = "Sprachacus — Status"
            alert.informativeText = lines.joined(separator: "\n")
            alert.runModal()
        }
    }

}
