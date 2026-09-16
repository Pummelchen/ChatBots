// ChatBotsCoreTests — the API trace switch (A140).
//
// `CHATBOTS_TRACE_API` prints each request to a cloud endpoint on standard error so a protocol
// problem can be seen. It was tested with `!= nil`, so `CHATBOTS_TRACE_API=0` turned it *on*; it
// printed the whole body — instructions and the entire conversation, with every attached image
// base64-encoded inline — with no cap; and nothing in the README or `SECURITY.md` said it existed,
// while `SECURITY.md` promises the conversation leaves the machine only to the chosen endpoint.
//
// The switch stays, because protocol debugging needs it. What is tested here is that setting it to
// something that means "off" leaves it off, and that switching it on writes a bounded summary with
// the image payloads left out.

import Foundation
import Testing
@testable import ChatBotsCore

/// Runs `body` with standard error captured to a file, and returns what was written to it.
///
/// Standard error is restored *before* this returns, so an assertion failure is reported where the
/// test runner can see it rather than into the captured file — which is what happened the first time
/// this test was written, and made a failing test print nothing at all.
private func capturingStandardError<T>(_ body: () async -> T) async -> (value: T, written: String) {
    let log = FileManager.default.temporaryDirectory.appending(path: "trace-\(UUID().uuidString).log")
    FileManager.default.createFile(atPath: log.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: log) else {
        return (await body(), "")
    }
    let saved = dup(STDERR_FILENO)
    dup2(handle.fileDescriptor, STDERR_FILENO)
    let value = await body()
    dup2(saved, STDERR_FILENO)
    close(saved)
    try? handle.close()
    let written = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: log)
    return (value, written)
}

/// One request to a port nothing listens on: the trace is written before the connection is
/// attempted, so the endpoint does not need to exist for this to be about the trace.
private func tracedRequest(_ request: OpenAIResponsesClient.Request) async {
    let client = OpenAIResponsesClient(endpoint: OpenAIEndpoint(baseURL: "http://127.0.0.1:9"))
    do {
        for try await _ in client.stream(request) { Issue.record("nothing can stream here") }
    } catch {
        // Expected: the connection is refused. What this test is about was already written.
    }
}

@Suite("The API trace switch (A140)", .serialized)
struct TraceSwitchTests {

    @Test("Only a value that means 'on' turns the trace on")
    func truthiness() {
        // The defect: `!= nil` meant every one of these turned it on.
        for off in [nil, "", "0", "false", "FALSE", "no", "  "] {
            #expect(!OpenAIResponsesClient.traceIsOn(off), "\(off ?? "nil") must not enable the trace")
        }
        for on in ["1", "true", "yes", "on", "anything"] {
            #expect(OpenAIResponsesClient.traceIsOn(on), "\(on) must enable the trace")
        }
    }

    @Test("Switching it on prints a bounded body with the image payloads left out")
    func outputIsBoundedAndOmitted() async {
        let secretImage = String(repeating: "QUJD", count: 400)
        let request = OpenAIResponsesClient.Request(
            instructions: "You are a participant.",
            input: String(repeating: "a very long conversation ", count: 400),
            images: [
                OpenAIResponsesClient.ImageAttachment(mediaType: "image/png", base64: secretImage)
            ])

        setenv("CHATBOTS_TRACE_API", "1", 1)
        let (_, written) = await capturingStandardError { await tracedRequest(request) }
        unsetenv("CHATBOTS_TRACE_API")

        let trace = written.split(separator: "\n").filter { $0.hasPrefix("[trace]") }.map(String.init)
        #expect(!trace.isEmpty, "the switch was on, so something was traced")
        #expect(trace.contains { $0.contains("POST http://127.0.0.1:9/v1/responses") })
        #expect(
            trace.contains { $0.contains("image payload(s) omitted") },
            "the trace says the images were left out: \(trace.first ?? "")")
        #expect(!written.contains(secretImage), "and the base64 is not in the output")
        #expect(!written.contains(String(repeating: "QUJD", count: 10)), "not even its beginning")

        // The body line is capped, so a conversation cannot be spilled into a log by the kilobyte.
        // The body is the trace line that is not the request line; the preview is the truncated one,
        // so looking for a key that sorts late would find nothing at all.
        let bodyLine = trace.first { !$0.contains("POST ") } ?? ""
        #expect(
            bodyLine.count <= OpenAIResponsesClient.traceLimit + 200,
            "the printed body is within the limit, was \(bodyLine.count)")
        // Keys sort, so a long input fills the cap and the fields after it are the ones that get cut.
        #expect(bodyLine.contains("\"input\""), "while still showing the request's own shape")
    }

    @Test("A body that fits is traced whole, so the switch still shows what was sent")
    func shortBodyIsTracedWholly() async {
        setenv("CHATBOTS_TRACE_API", "1", 1)
        let (_, written) = await capturingStandardError {
            await tracedRequest(
                OpenAIResponsesClient.Request(
                    instructions: "You are a participant.", input: "hello"))
        }
        unsetenv("CHATBOTS_TRACE_API")

        // The counterweight to the test above: the cap must not be so aggressive that the switch
        #expect(written.contains("You are a participant."), "the instructions are visible")
        #expect(written.contains("hello"), "and so is the input")
        #expect(!written.contains("omitted"), "and nothing says it was omitted when nothing was")
    }

    @Test("Switching it off prints nothing at all")
    func offPrintsNothing() async {
        setenv("CHATBOTS_TRACE_API", "0", 1)
        let (_, written) = await capturingStandardError {
            await tracedRequest(OpenAIResponsesClient.Request(input: "hello"))
        }
        unsetenv("CHATBOTS_TRACE_API")

        #expect(!written.contains("[trace]"), "CHATBOTS_TRACE_API=0 must not print the conversation")
    }
}
