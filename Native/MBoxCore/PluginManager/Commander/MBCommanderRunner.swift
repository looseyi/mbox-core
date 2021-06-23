//
//  MBCommanderRunner.swift
//  MBoxCore
//
//  Created by Whirlwind on 2019/7/6.
//  Copyright © 2019 bytedance. All rights reserved.
//

import Foundation
import ObjCCommandLine

public var command: MBCommander?
public var cmdClass: MBCommander.Type = MBCommanderGroup.shared.command!
public var cmdGroup: MBCommanderGroup = MBCommanderGroup.shared

private func setupSingal() {
    ignoreSignal(SIGTTOU)
    trapSignal(.Crash) { signal in
        resetSTDIN()
        UI.indents.removeAll()
        Thread.callStackSymbols.forEach{
            UI.log(info: $0)
        }

        let signalName = "Receive Signal: \(String(cString: strsignal(signal)))"
        UI.log(summary: signalName)
        let error = NSError(domain: "Signal",
                            code: Int(signal),
                            userInfo: [NSLocalizedDescriptionKey: signalName])
        let code = finish(signal, error: error)
        exitApp(code)
    }
    trapSignal(.Cancel) { signal in
        resetSTDIN()
        let signalName = "[Cancel] \(String(cString: strsignal(signal)))"
        UI.log(summary: signalName.ANSI(.red))
        let error = NSError(domain: "Signal",
                            code: Int(signal),
                            userInfo: [NSLocalizedDescriptionKey: signalName])
        let code = finish(signal, error: error)
        exitApp(code)
    }
}

private var startTime = Date()
private func logCommander(parser: ArgumentParser) {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .iso8601)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    UI.log(info: "[\(formatter.string(from: startTime))] \(parser.rawDescription)", pip: .FILE)
}

private var sessionTitle: String? {
    var logNames = [String]()
    for arg in CommandLine.arguments.dropFirst() {
        if arg.hasPrefix("-") || arg.count > 20 { break }
        logNames.append(arg)
    }
    return logNames.isEmpty ? nil : logNames.joined(separator: " ")
}

public func exitApp(_ exitCode: Int32) {
    waitExit(exitCode)
    MBSession.current = nil
    exit(exitCode)
}

public func runCommander() {
    MBCMD.isCMDEnvironment = true

    var exitCode: Int32 = 0
    do {
        let code = try runCommander(CommandLine.arguments)
        exitCode = finish(code)
    } catch {
        if exitSignal != nil { return }
        exitCode = finish(UI.statusCode, error: error)
        if !(error is UserError),
           !(error is ArgumentError),
           let logFile = UI.logger.verbLogFileInfo {
            UI.log(info: "The log was saved: `\(logFile.filePath)`")
        }
    }
    exitApp(exitCode)
}

