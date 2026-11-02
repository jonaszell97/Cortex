import AppKit
@testable import Cortex
import CortexCore

/// The made-up history, snippets, links, notes and commands the README
/// screenshots show.
@MainActor
enum DemoData {
    static func configure(_ defaults: UserDefaults, scratch: URL) {
        // Never record the real clipboard into the demo history.
        defaults.set(true, forKey: "isRecordingPaused")
        for id in ["ai", "sync", "scrolling", "text-recognition"] {
            defaults.set(true, forKey: ModuleHost.enabledKey(ModuleID(rawValue: id)))
        }
        defaults.set(scratch.appending(path: "knowledge").path(percentEncoded: false), forKey: "knowledge.folder")
        defaults.set(false, forKey: "knowledge.keepHistory")
        defaults.set(false, forKey: "knowledge.linkSkills")
    }

    static func seed(database: AppDatabase, config: URL, knowledge: URL) throws {
        try seedClips(ClipStore(database: database))
        try seedSnippets(SnippetStore(database: database))
        try seedReadingList(ReadingListStore(database: database))
        try writeFiles(actions, under: config.appending(path: "actions"))
        try writeFiles(["projects.toml": projects], under: config)
        try writeFiles(notes, under: knowledge)
    }

    // MARK: - Clipboard

    private struct Clip {
        var text: String?
        var app: (id: String, name: String)
        var minutesAgo: Double
        var image: Data?
        var sensitive = false
        var pinned = false
    }

    private static let terminal = ("com.apple.Terminal", "Terminal")
    private static let safari = ("com.apple.Safari", "Safari")
    private static let mail = ("com.apple.mail", "Mail")
    private static let notesApp = ("com.apple.Notes", "Notes")
    private static let figma = ("com.figma.Desktop", "Figma")
    private static let vscode = ("com.microsoft.VSCode", "Visual Studio Code")
    private static let messages = ("com.apple.MobileSMS", "Messages")
    private static let screenshot = ("com.apple.screencaptureui", "Screenshot")
    private static let passwords = ("com.apple.Passwords", "Passwords")

