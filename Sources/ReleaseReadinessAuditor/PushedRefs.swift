import Foundation

/// The refs git is about to push, as a `pre-push` hook receives them.
///
/// ## Why this is read rather than required
///
/// The release-tag invariant needs to be enforced where the failure becomes visible to
/// consumers — at push, not at commit. The obvious way to arrange that is a new hook, and it
/// is the wrong way: the hook is already installed in 76+ repositories, and a rule that only
/// bites after every one of them edits a shell script is a rule that mostly does not bite.
/// Worse, downgrading the commit-time check while the push-time check waits on that rollout
/// removes the protection outright in every repository that has not caught up.
///
/// It is also unnecessary. The installed template already runs
/// `quality-gate --check release-readiness`, and git hands a `pre-push` hook the ref list on
/// **stdin**, which command substitution passes straight through to the child. The data is
/// already arriving; nothing was reading it. So the capability ships with the binary, and a
/// repository gains it by upgrading the tool it already upgrades — no hook edit anywhere.
///
/// ## The format
///
/// One line per ref, four fields:
///
///     <local ref> <local sha> <remote ref> <remote sha>
///
/// A deleted ref has an all-zero local sha; a ref new on the remote has an all-zero remote sha.
public struct PushedRef: Sendable, Equatable {

    /// The local ref being pushed, e.g. `refs/tags/v0.1.1`.
    public let localRef: String

    /// The object the local ref points at, or all zeros when the ref is being deleted.
    public let localSHA: String

    /// The ref name on the remote.
    public let remoteRef: String

    /// The object the remote currently has, or all zeros when the ref is new there.
    public let remoteSHA: String

    /// Whether this line deletes the ref rather than updating it.
    public var isDeletion: Bool { localSHA.allSatisfy { $0 == "0" } }

    /// The tag name, when this ref is a tag.
    public var tagName: String? {
        localRef.hasPrefix("refs/tags/") ? String(localRef.dropFirst("refs/tags/".count)) : nil
    }
}

/// Reads and recognises a `pre-push` ref list.
public enum PushedRefs {

    /// Parses git's `pre-push` stdin format, ignoring anything that is not that format.
    ///
    /// Deliberately strict. This decides whether a run is a push boundary, so it must not
    /// mistake a here-doc, a piped config file, or a CI log for a ref list: every non-empty
    /// line has to have four fields and a `refs/` local ref, or the whole input is rejected.
    ///
    /// - Parameter input: The raw stdin text.
    /// - Returns: The refs, or `nil` when the input is not a ref list.
    public static func parse(_ input: String) -> [PushedRef]? {
        let lines = input.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }

        var refs: [PushedRef] = []
        for line in lines {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count == 4, fields[0].hasPrefix("refs/") else { return nil }
            refs.append(PushedRef(
                localRef: fields[0], localSHA: fields[1],
                remoteRef: fields[2], remoteSHA: fields[3]))
        }
        return refs
    }

    /// Reads stdin when doing so cannot block, and returns a ref list if that is what it holds.
    ///
    /// Never reads from a terminal: a person running `quality-gate` by hand would otherwise
    /// see it hang waiting for EOF. A `pre-commit` hook gets no ref list and reaches EOF
    /// immediately, which parses to `nil` and leaves the run advisory — the correct answer,
    /// since a commit is not the boundary this rule guards.
    ///
    /// - Parameter isTerminal: Whether stdin is a terminal; injected so tests need no tty.
    /// - Returns: The pushed refs, or `nil` when this is not a push boundary.
    public static func fromStandardInput(
        isTerminal: Bool = isatty(FileHandle.standardInput.fileDescriptor) == 1
    ) -> [PushedRef]? {
        guard !isTerminal else { return nil }

        // `readToEnd` blocks until EOF, so an open stdin with nothing on it would hang the whole
        // gate — a far worse failure than missing a boundary check. Git writes the ref list
        // before it runs the hook, so at a real boundary the data is already in the pipe and
        // this returns immediately. Anything that is not ready right now is not a push.
        guard hasImmediateInput() else { return nil }

        guard let data = try? FileHandle.standardInput.readToEnd(), !data.isEmpty else { // silent: no stdin at all is the ordinary case for a manual run, and it means "not a push boundary"
            return nil
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(text)
    }

    /// Whether stdin has data ready this instant, without waiting for any of it.
    ///
    /// A zero-timeout `poll` rather than a read: the question is "is this a push boundary",
    /// and the answer at a real boundary is already sitting in the pipe git filled before it
    /// invoked the hook.
    private static func hasImmediateInput() -> Bool {
        var descriptor = pollfd(
            fd: FileHandle.standardInput.fileDescriptor, events: Int16(POLLIN), revents: 0)
        return poll(&descriptor, 1, 0) > 0
    }
}
