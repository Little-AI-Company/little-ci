import Foundation
import Testing
@testable import LittleCICore

@Suite("Failure classification on recorded job logs")
struct FailureClassifierTests {
    func job(_ name: String) -> WorkflowJob { Fixture.decode(WorkflowJob.self, "logs/\(name).job.json") }
    func log(_ name: String) -> String { Fixture.text("logs/\(name).log") }

    @Test("Machine signatures", arguments: [
        ("runner-lost", "runner lost"),
        ("compose-missing", "Docker Compose missing"),
        ("docker-down", "Docker down"),
        ("toolchain-node", "toolchain drift"),
    ])
    func machineSignature(name: String, reason: String) {
        let result = FailureClassifier.classify(job(name), log: log(name))
        #expect(result.cause == .machine)
        #expect(result.reason == reason)
    }

    @Test("The toolchain check's script, echoed in every log, is not a toolchain failure")
    func scriptEchoIsNotEvidence() {
        let text = log("code-failure")
        #expect(text.contains("package.json asks for"), "the fixture carries the echoed script")
        #expect(FailureClassifier.classify(job("code-failure"), log: text).cause == .code)
    }

    @Test("Disk full is read from the job's annotations")
    func diskFullFromAnnotations() {
        let annotations = try! JSONDecoder().decode([String].self, from: Fixture.data("logs/disk-full.annotations.json"))
        let result = FailureClassifier.classify(job("disk-full"), log: "", annotations: annotations)
        #expect(result.reason == "disk full")
    }

    @Test("A 5 s timeout is machine load only when the job passed on rerun")
    func timeoutNeedsAPassingRerun() {
        let rerun = job("timeout-5s.rerun")
        #expect(rerun.conclusion == "success" && rerun.runAttempt > job("timeout-5s").runAttempt)
        #expect(FailureClassifier.classify(job("timeout-5s"), log: log("timeout-5s"), context: .init(passedOnRerun: true)).cause == .machine)
        #expect(FailureClassifier.classify(job("timeout-5s"), log: log("timeout-5s")).cause == .unsure)
    }

    @Test("Check only reports other jobs")
    func aggregateJob() {
        var check = job("code-failure")
        check.name = "Check"
        #expect(FailureClassifier.classify(check, log: log("code-failure")).cause == .derived)
    }

    @Test("A rerun's copied job is not counted as new work")
    func carriedOverCopies() throws {
        var copy = job("docker-down")
        copy.createdAt = try #require(copy.startedAt).addingTimeInterval(600)
        #expect(copy.isCarriedOverCopy)
        #expect(!copy.tookRunner)
        #expect(copy.queueWait == nil)
    }
}
