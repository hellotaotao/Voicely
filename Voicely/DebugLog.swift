//
//  DebugLog.swift
//  Voicely
//

import Foundation

@inline(__always)
func debugLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print(message())
    #endif
}
