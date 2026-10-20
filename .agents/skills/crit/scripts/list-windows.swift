// Prints the on-screen windows of one process as JSON, for capture.py.
//   swiftc -O list-windows.swift -o list-windows && ./list-windows <pid>
// Window titles are empty unless the calling terminal has Screen Recording permission.
import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: list-windows <pid>\n".utf8))
    exit(2)
}

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
let matching: [[String: Any]] = windows.compactMap { window in
    guard let ownerPID = window[kCGWindowOwnerPID as String] as? Int32, ownerPID == pid,
          let owner = window[kCGWindowOwnerName as String] as? String, owner.contains("Little"),
          let id = window[kCGWindowNumber as String] as? Int,
          let layer = window[kCGWindowLayer as String] as? Int,
          let bounds = window[kCGWindowBounds as String] as? [String: Double]
    else { return nil }
    return [
        "id": id,
        "owner": owner,
        "title": window[kCGWindowName as String] as? String ?? "",
        "layer": layer,
        "width": bounds["Width"] ?? 0,
        "height": bounds["Height"] ?? 0,
    ]
}
let output = try JSONSerialization.data(withJSONObject: matching, options: [.sortedKeys])
FileHandle.standardOutput.write(output)
