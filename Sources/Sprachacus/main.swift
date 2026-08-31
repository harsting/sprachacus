//  Sprachacus — lokale Diktier-App für macOS mit KI-Textkorrektur.
//  Copyright (C) 2026 Marvin Ewald Harst — https://harsting.de
//
//  Freie Software unter den Bedingungen der GNU General Public License,
//  Version 3 oder später. Weitergabe ohne jede Gewährleistung; siehe LICENSE.

import AppKit

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
