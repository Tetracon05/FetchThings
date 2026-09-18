import DownloadKit
import Foundation
import Testing
@testable import Downloader

@Suite("File categories")
struct FileCategoryTests {
    @Test(arguments: [
        ("movie.mp4", FileCategory.video), ("clip.MOV", .video), ("film.mkv", .video), ("stream.webm", .video), ("old.avi", .video),
        ("song.mp3", .audio), ("track.flac", .audio), ("voice.opus", .audio), ("mix.ogg", .audio), ("take.wav", .audio),
        ("photo.jpg", .images), ("shot.PNG", .images), ("scan.heic", .images), ("pic.webp", .images), ("new.avif", .images),
        ("report.pdf", .documents), ("notes.txt", .documents), ("sheet.xlsx", .documents), ("book.epub", .documents),
        ("backup.zip", .archives), ("src.tar.gz", .archives), ("data.7z", .archives),
        ("Setup.dmg", .applications), ("tool.pkg", .applications), ("ubuntu.iso", .applications), ("installer.exe", .applications),
        ("mystery.zzzunknown", .other), ("noextension", .other), (".hidden", .other), ("firmware.bin", .other), ("blob.dat", .other),
    ] as [(String, FileCategory)])
    func classifiesByExtension(name: String, expected: FileCategory) {
        #expect(FileCategory.classify(filename: name) == expected)
    }

    @Test func nilAndEmptyAreOther() {
        #expect(FileCategory.classify(filename: nil) == .other)
        #expect(FileCategory.classify(filename: "") == .other)
    }
}

@Suite("Sidebar filters")
struct SidebarItemTests {
    @Test func activeMeansNotFinished() {
        for state in DownloadState.allCases {
            let expected = state != .completed && state != .failed
            #expect(SidebarItem.active.includes(snapshot("a.zip", state: state)) == expected, "\(state)")
        }
    }

    @Test func completedAndFailedAreExact() {
        #expect(SidebarItem.completed.includes(snapshot(state: .completed)))
        #expect(!SidebarItem.completed.includes(snapshot(state: .failed)))
        #expect(SidebarItem.failed.includes(snapshot(state: .failed)))
        #expect(!SidebarItem.failed.includes(snapshot(state: .paused)))
        for state in DownloadState.allCases { #expect(SidebarItem.all.includes(snapshot(state: state))) }
    }

    @Test func categoriesUseTheFileName() {
        #expect(SidebarItem.category(.video).includes(snapshot("film.mkv")))
        #expect(!SidebarItem.category(.video).includes(snapshot("song.mp3")))
        // No file name yet: fall back to the last part of the URL.
        #expect(SidebarItem.category(.archives).includes(snapshot(nil, url: "https://example.com/dl/pack.zip")))
    }

    @Test func everyItemHasATitleAndASymbol() {
        for item in SidebarItem.downloadItems + SidebarItem.categoryItems {
            #expect(!item.title.isEmpty && !item.symbol.isEmpty)
        }
        #expect(SidebarItem.categoryItems.count == FileCategory.allCases.count)
    }
}

@Suite("Display formatting")
struct FormattingTests {
    @Test func displayNamePrefersTheFileNameThenTheURL() {
        #expect(snapshot("real.zip", url: "https://e.com/x").displayName == "real.zip")
        #expect(snapshot(nil, url: "https://e.com/path/thing.iso").displayName == "thing.iso")
        #expect(snapshot(nil, url: "https://e.com/").displayName == "e.com")
        #expect(snapshot("", url: "https://e.com/a.bin").displayName == "a.bin")
    }

    @Test func speedAndSizeShowADashWhenUnknown() {
        #expect(Formatters.speed(0) == "—")
        #expect(Formatters.speed(0.5) == "—")
        #expect(Formatters.size(nil) == "—")
        #expect(Formatters.speed(2_500_000).hasSuffix("/s"))
        #expect(Formatters.size(1_500_000).contains("MB"))
    }

