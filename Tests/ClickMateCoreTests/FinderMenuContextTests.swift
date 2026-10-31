import AppKit
import Foundation
import XCTest

final class FinderMenuContextTests: XCTestCase {
    private let directory = URL(fileURLWithPath: "/tmp/ClickMateContext", isDirectory: true)

    func testContainerIgnoresStaleFinderSelection() {
        let file = directory.appendingPathComponent("selected.txt")
        let context = FinderMenuContext(kind: .container, selectedURLs: [file], targetedURL: directory)

        XCTAssertTrue(context.actionURLs.isEmpty)
        XCTAssertEqual(context.destinationDirectory, directory)
        for command in [MenuCommand.moveToNewFolder, .duplicateTimestamp, .createAlias, .compress, .md5, .copyFilename] {
            XCTAssertTrue(context.urls(for: command).isEmpty, command.rawValue)
        }
        XCTAssertEqual(context.urls(for: .copyPOSIXPath), [directory])
        XCTAssertEqual(context.urls(for: .openVSCode), [directory])
    }

    func testItemMenuNeverUsesCurrentDirectoryAsSelection() {
        let context = FinderMenuContext(kind: .items, selectedURLs: [], targetedURL: directory)
        XCTAssertTrue(context.actionURLs.isEmpty)
        XCTAssertTrue(context.urls(for: .compress).isEmpty)
    }

    func testSelectedFileAndFolderPreserveActionAndDestination() {
        let file = directory.appendingPathComponent("selected.txt")
        for kind in [FinderMenuContext.Kind.items, .sidebar, .toolbar] {
            let context = FinderMenuContext(kind: kind, selectedURLs: [file], targetedURL: directory)
            XCTAssertEqual(context.actionURLs, [file])
            XCTAssertEqual(context.urls(for: .compress), [file])
            XCTAssertEqual(context.destinationDirectory, directory)
        }
        let folder = directory.appendingPathComponent("Folder", isDirectory: true)
        let context = FinderMenuContext(kind: .items, selectedURLs: [folder], targetedURL: directory)
        XCTAssertEqual(context.destinationDirectory, folder)
        XCTAssertEqual(context.actionURLs, [folder])
    }

    func testExecutionRejectsChangedSelectionInsteadOfUsingNewFiles() {
        let original = directory.appendingPathComponent("original.txt")
        let changed = directory.appendingPathComponent("other.txt")
        let context = FinderMenuContext(kind: .items, selectedURLs: [original], targetedURL: directory)
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [changed], currentTargetedURL: directory))
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [], currentTargetedURL: directory))
    }

    func testExecutionDoesNotProbeSandboxAccessAndAcceptsReorderedSelection() {
        let first = directory.appendingPathComponent("first.txt")
        let second = directory.appendingPathComponent("second.txt")
        let context = FinderMenuContext(kind: .items, selectedURLs: [first, second], targetedURL: directory)
        XCTAssertTrue(context.isValidForExecution(currentSelectedURLs: [first, second], currentTargetedURL: directory))
        XCTAssertTrue(context.isValidForExecution(currentSelectedURLs: [second, first], currentTargetedURL: directory))
    }

    func testContainerValidatesOriginalDirectoryWithoutAdoptingSelection() {
        let context = FinderMenuContext(kind: .container, selectedURLs: [], targetedURL: directory)
        XCTAssertTrue(context.isValidForExecution(currentSelectedURLs: [directory.appendingPathComponent("new.txt")], currentTargetedURL: directory))
        XCTAssertFalse(context.isValidForExecution(currentSelectedURLs: [], currentTargetedURL: directory.deletingLastPathComponent()))
        XCTAssertTrue(context.isValidForExecution(currentSelectedURLs: [], currentTargetedURL: directory))
    }
}

final class FinderFolderSyncTests: XCTestCase {
    func testPublishesOnlyExplicitSelectedPathsWithoutSharingBookmarkData() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let selected = externalFolder("Downloads")
            let unselected = externalFolder("Unselected")
            let emptyBookmark = externalFolder("EmptyBookmark")
            let secret = Data("private-bookmark-payload-\(UUID().uuidString)".utf8)
            var preferences = ClickMatePreferences.defaults
            preferences.monitoredFolderPaths = [selected, unselected, emptyBookmark, "/System"]
            preferences.monitoredFolderBookmarks = [selected: secret, emptyBookmark: Data(), "/System": secret]

