import Foundation

func runCodexHook(args: [String]) -> Int32 {
    do {
        let parsed = try HarnessArguments(["hook"] + args, options: ["--manifest", "--entry"])
        let input = try HarnessIO.readInput()
        let event = try HarnessIO.object(input)
        let manifestPath = try parsed.path("--manifest", fallback: ""), entry = try parsed.required("--entry")
        let result = entry == "lifecycle"
            ? HarnessLifecycle.run(manifestPath: manifestPath, event: event)
            : HarnessBridge.run(manifestPath: manifestPath, entryID: entry, event: event)
        if let output = result.output { try harnessPrint(output) }
        if !result.error.isEmpty { FileHandle.standardError.write(Data(result.error.utf8)) }
        return result.code
    } catch { return harnessError(error) }
}
