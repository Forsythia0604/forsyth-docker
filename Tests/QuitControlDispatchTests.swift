import Foundation

@main
struct QuitControlDispatchTests {
    @MainActor
    static func main() async {
        var started = 0, finished = 0, returned = 0
        let first = Task { @MainActor in await DockerQuitControlDispatch.request(); returned += 1 }
        let second = Task { @MainActor in await DockerQuitControlDispatch.request(); returned += 1 }
        try? await Task.sleep(for: .milliseconds(50))
        precondition(returned == 0, "Cold-start requests must wait for the host to be ready")
        DockerQuitControlDispatch.install {
            started += 1
            try? await Task.sleep(for: .milliseconds(150))
            finished += 1
        }
        try? await Task.sleep(for: .milliseconds(50))
        precondition(started == 2 && returned == 0, "Do not acknowledge an action before the quit operation completes")
        await first.value; await second.value
        precondition(finished == 2 && returned == 2, "Every queued invocation must receive its completion")
        await DockerQuitControlDispatch.request()
        precondition(started == 3 && finished == 3, "A warm host must accept a later invocation")
        print("Quit control dispatch: 4 checks passed")
    }
}