            XCTAssertTrue(FinderFolderSyncStore.publish(preferences: preferences, pasteboardName: pasteboardName))
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [selected])

            let data = try XCTUnwrap(NSPasteboard(name: pasteboardName).data(forType: FinderFolderSyncStore.pasteboardType))
            let json = try XCTUnwrap(String(data: data, encoding: .utf8))
            XCTAssertFalse(json.contains(secret.base64EncodedString()))
            XCTAssertFalse(json.contains("monitoredFolderBookmarks"))
            XCTAssertFalse(json.contains("private-bookmark-payload"))
        }
    }

    func testEmptySnapshotRemovesFoldersAndPersistsRemovalAcrossRestart() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let selected = externalFolder("Downloads")
            var preferences = ClickMatePreferences.defaults
            preferences.monitoredFolderPaths = [selected]
            preferences.monitoredFolderBookmarks = [selected: Data([1])]
            XCTAssertTrue(FinderFolderSyncStore.publish(preferences: preferences, pasteboardName: pasteboardName))
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [selected])

            preferences.monitoredFolderPaths = []
            preferences.monitoredFolderBookmarks = [:]
            XCTAssertTrue(FinderFolderSyncStore.publish(preferences: preferences, pasteboardName: pasteboardName))
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [])

            NSPasteboard(name: pasteboardName).clearContents()
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [])
        }
    }

    func testCurrentPublicationReplacesFutureDatedCache() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let previous = externalFolder("Old")
            let selected = externalFolder("Downloads")
            let cached = FinderFolderSyncSnapshot(paths: [previous], updatedAt: Date(timeIntervalSinceNow: 86_400))
            try JSONEncoder().encode(cached).write(to: cacheURL)

            var preferences = ClickMatePreferences.defaults
            preferences.monitoredFolderPaths = [selected]
            preferences.monitoredFolderBookmarks = [selected: Data([1])]
            XCTAssertTrue(FinderFolderSyncStore.publish(preferences: preferences, updatedAt: .now, pasteboardName: pasteboardName))
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [selected])

            NSPasteboard(name: pasteboardName).clearContents()
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [selected])
        }
    }

    func testInvalidPublicationsDoNotOverwriteLastValidCache() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let selected = externalFolder("Downloads")
            let validData = try JSONEncoder().encode(FinderFolderSyncSnapshot(paths: [selected]))
            try validData.write(to: cacheURL)
            var unknownVersion = try XCTUnwrap(JSONSerialization.jsonObject(with: validData) as? [String: Any])
            unknownVersion["version"] = Int.max
            let relativeData = try JSONEncoder().encode(FinderFolderSyncSnapshot(paths: ["relative/Downloads"]))
            let oversizedData = try JSONEncoder().encode(FinderFolderSyncSnapshot(paths: ["/Volumes/Disk/" + String(repeating: "a", count: 1_048_576)]))

            for data in [Data("broken-json".utf8), try JSONSerialization.data(withJSONObject: unknownVersion), relativeData, oversizedData] {
                let pasteboard = NSPasteboard(name: pasteboardName)
                pasteboard.clearContents()
                XCTAssertTrue(pasteboard.setData(data, forType: FinderFolderSyncStore.pasteboardType))
                XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [selected])
                XCTAssertEqual(try Data(contentsOf: cacheURL), validData)
            }
        }
    }

    func testUnavailableExternalSubfolderCanBeMonitoredWithoutFilesystemProbe() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let selected = externalFolder("UserData/Downloads")
            XCTAssertFalse(FileManager.default.fileExists(atPath: selected))
            XCTAssertTrue(MonitoredFolderPolicy.isAllowedExplicitMonitoringPath(selected))
            var preferences = ClickMatePreferences.defaults
            preferences.monitoredFolderPaths = [selected]
            preferences.monitoredFolderBookmarks = [selected: Data([1])]

            XCTAssertTrue(FinderFolderSyncStore.publish(preferences: preferences, pasteboardName: pasteboardName))
            XCTAssertEqual(FinderFolderSyncStore.synchronizedPaths(cacheFileURL: cacheURL, pasteboardName: pasteboardName), [selected])
        }
    }

    func testExplicitMonitoringRejectsDangerousRootsAndAliases() throws {
        let home = MonitoredFolderPolicy.userHomeDirectory()
        for path in ["", "Downloads", "/", "/System", "/System/Library", "/Library", "/Volumes", "/Volumes/External", home.path, home.appendingPathComponent("Library/Containers").path] {
            XCTAssertFalse(MonitoredFolderPolicy.isAllowedExplicitMonitoringPath(path), path)
        }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, target) in [URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/Library"), home].enumerated() {
            let alias = directory.appendingPathComponent("UnsafeAlias-\(index)")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
            XCTAssertFalse(MonitoredFolderPolicy.isAllowedExplicitMonitoringPath(alias.path))
        }
    }

    func testRedirectedDownloadsIsSelectableButNeverAutomaticallyMonitored() throws {
        let home = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: home) }
        let target = URL(fileURLWithPath: externalFolder("UserData/Downloads"), isDirectory: true)
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: downloads, withDestinationURL: target)

        let candidates = MonitoredFolderPolicy.redirectedDefaultDirectoryURLs(homeDirectory: home)
        XCTAssertTrue(candidates.contains { MonitoredFolderPolicy.canonicalPath(for: $0) == target.path })
        let automatic = MonitoredFolderPolicy.defaultDirectoryURLsForFinderSyncBootstrap(homeDirectory: home)
        XCTAssertFalse(automatic.contains(downloads))
        XCTAssertFalse(automatic.contains(target))
        XCTAssertTrue(MonitoredFolderPolicy.isAllowedExplicitMonitoringPath(target.path))
    }

    private func withIsolatedChannel(_ body: (NSPasteboard.Name, URL) throws -> Void) throws {
        let directory = try makeTemporaryDirectory()
        let pasteboardName = NSPasteboard.Name("com.zxacn.clickmate.tests.finder-folders.\(UUID().uuidString)")
        defer {
            NSPasteboard(name: pasteboardName).clearContents()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(pasteboardName, directory.appendingPathComponent("FinderFolderSync.json"))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClickMateFolderSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func externalFolder(_ relativePath: String) -> String {
        "/Volumes/ClickMateFolderSync-\(UUID().uuidString)/\(relativePath)"
    }
}

final class FinderMenuPreferencesSyncTests: XCTestCase {
    func testSnapshotEncodingRoundTripsMenuOnlyConfiguration() throws {
        var preferences = ClickMatePreferences.defaults
        preferences.enabledCommands = [.newFile, .openITerm, .openVSCode]
        preferences.removedMenuCommands = Set(MenuCommand.allCases).subtracting(preferences.enabledCommands)
        preferences.foldedMenuGroups = [.openHere]
        preferences.topLevelShortcutCommands = [.openVSCode]
        preferences.topLevelShortcutTemplateIDs = ["md"]
        preferences.detectedApplicationOrder = [
            "com.microsoft.VSCode", "com.googlecode.iterm2", "com.apple.Terminal",
            "com.todesktop.230313mzl4w4u92", "com.barebones.bbedit", "com.sublimetext.4"
        ]
        preferences.removedDetectedApplicationBundleIDs = ["com.barebones.bbedit"]
        preferences.pinnedApplicationPaths = ["/Applications/Example.app"]
        preferences.language = .simplifiedChinese
        preferences.finderToolsEnabled = true
        preferences.monitoredFolderBookmarks = ["/private": Data("secret-bookmark".utf8)]

        let snapshot = FinderMenuPreferencesSnapshot(
            preferences: preferences,
            updatedAt: Date(timeIntervalSinceReferenceDate: 1234)
        )
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try XCTUnwrap(FinderMenuPreferencesSyncStore.decodeValidatedSnapshot(from: data))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        XCTAssertEqual(decoded, snapshot)
        XCTAssertFalse(json.contains("monitoredFolderBookmarks"))
        XCTAssertFalse(json.contains("secret-bookmark"))
        XCTAssertFalse(json.contains("quickFeatureSettings"))
    }

    func testUnsupportedSnapshotVersionIsRejected() throws {
        var snapshot = FinderMenuPreferencesSnapshot(preferences: .defaults)
        snapshot.version = FinderMenuPreferencesSnapshot.currentVersion + 1

        XCTAssertNil(FinderMenuPreferencesSyncStore.decodeValidatedSnapshot(
            from: try JSONEncoder().encode(snapshot)
        ))
    }

    func testMalformedOversizedAndInvalidPayloadsAreRejected() throws {
        var duplicateOrder = FinderMenuPreferencesSnapshot(preferences: .defaults)
        duplicateOrder.menuPreferences.menuCommandOrder = [.newFile, .newFile]

        XCTAssertNil(FinderMenuPreferencesSyncStore.decodeValidatedSnapshot(from: Data("not-json".utf8)))
        XCTAssertNil(FinderMenuPreferencesSyncStore.decodeValidatedSnapshot(
            from: Data(count: FinderMenuPreferencesSyncStore.maximumPayloadSize + 1)
        ))
        XCTAssertNil(FinderMenuPreferencesSyncStore.decodeValidatedSnapshot(
            from: try JSONEncoder().encode(duplicateOrder)
        ))
    }

    func testLiveSnapshotWinsOverFutureDatedCacheAndReplacesIt() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            var cachedPreferences = ClickMatePreferences.defaults
            cachedPreferences.enabledCommands = [.sha256]
            let cached = FinderMenuPreferencesSnapshot(
                preferences: cachedPreferences,
                updatedAt: Date(timeIntervalSinceNow: 86_400)
            )
            try JSONEncoder().encode(cached).write(to: cacheURL)

            var livePreferences = ClickMatePreferences.defaults
            livePreferences.enabledCommands = [.newFile, .openITerm, .openVSCode]
            XCTAssertTrue(FinderMenuPreferencesSyncStore.publish(
                preferences: livePreferences,
                updatedAt: .now,
                pasteboardName: pasteboardName,
                sharedContainerURL: nil
            ))

            let synchronized = try XCTUnwrap(FinderMenuPreferencesSyncStore.synchronizedSnapshot(
                cacheFileURL: cacheURL,
                pasteboardName: pasteboardName,
                sharedContainerURL: nil
            ))
            XCTAssertEqual(synchronized.menuPreferences.enabledCommands, livePreferences.enabledCommands)
            XCTAssertEqual(
                try JSONDecoder().decode(
                    FinderMenuPreferencesSnapshot.self,
                    from: Data(contentsOf: cacheURL)
                ),
                synchronized
            )
        }
    }

    func testCacheRestoresLastValidSnapshotWhenLiveStateIsMissing() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            var preferences = ClickMatePreferences.defaults
            preferences.enabledCommands = [.newFile, .openVSCode]
            let cached = FinderMenuPreferencesSnapshot(preferences: preferences)
            try JSONEncoder().encode(cached).write(to: cacheURL)
            NSPasteboard(name: pasteboardName).clearContents()

            XCTAssertEqual(
                FinderMenuPreferencesSyncStore.synchronizedSnapshot(
                    cacheFileURL: cacheURL,
                    pasteboardName: pasteboardName,
                    sharedContainerURL: nil
                ),
                cached
            )
        }
    }

    func testInvalidLiveStateKeepsLastValidCache() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let cached = FinderMenuPreferencesSnapshot(preferences: .defaults)
            let cachedData = try JSONEncoder().encode(cached)
            try cachedData.write(to: cacheURL)
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            XCTAssertTrue(pasteboard.setData(Data("broken-live-state".utf8), forType: FinderMenuPreferencesSyncStore.pasteboardType))

            XCTAssertEqual(
                FinderMenuPreferencesSyncStore.synchronizedSnapshot(
                    cacheFileURL: cacheURL,
                    pasteboardName: pasteboardName,
                    sharedContainerURL: nil
                ),
                cached
            )
            XCTAssertEqual(try Data(contentsOf: cacheURL), cachedData)
        }
    }

    func testMainAppPublicationIsAppliedByFinderFallbackConsumer() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            var preferences = ClickMatePreferences.defaults
            preferences.enabledCommands = [.newFile, .openITerm, .openVSCode]
            preferences.removedMenuCommands = Set(MenuCommand.allCases).subtracting(preferences.enabledCommands)
            XCTAssertTrue(FinderMenuPreferencesSyncStore.publish(
                preferences: preferences,
                pasteboardName: pasteboardName,
                sharedContainerURL: nil
            ))

            let applied = try XCTUnwrap(FinderMenuPreferencesSyncStore.synchronizedPreferences(
                applyingTo: .defaults,
                cacheFileURL: cacheURL,
                pasteboardName: pasteboardName,
                sharedContainerURL: nil
            ))
            XCTAssertEqual(applied.enabledCommands, preferences.enabledCommands)
            XCTAssertEqual(applied.removedMenuCommands, preferences.removedMenuCommands)
            XCTAssertFalse(applied.orderedVisibleMenuGroups.contains(.hash))
            XCTAssertFalse(applied.orderedVisibleMenuGroups.contains(.fileUtilities))
            XCTAssertFalse(applied.orderedVisibleMenuGroups.contains(.advanced))
        }
    }

    func testSignedAppGroupPathDoesNotPublishOrConsumeFallback() throws {
        try withIsolatedChannel { pasteboardName, cacheURL in
            let sharedContainerURL = cacheURL.deletingLastPathComponent()
            XCTAssertFalse(FinderMenuPreferencesSyncStore.publish(
                preferences: .defaults,
                pasteboardName: pasteboardName,
                sharedContainerURL: sharedContainerURL
            ))
            XCTAssertNil(NSPasteboard(name: pasteboardName).data(forType: FinderMenuPreferencesSyncStore.pasteboardType))
            XCTAssertNil(FinderMenuPreferencesSyncStore.synchronizedSnapshot(
                cacheFileURL: cacheURL,
                pasteboardName: pasteboardName,
                sharedContainerURL: sharedContainerURL
            ))
        }
    }

    func testApplyingMenuSnapshotPreservesFolderAuthorizationAndFinderCutState() {
        var current = ClickMatePreferences.defaults
        let bookmark = Data("bookmark".utf8)
        current.monitoredFolderPaths = ["/Volumes/Example/Folder"]
        current.monitoredFolderBookmarks = ["/Volumes/Example/Folder": bookmark]
        current.quickFeatureSettings = [
            QuickFeatureSettings(id: .finderCut, isEnabled: true, shortcut: .commandX),
            QuickFeatureSettings(id: .screenshot, isEnabled: false, shortcut: .screenshotDefault)
        ]

        var source = ClickMatePreferences.defaults
        source.enabledCommands = [.newFile]
        source.pinnedApplicationPaths = ["/Applications/Example.app"]
        let applied = FinderMenuPreferences(preferences: source).applying(to: current)

        XCTAssertEqual(applied.monitoredFolderPaths, current.monitoredFolderPaths)
        XCTAssertEqual(applied.monitoredFolderBookmarks, current.monitoredFolderBookmarks)
        XCTAssertEqual(applied.quickFeatureSettings, current.quickFeatureSettings)
        XCTAssertEqual(applied.pinnedApplicationPaths, source.pinnedApplicationPaths)
        XCTAssertTrue(applied.quickFeatureSettings(for: .finderCut).isEnabled)
    }

    func testRemovingAllHashCommandsRemovesHashGroup() {
        assertGroupDisappears(.hash)
    }

    func testRemovingAllFileUtilityCommandsRemovesFileUtilityGroup() {
        assertGroupDisappears(.fileUtilities)
    }

    func testRemovingAllAdvancedCommandsRemovesAdvancedGroup() {
        assertGroupDisappears(.advanced)
    }

    private func assertGroupDisappears(_ group: MenuCommandGroup, file: StaticString = #filePath, line: UInt = #line) {
        var preferences = ClickMatePreferences.defaults
        group.commands.forEach { preferences.removeMenuCommand($0) }

        XCTAssertFalse(preferences.orderedVisibleMenuGroups.contains(group), file: file, line: line)
    }

    private func withIsolatedChannel(_ body: (NSPasteboard.Name, URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClickMateMenuSync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let pasteboardName = NSPasteboard.Name("com.zxacn.clickmate.tests.menu-sync.\(UUID().uuidString)")
        defer {
            NSPasteboard(name: pasteboardName).clearContents()
            try? FileManager.default.removeItem(at: directory)
        }
        try body(pasteboardName, directory.appendingPathComponent("FinderMenuPreferencesSync.json"))
    }
}