public func runCommander(_ arguments: [String]) throws -> Int32 {
    let session = MBSession(title: sessionTitle, isMain: true)
    MBSession.main = session

    setupSingal()

    storeSTDIN()
    defer {
        resetSTDIN()
    }

    if ProcessInfo.processInfo.environment["SUDO_USER"] != nil {
        print("[ERROR] Please not use `sudo`!")
        exit(254)
    }

    let parser = ArgumentParser(arguments: arguments)
    UI.args = parser
    if let root = try? parser.option(for: "root") {
        UI.rootPath = root.expandingTildeInPath
    }
    if ProcessInfo.processInfo.arguments.first?.lastPathComponent == "MDevCLI" {
        guard let path = try? parser.option(for: "dev-root") ?? ProcessInfo.processInfo.environment["MBOX2_DEVELOPMENT_ROOT"] else {
            print("[ERROR] `mdev` require the `--dev-root` option or `MBOX2_DEVELOPMENT_ROOT` environment variable.")
            exit(253)
        }
        UI.devRoot = path.expandingTildeInPath
    }

    if parser.hasOption("no-logfile") {
        UI.logger.avaliablePipe = UI.logger.avaliablePipe.withoutFILE()
    } else if let logfile = try? parser.option(for: "logfile"),
              logfile.count > 0,
              logfile.deletingPathExtension.count > 0 {
        let ext = logfile.pathExtension
        UI.logger.infoFilePath = logfile
        UI.logger.verbFilePath = logfile.deletingPathExtension.appending(pathExtension: "verbose").appending(pathExtension: ext)
    }

    MBPluginManager.shared.runAll()

    MBCommanderGroup.preParse(parser)

    _ = parser.argument()!  // Executable Name

    logCommander(parser: parser)

    UI.verbose = parser.hasOption("verbose") || parser.hasFlag("v")

    var throwError: Error?

    do {
    
        MBPluginManager.shared.registerCommander()
        
        _ = try executeCommand(parser: parser)
    } catch let error as ArgumentError {
        let help = Help(command: cmdClass, group: cmdGroup, argv: parser)
        if UI.showHelp, UI.apiFormatter != .none {
            UI.log(api: help.APIDescription(format: UI.apiFormatter))
        } else {
            if !error.description.isEmpty {
                UI.log(info: error.description)
                UI.log(info: "", pip: .ERR)
                throwError = error
            }
            UI.log(info: help.description,
                   pip: .ERR)
        }
    } catch let error as RuntimeError {
        throwError = error
        if error.description.count > 0 {
            UI.log(error: error.description, output: false)
        }
    } catch let error as UserError {
        throwError = error
        if error.description.count > 0 {
            UI.log(error: error.description, output: false)
        }
    } catch let error as NSError {
        throwError = error
        let info: String
        if let reason = error.localizedFailureReason {
            info = "(code: \(error.code) reason: \(reason))"
        } else {
            info = "(code: \(error.code))"
        }
        UI.log(error: "Error: \(error.domain) \(info)\n\t\(error.localizedDescription)")
    } catch {
        throwError = error
        UI.log(error: "\("Unknown error occurred.")\n\t\(error.localizedDescription)")
    }

    if let error = throwError {
        throw error
    } else {
        return UI.statusCode
    }
}

dynamic
public func executeCommand(parser: ArgumentParser) throws -> String {
    if let group = MBCommanderGroup.shared.command(for: parser) {
        cmdGroup = group
    } else {
        // 使用 MBCommander 基类解析基础 Options/Flags
        _ = try cmdClass.init(argv: parser)
        throw ArgumentError.invalidCommand("Not found command `\(parser.rawArguments.dropFirst().first!)`")
    }

    if let cmd = cmdGroup.command {
        cmdClass = cmd.forwardCommand ?? cmd
    } else {
        throw ArgumentError.invalidCommand(nil)
    }

    command = try cmdClass.init(argv: parser)
    try command?.performAction()
    return UI.showHelp ? "help.\(cmdClass.fullName)" : cmdClass.fullName
}

@discardableResult
dynamic public func finish(_ code: Int32, error: Error? = nil) -> Int32 {
    UI.logSummary()

    let finishTime = Date()
    UI.duration = finishTime.timeIntervalSince(startTime)
    let duration = MBSession.durationFormatter.string(from: startTime, to: finishTime)!
    UI.log(verbose: "==" * 20 + " " + duration + " " + "==" * 20, pip: .FILE)

    let error = UI.showHelp ? nil : error
    var exitCode: Int32 = 0
    if code != 0 {
        exitCode = code
    } else if let error = error {
        if let error = error as? RuntimeError {
            exitCode = error.code
        } else if let _ = error as? UserError {
            exitCode = 254
        } else {
            exitCode = Int32((error as NSError).code)
        }
    }

    return exitCode
}

dynamic
public func waitExit(_ code: Int32) {
    try? FileManager.default.removeItem(atPath: FileManager.temporaryDirectory)
}
