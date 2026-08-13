import Foundation

/// A deliberately minimal reader for Metal Shading Language.
///
/// It recovers what the rules need — entry point names, parameter address spaces
/// and attributes, and body text — and nothing else. It is not an MSL front end and
/// must not grow into one: the moment it needs full type resolution, the honest move
/// is to stop parsing and report the kernel as unanalyzed.
public enum MetalKernelParser {

    /// Recovers every `kernel` entry point in a shader source.
    ///
    /// - Parameters:
    ///   - text: Metal source, from a `.metal` file or a Swift string literal.
    ///   - source: Where the text came from, carried onto each kernel.
    /// - Returns: One record per entry point, in source order.
    public static func kernels(in text: String, source: ShaderSource) -> [MetalKernel] {
        var results: [MetalKernel] = []
        var searchStart = text.startIndex

        while let kernelWord = text.range(of: "kernel", range: searchStart..<text.endIndex) {
            searchStart = kernelWord.upperBound
            // `kernel` must stand alone — not the tail of `my_kernel`.
            if kernelWord.lowerBound > text.startIndex {
                let prev = text[text.index(before: kernelWord.lowerBound)]
                if prev.isLetter || prev.isNumber || prev == "_" { continue }
            }
            guard let openParen = text[kernelWord.upperBound...].firstIndex(of: "(") else { continue }
            guard let closeParen = matchingParen(in: text, openAt: openParen) else { continue }

            let signature = String(text[kernelWord.upperBound..<openParen])
            guard let name = entryPointName(from: signature) else { continue }

            let parameterText = String(text[text.index(after: openParen)..<closeParen])
            let parameters = splitParameters(parameterText)

            guard let bodyOpen = text[closeParen...].firstIndex(of: "{"),
                  let bodyClose = matchingBrace(in: text, openAt: bodyOpen) else { continue }
            let body = String(text[text.index(after: bodyOpen)..<bodyClose])

            results.append(MetalKernel(
                name: name,
                threadPositionParameter: threadPositionParameter(in: parameters),
                scalarParameters: scalarParameters(in: parameters),
                bufferParameters: bufferParameters(in: parameters),
                body: body,
                source: source,
                declarationLine: lineNumber(of: kernelWord.lowerBound, in: text)))

            searchStart = bodyClose
        }
        return results
    }

    // MARK: - Signature pieces

    /// The identifier immediately before the parameter list — the entry point name.
    ///
    /// The return type of a `kernel` is always `void`, so the last identifier in the
    /// text between `kernel` and `(` is the name.
    static func entryPointName(from signature: String) -> String? {
        let identifierCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        let tokens = signature.components(separatedBy: identifierCharacters.inverted)
            .filter { !$0.isEmpty }
        guard let last = tokens.last, last != "void" else { return nil }
        return last
    }

    /// Splits a parameter list on top-level commas, ignoring those inside brackets.
    ///
    /// `[[thread_position_in_grid]]` and templated types both contain commas that are
    /// not parameter separators.
    static func splitParameters(_ text: String) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            switch character {
            case "[", "(", "<": depth += 1; current.append(character)
            case "]", ")", ">": depth -= 1; current.append(character)
            case "," where depth == 0:
                parts.append(current.trimmingCharacters(in: .whitespacesAndNewlines)); current = ""
            default: current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !last.isEmpty { parts.append(last) }
        return parts.filter { !$0.isEmpty }
    }

    /// The parameter carrying `[[thread_position_in_grid]]`.
    static func threadPositionParameter(in parameters: [String]) -> String? {
        for parameter in parameters where parameter.contains("thread_position_in_grid") {
            guard let attributeStart = parameter.range(of: "[[") else { continue }
            let beforeAttribute = String(parameter[parameter.startIndex..<attributeStart.lowerBound])
            if let name = trailingIdentifier(of: beforeAttribute) { return name }
        }
        return nil
    }

    /// Scalar parameters a thread id could be bounded against.
    ///
    /// Metal passes a scalar bound as `constant uint& count` or `constant ulong& n`.
    /// A pointer is a buffer, not a bound, so `*` disqualifies.
    static func scalarParameters(in parameters: [String]) -> [String] {
        parameters.compactMap { parameter in
            guard parameter.contains("&"), !parameter.contains("*") else { return nil }
            guard parameter.contains("constant") || parameter.contains("device") else { return nil }
            return declaredName(of: parameter)
        }
    }

    /// Pointer parameters in `device` or `constant` address space.
    static func bufferParameters(in parameters: [String]) -> [String] {
        parameters.compactMap { parameter in
            guard parameter.contains("*") else { return nil }
            guard parameter.contains("device") || parameter.contains("constant") else { return nil }
            return declaredName(of: parameter)
        }
    }

    /// The parameter's own name, with any `[[...]]` attribute removed first.
    ///
    /// Taking the trailing identifier of the raw text finds the `1` in
    /// `[[buffer(1)]]` instead of the name — an attribute is a suffix that happens
    /// to end in identifier characters.
    static func declaredName(of parameter: String) -> String? {
        trailingIdentifier(of: strippingAttributes(parameter))
    }

    /// Removes every `[[...]]` attribute from a declarator.
    static func strippingAttributes(_ text: String) -> String {
        var result = text
        while let open = result.range(of: "[["),
              let close = result.range(of: "]]", range: open.upperBound..<result.endIndex) {
            result.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return result
    }

    /// The last identifier in a declarator, which is the parameter's name.
    static func trailingIdentifier(of text: String) -> String? {
        var name = ""
        for character in text.reversed() {
            if character.isLetter || character.isNumber || character == "_" {
                name.insert(character, at: name.startIndex)
            } else if name.isEmpty {
                continue
            } else {
                break
            }
        }
        return name.isEmpty ? nil : name
    }

    // MARK: - Balancing

    /// The `)` matching an `(`, honouring nesting.
    static func matchingParen(in text: String, openAt open: String.Index) -> String.Index? {
        matching(in: text, openAt: open, open: "(", close: ")")
    }

    /// The `}` matching a `{`, honouring nesting.
    static func matchingBrace(in text: String, openAt open: String.Index) -> String.Index? {
        matching(in: text, openAt: open, open: "{", close: "}")
    }

    private static func matching(
        in text: String, openAt open: String.Index, open openCharacter: Character,
        close closeCharacter: Character
    ) -> String.Index? {
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == openCharacter {
                depth += 1
            } else if character == closeCharacter {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 1-based line number of an index.
    static func lineNumber(of index: String.Index, in text: String) -> Int {
        text[text.startIndex..<index].reduce(into: 1) { count, character in
            if character.isNewline { count += 1 }
        }
    }
}
