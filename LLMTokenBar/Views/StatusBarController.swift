import AppKit
import SwiftUI

@MainActor
final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem
    private var popover: NSPopover
    private let manager: UsagePollingManager
    private let historyStore: UsageHistoryStore
    private let tokenStats: TokenStatsService
    private var settingsWindow: NSWindow?
    private var eventMonitor: Any?
    private var iconObserver: NSObjectProtocol?

    init(manager: UsagePollingManager, historyStore: UsageHistoryStore, tokenStats: TokenStatsService) {
        self.manager = manager
        self.historyStore = historyStore
        self.tokenStats = tokenStats
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = NSPopover()
        super.init()

        setupPopover()
        setupStatusItem()
        observeIconChanges()
    }

    private func setupPopover() {
        let popoverView = PopoverView(manager: manager, tokenStats: tokenStats, onOpenSettings: { [weak self] in
            self?.openSettings()
        })

        popover.contentSize = NSSize(
            width: Constants.UI.popoverWidth,
            height: Constants.UI.popoverHeight
        )
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: popoverView)
    }

    private func setupStatusItem() {
        guard let button = statusItem.button else { return }

        let iconName = UserDefaults.standard.string(forKey: "statusBarIcon") ?? StatusBarIcon.default.rawValue
        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "Token Usage"
        )
        button.imagePosition = .imageLeading
        button.action = #selector(togglePopover)
        button.target = self
    }

    private func observeIconChanges() {
        iconObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateIcon()
            }
        }
    }

    private func updateIcon() {
        let iconName = UserDefaults.standard.string(forKey: "statusBarIcon") ?? StatusBarIcon.default.rawValue
        statusItem.button?.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "Token Usage"
        )
    }

    func updateStatusText(_ text: String) {
        statusItem.button?.title = " \(text)"
    }

    @objc private func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            guard let button = statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let popoverWindow = popover.contentViewController?.view.window {
                popoverWindow.level = .floating
                popoverWindow.hidesOnDeactivate = false
                popoverWindow.makeKey()
            }
            startEventMonitor()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        stopEventMonitor()
    }

    private func startEventMonitor() {
        stopEventMonitor()
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    private func stopEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func openSettings() {
        popover.performClose(nil)

        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView(manager: manager, historyStore: historyStore)
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "LLM Token Bar 설정"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(NSSize(
            width: Constants.UI.settingsWidth,
            height: Constants.UI.settingsHeight
        ))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
