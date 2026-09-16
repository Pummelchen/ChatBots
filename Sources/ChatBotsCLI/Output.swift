// ChatBotsCLI — where a run writes its progress and its headings
//
// Split out of `main.swift`, which held the entry point, the command line and every mode in one
// 1132-line file. Nothing changed but which file each one lives in.

import Foundation

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func header(_ title: String) {
    print("")
    print(String(repeating: "─", count: 78))
    print(title)
    print(String(repeating: "─", count: 78))
}
