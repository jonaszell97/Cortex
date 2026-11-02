import AppKit
import Testing
@testable import Cortex
import CortexCore

/// The progress card and the menu bar ring for running quick actions.
@MainActor
@Suite struct ActionProgressTests {
    let service: ActionsService
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-progress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "name = 'Slow'\naccepts = ['none']\ncommand = 'sleep 30'".write(
            to: directory.appending(path: "slow.toml"), atomically: true, encoding: .utf8)
        try "name = 'Quick'\naccepts = ['none']\ncommand = 'true'".write(
            to: directory.appending(path: "quick.toml"), atomically: true, encoding: .utf8)
        service = ActionsService(directory: directory, defaults: UserDefaults(suiteName: "CortexTests-\(UUID().uuidString)")!)
        service.reload()
    }

    func action(_ id: String) -> any QuickAction {
        service.allActions.first { $0.id == id }!
    }

    func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test func overallProgress() {
        let a = ActionJob(title: "A", inputSummary: "a")
        let b = ActionJob(title: "B", inputSummary: "b")
        #expect(ActionJob.overallProgress([a, b]) == nil, "nothing reported yet")
        a.progress = 0.5
        #expect(ActionJob.overallProgress([a, b]) == 0.25, "b counts as not started")
        b.progress = 1
        #expect(ActionJob.overallProgress([a, b]) == 0.75)
    }

    @Test func ringIsATemplateImage() {
        for progress in [nil, 0, 0.4, 1] as [Double?] {
            let image = ProgressRing.image(progress: progress)
            #expect(image.isTemplate)
            #expect(image.size == ProgressRing.size)
            #expect(image.cgImage(forProposedRect: nil, context: nil, hints: nil) != nil)
        }
    }

    @Test func jobsInTheStatusMenuShowProgressAndCancel() throws {
        let job = ActionJob(title: "Compress", inputSummary: "2 files")
        #expect(ActionsModule.statusMenuItem(for: job).title == "Compress: 2 files…")
        job.progress = 0.426
        let item = ActionsModule.statusMenuItem(for: job)
        #expect(item.title == "Compress: 2 files – 43 %")
        let cancel = try #require(item.action)
        cancel()
        #expect(job.isCancelled)
    }

    @Test func ringBeatsThePauseIcon() throws {
        #expect(ActionsModule.statusIcon(for: []) == nil)
        let a = ActionJob(title: "A", inputSummary: "a")
        let one = try #require(ActionsModule.statusIcon(for: [a]))
        #expect(one.accessibilityLabel == "Cortex (running A)")
        #expect(one.image.isTemplate && one.priority > 0)
        let two = try #require(ActionsModule.statusIcon(for: [a, ActionJob(title: "B", inputSummary: "b")]))
        #expect(two.accessibilityLabel == "Cortex (running 2 actions)")
    }

    @Test func cardShowsForLongJobsAndGoesWhenCancelled() async throws {
        let card = ProgressCardController(actions: service, showDelay: .milliseconds(100))
        await service.run(action("user.slow"), input: .none, delivery: .copy)
        #expect(service.jobs.count == 1)
        #expect(!card.isShowing, "not before the delay")
        try await waitUntil { card.isShowing }
        #expect(card.isShowing)

        service.jobs[0].cancel()
        #expect(service.jobs.first?.isCancelled == true)
        try await waitUntil { service.jobs.isEmpty }
        #expect(service.jobs.isEmpty, "cancelling stops the process")
        try await waitUntil { !card.isShowing }
        #expect(!card.isShowing)
    }

    @Test func quickJobsNeverShowTheCard() async throws {
        let card = ProgressCardController(actions: service, showDelay: .milliseconds(500))
        await service.run(action("user.quick"), input: .none, delivery: .copy)
        try await waitUntil { service.jobs.isEmpty }
        try await Task.sleep(for: .milliseconds(700))
        #expect(!card.isShowing)
    }
}
