//
//  CodeCamApp.swift
//  CodeCam
//
//  Created by lai lin on 2026/9/4.
//

import SwiftUI
import SwiftData

@main
struct CodeCamApp: App {
    private let modelContainer: ModelContainer

    init() {
        do {
            let schema = Schema(AppSchema.models)
            modelContainer = try ModelContainer(for: schema)
        } catch {
            fatalError("无法创建本地数据存储：\(error.localizedDescription)")
        }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
        }
        .modelContainer(modelContainer)
    }
}

private enum AppTab: Hashable {
    case tasks
    case capture
    case records
    case mine
}

private struct MainTabView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var registrations: [DeviceRegistration]
    // The redesigned capture overview is the staff landing page; task details
    // remain one tap away without making the app open on the legacy list UI.
    @State private var selectedTab: AppTab = .tasks
    @State private var captureRootID = UUID()
    @State private var targetExecutionItemID: String?
    @AppStorage(CodeCamAppModeStore.key) private var appMode = CodeCamAppMode.staff.rawValue

    private var registration: DeviceRegistration? {
        registrations.first { $0.terminalID == InstallationIDStore.value }
    }

    private var captureTabSelection: Binding<AppTab> {
        Binding(
            get: { selectedTab },
            set: { tab in
                if tab == .capture {
                    captureRootID = UUID()
                }
                selectedTab = tab
            }
        )
    }

    var body: some View {
        if appMode == CodeCamAppMode.customer.rawValue {
            CustomerModeRootView()
                .task { _ = AccountAuthService.session(in: modelContext) }
        } else {
        staffTabs
        }
    }

    private var staffTabs: some View {
        TabView(selection: captureTabSelection) {
            TodayTasksView { itemID in
                targetExecutionItemID = itemID
                selectedTab = .capture
            }
                .tabItem { Label("任务", systemImage: "checklist") }
                .tag(AppTab.tasks)

            ContentView(
                targetExecutionItemID: $targetExecutionItemID,
                onOpenRecords: { selectedTab = .records }
            )
                .id(captureRootID)
                .tabItem { Label("扫码", systemImage: "barcode.viewfinder") }
                .tag(AppTab.capture)

            RecordsView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }
                .tag(AppTab.records)

            MineView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(AppTab.mine)
        }
        .tint(CodeCamTheme.blue)
        .toolbarBackground(CodeCamTheme.canvas, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .task {
            TaskBootstrapper.seedIfNeeded(in: modelContext)
            _ = DeviceRegistrationService.registration(in: modelContext)
            _ = AccountAuthService.session(in: modelContext)
            SyncScheduler.schedule(in: modelContext, delayNanoseconds: 2_000_000_000)
        }
        .task(id: registration?.stateRaw) {
            await heartbeatWhileActive()
        }
    }

    private func heartbeatWhileActive() async {
        guard registration != nil else { return }
        while !Task.isCancelled {
            let current = DeviceRegistrationService.registration(in: modelContext)
            guard current.state == .registered || current.state == .online || current.state == .offline else { return }
            do {
                try await DeviceRegistrationService.sendHeartbeat(current, in: modelContext)
            } catch {
                DeviceRegistrationService.markOffline(error, for: current, in: modelContext)
            }
            try? await Task.sleep(for: .seconds(60))
        }
    }
}
