import AppKit
import SwiftUI
import Combine
@preconcurrency import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    static var retained: AppDelegate?

    private var state: AppState!
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var approvalPanel: NSPanel?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - 启动

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)

        state = AppState()
        buildMainMenu()
        buildStatusItem()
        buildMainWindow()
        observeOffers()
        Notifier.bootstrap()
        UNUserNotificationCenter.current().delegate = self

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    /// Dock 拖拽文件 / Finder「打开方式」/ open -a 时进入发送流程
    func application(_ sender: NSApplication, open urls: [URL]) {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let items = urls.map { SharedItem(url: $0) }
        state.sendWithTargetPicker(items: items)
    }

    // MARK: - 主窗口

    private func buildMainWindow() {
        let hosting = NSHostingView(rootView: MainView().environmentObject(state))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered,
                         defer: false)
        w.title = "GrandLine"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(srgbRed: 0.039, green: 0.055, blue: 0.078, alpha: 1)
        w.contentView = hosting
        w.minSize = NSSize(width: 760, height: 540)
        w.center()
        w.setFrameAutosaveName("GrandLineMainWindow")
        w.isReleasedWhenClosed = false
        self.window = w
    }

    // MARK: - 主菜单（应用级快捷键）

    /// ⌘R 扫描 · ⌘D 收放锚 · ⌘T 航海日志 · ⌘O 货舱 · ⌘, 设置
    private func buildMainMenu() {
        let main = NSMenu()

        // App 菜单
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About GrandLine",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                        keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…",
                        action: #selector(openSettings), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide GrandLine",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Hide Others",
                        action: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit GrandLine",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Go 菜单：本应用的命令入口
        let goItem = NSMenuItem()
        main.addItem(goItem)
        let goMenu = NSMenu(title: "Go")
        goMenu.addItem(withTitle: "Scan", action: #selector(scan), keyEquivalent: "r").target = self
        goMenu.addItem(withTitle: "Find Ship…", action: #selector(findShip), keyEquivalent: "f").target = self
        goMenu.addItem(withTitle: "Toggle Receiving (Set Sail / Drop Anchor)",
                       action: #selector(toggleReceiving), keyEquivalent: "d").target = self
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Send Clipboard…", action: #selector(sendClipboard), keyEquivalent: "k").target = self
        goMenu.addItem(withTitle: "Logbook", action: #selector(openTransfers), keyEquivalent: "t").target = self
        goMenu.addItem(withTitle: "Open Cargo Hold", action: #selector(openInbox), keyEquivalent: "o").target = self
        goMenu.addItem(.separator())
        goMenu.addItem(withTitle: "Settings", action: #selector(openSettings), keyEquivalent: ",").target = self
        goItem.submenu = goMenu

        // Help 菜单：内置使用说明
        let helpItem = NSMenuItem()
        main.addItem(helpItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(withTitle: "How to Sail",
                         action: #selector(openHelp), keyEquivalent: "?").target = self
        helpItem.submenu = helpMenu

        // Edit 菜单：昵称 / PIN 输入框的剪切复制粘贴
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Window 菜单
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Minimize",
                        action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "Close",
                        action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu

        NSApp.mainMenu = main
    }

    // MARK: - 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // 菜单栏用草帽剪影（模板图，随系统明暗自动着色）
            button.image = StrawHatGlyph.image(size: 17)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showStatusMenu()
        } else {
            toggleMainWindow()
        }
    }

    private func toggleMainWindow() {
        guard let window else { return }
        if window.isVisible && window.isKeyWindow {
            window.orderOut(nil)
        } else {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open GrandLine", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Scan", action: #selector(scan), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Send Clipboard…", action: #selector(sendClipboard), keyEquivalent: "k").target = self
        menu.addItem(withTitle: "Logbook…", action: #selector(openTransfers), keyEquivalent: "t").target = self
        menu.addItem(NSMenuItem.separator())

        let recv = NSMenuItem(title: "Allow Receiving", action: #selector(toggleReceiving), keyEquivalent: "d")
        recv.target = self
        recv.state = state.receivingEnabled ? .on : .off
        menu.addItem(recv)

        menu.addItem(withTitle: "Open Cargo Hold", action: #selector(openInbox), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "Quit GrandLine", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func scan() {
        window.makeKeyAndOrderFront(nil)
        state.refresh()
    }

    @objc private func findShip() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.openPeerSearch()
    }

    @objc private func sendClipboard() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.showClipboardSend = true
    }

    @objc private func openTransfers() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.showTransfers = true
    }

    @objc private func openSettings() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.showSettings = true
    }

    @objc private func openHelp() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        state.showHelp = true
    }

    @objc private func openWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func toggleReceiving() {
        state.receivingEnabled.toggle()
    }

    @objc private func openInbox() {
        state.revealInbox()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - 接收确认浮层

    private func observeOffers() {
        state.$pendingOffer
            .receive(on: RunLoop.main)
            .sink { [weak self] offer in
                guard let self else { return }
                if let offer {
                    self.showApproval(offer)
                } else {
                    self.closeApproval()
                }
            }
            .store(in: &cancellables)
    }

    private func showApproval(_ offer: IncomingOffer) {
        closeApproval()

        let view = ApprovalView(
            offer: offer,
            senderAvatar: state.peers.first(where: { $0.id == offer.senderID })?.avatar,
            onAccept: { [weak self] trustNow in
                guard let self else { return }
                self.state.respondToOffer(accept: true)
                if trustNow {
                    self.state.trustPeer(id: offer.senderID, name: offer.senderName)
                }
            },
            onDecline: { [weak self] in self?.state.respondToOffer(accept: false) }
        )

        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .fullSizeContentView],
                            backing: .buffered,
                            defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.level = .floating
        panel.contentView = hosting
        panel.center()
        panel.makeKeyAndOrderFront(nil)

        NSApp.activate(ignoringOtherApps: true)
        approvalPanel = panel
    }

    private func closeApproval() {
        approvalPanel?.orderOut(nil)
        approvalPanel = nil
    }
}

// MARK: - 系统通知代理

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// 点击通知：唤起主窗口
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated { self.openWindow() }
        }
        completionHandler()
    }

    /// App 在前台时也不吞掉通知（AppState 已过滤前台场景，这里保持默认展示）
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - 入口

// NSApplication.delegate 是 assign 语义，需要自行持有强引用
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    AppDelegate.retained = delegate
    let application = NSApplication.shared
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
}
