import Foundation

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "harness": exit(runHarness(args: Array(args.dropFirst())))
case "codex-hook": exit(runCodexHook(args: Array(args.dropFirst())))
case "inbox": exit(runInbox(args: Array(args.dropFirst())))
case "probe-tools":
    do {
        let data = try HarnessIO.readInput()
        let value = try JSONDecoder().decode(HarnessToolsConfiguration.self, from: data)
        let configuration = try HarnessToolsConfiguration(claudeHomes: value.claudeHomes, codexHomes: value.codexHomes,
            skillsRoot: value.skillsRoot, stateRoot: value.stateRoot)
        if args[1] == "install" { try HarnessTools.install(configuration, executable: HarnessIO.canonical(CommandLine.arguments[0])) }
        else if args[1] == "remove" { try HarnessTools.remove(configuration.stateRoot) }
        try harnessPrint(HarnessTools.status(configuration))
    } catch { exit(harnessError(error)) }
case "probe-process":
    do {
        let result = try HarnessProcess.run(executable: "/bin/bash", arguments: ["-c", args[1]],
            input: FileHandle.standardInput.readDataToEndOfFile(), cwd: FileManager.default.currentDirectoryPath,
            environment: ProcessInfo.processInfo.environment, timeout: Double(args[2])!)
        try harnessPrint(["code": result.code, "stdout": String(decoding: result.stdout, as: UTF8.self),
            "stderr": String(decoding: result.stderr, as: UTF8.self), "failure": result.failure ?? ""])
    } catch { exit(harnessError(error)) }
case "probe-patch":
    do { try harnessPrint(HarnessPatch.events(HarnessIO.object(HarnessIO.readInput()))) }
    catch { exit(harnessError(error)) }
case "probe-trust":
    do {
        let manifest = try HarnessIO.loadManifest(args[1])
        try harnessPrint(HarnessNativeTrust.summarize(HarnessIO.readInput(), home: manifest.location.targetHome,
            cwd: FileManager.default.currentDirectoryPath, manifest: manifest))
    } catch { exit(harnessError(error)) }
default: exit(2)
}
