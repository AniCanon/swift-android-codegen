/// A simple indent-tracking code writer for generating source files.
struct CodeWriter {
    private var buffer = ""
    private var indentLevel = 0
    private let indentString = "    "

    mutating func line(_ text: String = "") {
        if text.isEmpty {
            buffer += "\n"
        } else {
            buffer += String(repeating: indentString, count: indentLevel) + text + "\n"
        }
    }

    mutating func indent() { indentLevel += 1 }
    mutating func dedent() { indentLevel = max(0, indentLevel - 1) }

    mutating func indented(_ body: (inout CodeWriter) -> Void) {
        indent()
        body(&self)
        dedent()
    }

    var output: String { buffer }
}
