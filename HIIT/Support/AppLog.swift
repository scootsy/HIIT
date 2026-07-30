import os

/// Small, targeted loggers — enough to diagnose the realistic bug reports
/// (lost workout, missing Health export, strap that won't connect) from a
/// device log, without ever logging health values themselves.
enum AppLog {
    static let save = Logger(subsystem: "com.scootsy.HIIT", category: "save")
    static let health = Logger(subsystem: "com.scootsy.HIIT", category: "health")
    static let ble = Logger(subsystem: "com.scootsy.HIIT", category: "ble")
}