    @Test func etaIsCompact() {
        #expect(Formatters.eta(nil) == "—")
        #expect(Formatters.eta(.infinity) == "—")
        #expect(Formatters.eta(-3) == "—")
        #expect(Formatters.eta(0.2) == "< 1 sec")
        #expect(Formatters.eta(45).contains("45"))
        // Two units at most: 1 h 5 min, not 1 h 5 min 12 s.
        let long = Formatters.eta(3912)
        #expect(long.contains("1") && long.contains("5") && !long.contains("12"), "\(long)")
    }

    @Test func percentHandlesUnknown() {
        #expect(Formatters.percent(nil) == "—")
        // Percent formatting follows the user's locale (Turkish writes "%46"), so check the parts.
        let partial = Formatters.percent(0.456)
        #expect(partial.contains("46") && partial.contains("%"), "\(partial)")
        let full = Formatters.percent(1)
        #expect(full.contains("100") && full.contains("%"), "\(full)")
    }

    @Test func statusAndActionFlags() {
        #expect(snapshot(state: .downloading).isPausable && !snapshot(state: .downloading).isResumable)
        #expect(snapshot(state: .queued).isPausable)
        #expect(snapshot(state: .paused).isResumable && !snapshot(state: .paused).isPausable)
        #expect(snapshot(state: .failed).isResumable)
        #expect(!snapshot(state: .completed).isPausable && !snapshot(state: .completed).isResumable)
        #expect(Set(DownloadState.allCases.map { snapshot(state: $0).statusText }).count == DownloadState.allCases.count)
    }

    @Test func sortKeysPutUnknownsPredictably() {
        #expect(snapshot(total: nil).sizeSortKey < snapshot(total: 0).sizeSortKey)
        #expect(snapshot(total: 1000, received: 100).progressSortKey == 0.1)
        #expect(snapshot(state: .downloading, total: nil).progressSortKey == -1)
    }
}

@MainActor
@Suite("Settings")
struct SettingsTests {
    private func defaults() -> UserDefaults {
        let suite = "DownloaderTests.settings.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsAreSensible() {
        let s = AppSettings(defaults: defaults())
        #expect(s.segmentCount == 8)
        #expect(s.maxConcurrentDownloads == 3)
        #expect(s.speedLimitKBps == 0 && s.globalSpeedLimit == nil)
        #expect(!s.detectClipboard, "clipboard detection is opt-in")
        #expect(s.downloadFolder.lastPathComponent == "Downloads")
    }

    @Test func valuesPersistAcrossInstances() {
        let d = defaults()
        let first = AppSettings(defaults: d)
        first.segmentCount = 16
        first.maxConcurrentDownloads = 5
        first.speedLimitKBps = 250
        first.detectClipboard = true
        first.defaultUserAgent = "Custom/1"
        first.downloadFolder = URL(filePath: "/tmp/elsewhere", directoryHint: .isDirectory)

        let second = AppSettings(defaults: d)
        #expect(second.segmentCount == 16 && second.maxConcurrentDownloads == 5)
        #expect(second.speedLimitKBps == 250 && second.globalSpeedLimit == 250_000)
        #expect(second.detectClipboard && second.defaultUserAgent == "Custom/1")
        #expect(second.downloadFolder.path == "/tmp/elsewhere")
    }

    @Test func outOfRangeStoredValuesAreClamped() {
        let d = defaults()
        d.set(500, forKey: "segmentCount")
        d.set(-4, forKey: "maxConcurrentDownloads")
        d.set(-100, forKey: "speedLimitKBps")
        let s = AppSettings(defaults: d)
        #expect(s.segmentCount == AppSettings.segmentRange.upperBound)
        #expect(s.maxConcurrentDownloads == AppSettings.concurrencyRange.lowerBound)
        #expect(s.speedLimitKBps == 0)
    }
}