    private static func seedClips(_ store: ClipStore) throws {
        let clips: [Clip] = [
            Clip(text: "docker compose up -d --build && docker compose logs -f", app: terminal, minutesAgo: 1),
            Clip(text: """
                {
                  "name": "rubber-duck",
                  "role": "Senior Debugging Consultant",
                  "salary": "bread",
                  "bugs_fixed": 1337,
                  "said_a_word": false
                }
                """, app: vscode, minutesAgo: 4),
            Clip(text: nil, app: screenshot, minutesAgo: 9, image: dialogScreenshot()),
            Clip(text: "#FF5F87", app: figma, minutesAgo: 14),
            Clip(text: "Sorry for the late reply! My cat walked across the keyboard and archived your email. Twice.", app: mail, minutesAgo: 22),
            Clip(text: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", app: safari, minutesAgo: 37),
            Clip(text: "correct-horse-battery-staple", app: passwords, minutesAgo: 41, sensitive: true),
            Clip(text: "git commit -m \"fix: works on my machine\"", app: terminal, minutesAgo: 58),
            Clip(text: "742 Evergreen Terrace, Springfield", app: messages, minutesAgo: 95),
            Clip(text: "Action items: 1. Agree that this meeting could have been an email. 2. Schedule a follow-up meeting.", app: notesApp, minutesAgo: 180),
            Clip(text: "#7C5CFF", app: figma, minutesAgo: 240),
            Clip(text: "SELECT * FROM coffee WHERE cups_today > 4; -- send help", app: vscode, minutesAgo: 300),
        ]
        // Oldest first, so the newest ends up on top.
        for clip in clips.reversed() {
            var representations: [LoadedRepresentation] = []
            if let image = clip.image { representations.append(LoadedRepresentation(type: ClipType.png, data: image)) }
            if let text = clip.text { representations.append(LoadedRepresentation(type: ClipType.plainText, data: Data(text.utf8))) }
            try store.record(
                ClipSnapshot(
                    representations: representations, plainText: clip.text, isSensitive: clip.sensitive,
                    sourceBundleID: clip.app.id, sourceAppName: clip.app.name,
                    copiedAt: .now.addingTimeInterval(-clip.minutesAgo * 60)),
                indexSensitive: false, pin: clip.pinned)
        }
    }

    /// A screenshot of a dialog everybody has seen at least once, for text
    /// recognition to read.
    static func dialogScreenshot() -> Data {
        let size = NSSize(width: 520, height: 210)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor(white: 0.97, alpha: 1).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 18, yRadius: 18).fill()
            NSImage(named: NSImage.cautionName)?.draw(in: NSRect(x: 30, y: 30, width: 64, height: 64))
            let title: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 17), .foregroundColor: NSColor.black]
            let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray]
            ("Task failed successfully." as NSString).draw(at: NSPoint(x: 116, y: 34), withAttributes: title)
            ("The operation completed with 0 errors and\n1 existential crisis. Retry anyway?" as NSString)
                .draw(in: NSRect(x: 116, y: 62, width: 380, height: 50), withAttributes: body)
            for (index, label) in ["Panic", "OK"].enumerated() {
                let button = NSRect(x: 300 + CGFloat(index) * 106, y: 150, width: 94, height: 32)
                (index == 1 ? NSColor.systemBlue : NSColor(white: 0.88, alpha: 1)).setFill()
                NSBezierPath(roundedRect: button, xRadius: 8, yRadius: 8).fill()
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                    .foregroundColor: index == 1 ? NSColor.white : NSColor.black,
                ]
                let text = label as NSString
                let textSize = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: button.midX - textSize.width / 2, y: button.midY - textSize.height / 2), withAttributes: attributes)
            }
            return true
        }
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }

    // MARK: - Snippets

    private static func seedSnippets(_ store: SnippetStore) throws {
        let snippets = [
            Snippet(name: "Shrug", keyword: ";shrug", body: "¯\\_(ツ)_/¯", tags: ["reactions"], usageCount: 412),
            Snippet(
                name: "Daily standup", keyword: ";standup",
                body: """
                    **Standup, {day} {date}**
                    Yesterday: {yesterday}
                    Today: {today}
                    Blockers: {argument name="blockers" default="the coffee machine is broken again"}
                    """,
                tags: ["work"], usageCount: 88),
            Snippet(name: "LGTM", keyword: ";lgtm", body: "Looks good to me! 🚀\n\n(I read most of it.)", tags: ["work", "reviews"], usageCount: 230),
            Snippet(
                name: "Out of office", keyword: ";ooo",
                body: """
                    Hi {name},

                    I'm out of office until {date format="EEEE, MMMM d" offset="+7d"}, with limited access to email and unlimited access to the beach. 🏖️

                    For anything urgent, please turn it off and on again.
                    """,
                tags: ["email"], usageCount: 6),
            Snippet(
                name: "Bug report", keyword: ";bug",
                body: "**Steps to reproduce**\n1. {cursor}\n\n**Expected**\n\n**Actual**\n\n**Have you tried turning it off and on again?** Yes / No",
                tags: ["work"], usageCount: 31),
            Snippet(name: "Home address", keyword: ";addr", body: "742 Evergreen Terrace\nSpringfield", usageCount: 17),
            Snippet(name: "Today (ISO)", keyword: ";today", body: "{date format=\"yyyy-MM-dd\"}", usageCount: 64),
        ]
        for snippet in snippets { _ = try store.save(snippet) }
    }

    // MARK: - Reading list

    private static func seedReadingList(_ store: ReadingListStore) throws {
        let links: [(url: String, title: String, app: String, hoursAgo: Double, read: Bool, note: String?)] = [
            ("https://www.joelonsoftware.com/2000/04/06/things-you-should-never-do-part-i/", "Things You Should Never Do, Part I", "Safari", 400, true, nil),
            ("https://infiniteundo.com/post/25326999628/falsehoods-programmers-believe-about-time", "Falsehoods Programmers Believe About Time", "Safari", 120, true, nil),
            ("https://css-tricks.com/centering-css-complete-guide/", "Centering in CSS: A Complete Guide", "Safari", 72, false, "Bookmark #47 on this topic. This time I'll remember."),
            ("https://rubberduckdebugging.com/", "Rubber Duck Debugging", "Messages", 30, false, "Sent by Sam after I asked them about my bug for 40 minutes."),
            ("https://www.kingarthurbaking.com/recipes/sourdough-bread-recipe", "Basic Sourdough Bread", "Safari", 8, false, "For Gerald's first real loaf."),
            ("https://developer.apple.com/documentation/swift/adoptingswift6", "Adopting strict concurrency in Swift 6 apps", "Safari", 2, false, nil),
            ("https://xkcd.com/1205/", "Is It Worth the Time?", "Mail", 0.5, false, nil),
        ]
        for link in links {
            let item = try store.add(url: link.url, title: link.title, sourceAppName: link.app, now: .now.addingTimeInterval(-link.hoursAgo * 3600))
            if link.note != nil { try store.edit(id: item.id!, title: link.title, note: link.note) }
            if link.read { try store.setRead(true, id: item.id!, at: .now.addingTimeInterval(-link.hoursAgo * 1800)) }
        }
    }

    // MARK: - Files

    private static func writeFiles(_ files: [String: String], under folder: URL) throws {
        for (path, text) in files {
            let url = folder.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try relativeDays(text).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// `{{day+2}}` is the day after tomorrow, so the due dates stay as
    /// close whenever the screenshots are taken.
    private static func relativeDays(_ text: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        var text = text
        while let match = text.firstMatch(of: /\{\{day\+(\d+)\}\}/) {
            let date = Calendar.current.date(byAdding: .day, value: Int(match.1)!, to: .now)!
            text.replaceSubrange(match.range, with: formatter.string(from: date))
        }
        return text
    }

    private static let actions: [String: String] = [
        "github.toml": """
            name = "GitHub Repository"
            trigger = "gh"
            url = "https://github.com/{argument}"
            example = "owner/repo"
            """,
        "deploy.toml": """
            name = "Deploy to Production"
            trigger = "deploy"
            command = "~/homelab/deploy.sh {argument}"
            argument = "optional"
            confirm = true
            symbol = "paperplane"
            keywords = ["ship", "yolo"]
            """,
        "tracking.toml": """
            name = "Track Parcel"
            trigger = "track"
            accepts = ["text"]
            matches = "^1Z[0-9A-Z]{16}$"
            url = "https://www.ups.com/track?tracknum={argument}"
            symbol = "shippingbox"
            """,
        "shrink-video.toml": """
            name = "Shrink Video to 720p"
            accepts = ["files"]
            extensions = ["mov", "mp4"]
            command = "ffmpeg -nostdin -i {input} -vf scale=-2:720 {output}"
            output_extension = "mp4"
            output_suffix = "-720p"
            symbol = "film"
            """,
    ]

    private static let projects = """
        scan = []

        [cortex]
        path = "~/Developer/cortex"

        [homelab]
        path = "~/Developer/homelab"

        [pi]
        host = "raspberrypi"
        path = "/home/pi/home-assistant"

        [sourdough-tracker]
        path = "~/Developer/sourdough-tracker"
        """

    static let notes: [String: String] = [
        "inbox/notes/2026-10-22-potrace.md": """
            ---
            title: Convert a PNG to an SVG with potrace
            tags: [images, cli]
            created: 2026-10-22T10:12:00Z
            updated: 2026-10-22T10:12:00Z
            ---
            potrace only reads bitmaps, so convert first:

            ```sh
            magick input.png -threshold 50% input.pbm
            potrace input.pbm -s -o output.svg
            ```
            """,
        "homelab/README.md": """
            ---
            name: Homelab
            summary: The Raspberry Pi cluster under the stairs
            symbol: server.rack
            folders: [~/Developer/homelab]
            ---
            Three Raspberry Pis, one NAS and a router that needs a reboot every full moon.
            """,
        "homelab/notes/the-pi-keeps-rebooting.md": """
            ---
            title: The Pi keeps rebooting
            tags: [raspberry-pi, hardware]
            created: 2026-09-14T21:03:00Z
            updated: 2026-10-20T08:15:00Z
            ---
            **It was the power supply.** It is always the power supply.

            Symptoms: random reboots under load, a little lightning bolt in the corner of the screen,
            and `vcgencmd get_throttled` says:

            ```sh
            $ vcgencmd get_throttled
            throttled=0x50005
            ```

            Fix: the official 27 W USB-C supply. Not the phone charger from the drawer.
            """,
        "homelab/notes/docker-on-a-new-server.md": """
            ---
            title: Docker on a new server
            tags: [docker, setup]
            created: 2026-08-02T18:40:00Z
            updated: 2026-10-01T19:22:00Z
            ---
            ```sh
            curl -fsSL https://get.docker.com | sh
            sudo usermod -aG docker $USER
            ```

            Log out and back in, or nothing works and you will spend an hour finding out why.
            """,
        "homelab/skills/deploy-with-compose/SKILL.md": """
            ---
            name: deploy-with-compose
            description: Deploys a service of the homelab with Docker Compose and checks that it came up
            ---
            1. `ssh pi@raspberrypi`
            2. `cd ~/services/<name> && git pull`
            3. `docker compose up -d --build`
            4. Check `docker compose ps` until it says healthy.
            """,
        "homelab/todos/fix-restic-backup.md": """
            ---
            title: Fix the restic backup
            status: open
            tags: [backup]
            due: {{day+7}}
            created: 2026-10-22T10:12:00Z
            updated: 2026-10-22T10:12:00Z
            ---
            The nightly run has been failing since the volume move.

            - [x] check the cron log
            - [ ] rotate the S3 key
            - [ ] run once by hand
            """,
        "homelab/todos/reboot-the-router.md": """
            ---
            title: Reboot the router (full moon)
            status: open
            tags: [network]
            due: {{day+13}}
            created: 2026-10-06T10:12:00Z
            updated: 2026-10-06T10:12:00Z
            ---
            """,
        "sourdough/README.md": """
            ---
            name: Sourdough
            summary: Keeping Gerald, the starter, alive
            symbol: leaf
            ---
            Gerald was born on 2026-09-01. He is doing his best.
            """,
        "sourdough/notes/feeding-schedule.md": """
            ---
            title: Gerald's feeding schedule
            tags: [gerald, baking]
            created: 2026-09-01T09:00:00Z
            updated: 2026-10-21T07:30:00Z
            ---
            | When | Flour | Water |
            | --- | --- | --- |
            | Morning | 50 g rye | 50 g |
            | Evening | 50 g wheat | 50 g |

            Smells like nail polish remover? He's hungry. Feed him twice.
            """,
        "sourdough/todos/feed-gerald.md": """
            ---
            title: Feed Gerald
            status: open
            tags: [gerald]
            due: {{day+0}}
            created: 2026-10-22T10:12:00Z
            updated: 2026-10-22T10:12:00Z
            ---
            - [x] 50 g rye
            - [ ] 50 g water
            - [ ] tell him he's doing great
            """,
        "inbox/todos/2026-10-21-smoke-detector.md": """
            ---
            title: Find out which smoke detector chirps at 3 a.m.
            status: open
            tags: [home]
            created: 2026-10-21T03:04:00Z
            updated: 2026-10-21T03:04:00Z
            ---
            """,
        "inbox/todos/2026-10-19-renew-domain.md": """
            ---
            title: Renew the domain before it expires (again)
            status: open
            tags: [urgent]
            due: {{day+2}}
            created: 2026-10-19T12:00:00Z
            updated: 2026-10-19T12:00:00Z
            ---
            """,
        "inbox/todos/2026-10-02-tax-return.md": """
            ---
            title: Do the tax return
            status: done
            created: 2026-10-02T12:00:00Z
            updated: 2026-10-12T12:00:00Z
            done: 2026-10-12T12:00:00Z
            ---
            """,
    ]
}
