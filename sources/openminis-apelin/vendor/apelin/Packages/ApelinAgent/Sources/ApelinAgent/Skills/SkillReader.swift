import Foundation
import KWWKAI

/// `apelin_skill_read`: a skill's instructions, or a file from its folder, read
/// when a task calls for them. The catalogue is loaded again on each call,
/// so a skill added or edited during a session is the one read.
struct SkillReader {
    static let maxBodyBytes = 64 * 1024
    static let maxFileBytes = 256 * 1024
    static let maxListedFiles = 100

    let userDirectory: URL

    func read(_ arguments: JSONValue) throws -> String {
        let asked = try arguments.requireString("name")
        let skills = SkillCatalog.load(userDirectory: userDirectory).skills
        let name = skills.contains { $0.name == asked } ? asked : BuiltInSkills.legacyNames[asked] ?? asked
        guard let skill = skills.first(where: { $0.name == name }) else {
            throw ToolArgumentError("No skill named \(name). Skills: \(skills.map(\.name).joined(separator: ", ")).")
        }
        if let file = arguments.argNonEmptyString("file") {
            if let contents = skill.files[file] {
                return Self.bounded(Data(contents.utf8), Self.maxFileBytes)
            }
            guard let directory = skill.directory else {
                let files = skill.files.keys.sorted()
                throw ToolArgumentError(files.isEmpty
                    ? "\(name) has no files; leave file out to read its instructions."
                    : "\(name) has no file \(file). Its files: \(files.joined(separator: ", ")).")
            }
            return try readFile(file, in: directory)
        }
        var text = Self.bounded(Data(skill.body.utf8), Self.maxBodyBytes)
        let files = skill.files.keys.sorted() + (skill.directory.map(Self.files(in:)) ?? [])
        if !files.isEmpty {
            text += "\n\nFiles in this skill's folder (apelin_skill_read with file): " + files.joined(separator: ", ")
        }
        return text
    }

    private func readFile(_ relative: String, in directory: String) throws -> String {
        let root = try ScopedRoot(URL(fileURLWithPath: directory, isDirectory: true))
        let path = try root.resolveExisting(relative)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: path)
        else {
            throw ToolArgumentError("\(relative) is not a file.")
        }
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
        guard !data.prefix(8192).contains(0) else {
            throw ToolArgumentError("\(relative) is not a text file.")
        }
        return Self.bounded(data, Self.maxFileBytes)
    }

    static func bounded(_ data: Data, _ limit: Int) -> String {
        guard data.count > limit else { return String(decoding: data, as: UTF8.self) }
        return String(decoding: data.prefix(limit), as: UTF8.self) + "\n… (truncated)"
    }

    /// Regular files below the folder, without following links, hidden
    /// entries or the `SKILL.md` already read.
    static func files(in directory: String) -> [String] {
        guard let walker = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        while let relative = walker.nextObject() as? String {
            let name = (relative as NSString).lastPathComponent
            if name.hasPrefix(".") {
                if walker.fileAttributes?[.type] as? FileAttributeType == .typeDirectory {
                    walker.skipDescendants()
                }
                continue
            }
            guard walker.fileAttributes?[.type] as? FileAttributeType == .typeRegular, relative != "SKILL.md" else {
                continue
            }
            files.append(relative)
            if files.count == maxListedFiles {
                break
            }
        }
        return files.sorted()
    }
}
