import Foundation

/// The app group shared by the Kibo app and the KiboShare extension. The
/// container holds exactly two things: the pending-attachment spool (the
/// extension writes, the app uploads) and the destination cache (the app
/// writes, the extension reads).
///
/// `containerURL` returns nil when the App Group entitlement is missing or
/// cannot be provisioned (free-provisioning contingency). Every caller must
/// degrade gracefully: the app falls back to its private Application Support
/// spool, and the extension reports that sharing is unavailable.
enum KiboAppGroup {
    static let identifier = "group.com.anotherjesse.kibo"

    static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}

extension PendingAttachmentSpool {
    /// Root selection happens here, once, at startup — never in scattered
    /// conditionals. With the app-group container available (the normal case)
    /// the spool lives in the shared container and `migrationRootURL` points
    /// at the Phase C Application Support root, which the always-sweep drains
    /// idempotently. Without the container the spool stays in Application
    /// Support exactly as in Phase C and nothing else changes.
    static func resolvedRoots(
        appGroupContainerURL: URL?,
        applicationSupportURL: URL
    ) -> (rootURL: URL, migrationRootURL: URL?) {
        let privateRoot = applicationSupportURL
            .appendingPathComponent(directoryName, isDirectory: true)
        guard let appGroupContainerURL else { return (privateRoot, nil) }
        return (
            appGroupContainerURL.appendingPathComponent(directoryName, isDirectory: true),
            privateRoot
        )
    }

    /// The main app's spool: full owner — enqueue, upload, sweep, GC.
    static func mainApp(fileManager: FileManager = .default) -> PendingAttachmentSpool {
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0]
        let roots = resolvedRoots(
            appGroupContainerURL: KiboAppGroup.containerURL(fileManager: fileManager),
            applicationSupportURL: applicationSupport
        )
        return PendingAttachmentSpool(
            rootURL: roots.rootURL,
            migrationRootURL: roots.migrationRootURL,
            fileManager: fileManager
        )
    }

    /// The share extension's spool: an enqueue-only writer against the shared
    /// container. The extension must NEVER sweep or GC — `tmp/` collection is
    /// owned solely by the main app, so a writer mid-stage can never lose its
    /// package. Nil when the app group container is unavailable.
    static func appGroupWriter(fileManager: FileManager = .default) -> PendingAttachmentSpool? {
        KiboAppGroup.containerURL(fileManager: fileManager).map {
            PendingAttachmentSpool(
                rootURL: $0.appendingPathComponent(directoryName, isDirectory: true),
                fileManager: fileManager
            )
        }
    }
}
