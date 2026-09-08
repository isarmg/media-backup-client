import Foundation
import Darwin

@main
struct BackupDirectoryRegression {
    static func main() throws {
        let temporary = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resolved = try BackupDirectory.canonicalSystemDirectory(temporary)
        precondition(resolved.path.hasPrefix("/private/var/"), "fixture must use the real Darwin /var alias")
        let alias = URL(fileURLWithPath: String(resolved.path.dropFirst("/private".count)), isDirectory: true)
        let rejected = Darwin.open(alias.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
        if rejected >= 0 { Darwin.close(rejected) }
        precondition(rejected < 0, "strict native check must reproduce the old alias failure")
        let fixed = try BackupDirectory.canonicalSystemDirectory(alias)
        precondition(fixed.path == resolved.path, "kernel path must retain /private")
        let accepted = Darwin.open(fixed.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY)
        precondition(accepted >= 0, "native check must accept resolved system path")
        Darwin.close(accepted)
        let file = fixed.appendingPathComponent("preserved.txt")
        try Data("preserved".utf8).write(to: file)
        let readBack = try Data(contentsOf: alias.appendingPathComponent("preserved.txt"))
        precondition(readBack == Data("preserved".utf8))
        print("Swift /var alias: old native path rejected, kernel path accepted, existing data preserved")
    }
}
