import Foundation

// The Variables sheet shows a collection's variables as rows, with one value each, and
// every environment as a column of other values for the same names. These are the rules
// behind that table, kept here so they can be tested without the app.

extension Variable {
    /// The one value the table shows and edits: the value requests use.
    public var shownValue: String {
        get { effectiveValue }
        set {
            if !secret, currentValue != nil { currentValue = newValue } else { value = newValue }
        }
    }

    /// True when the value is kept on this Mac only and never written to the workspace.
    /// Turning it on moves the value off the workspace, and turning it off moves it back.
    /// A secret is always kept off the workspace, in the Keychain, so this is false for one.
    public var isLocalOnly: Bool {
        get { !secret && currentValue != nil }
        set {
            guard !secret, newValue != isLocalOnly else { return }
            if newValue {
                currentValue = value
                value = ""
            } else {
                value = currentValue ?? value
                currentValue = nil
            }
        }
    }

    /// Marks the variable secret or not, keeping the value it shows.
    public mutating func setSecret(_ on: Bool) {
        guard on != secret else { return }
        let shown = shownValue
        secret = on
        currentValue = nil
        value = shown
    }
}

extension APIEnvironment {
    /// The value this environment has of its own for a name, if any.
    public func override(named name: String) -> Variable? {
        guard !name.isEmpty else { return nil }
        return variables.first { $0.key == name }
    }

    /// Gives a variable a value of its own in this environment. Empty text takes that value
    /// away, so the collection's value applies again.
    /// - Parameter secret: Whether a value added here should be secret, as the collection's is.
    public mutating func setOverride(_ text: String, for name: String, secret: Bool = false) {
        guard !name.isEmpty else { return }
        if text.isEmpty {
            variables.removeAll { $0.key == name }
        } else if let index = variables.firstIndex(where: { $0.key == name }) {
            variables[index].shownValue = text
            variables[index].enabled = true
        } else {
            variables.append(Variable(key: name, value: text, secret: secret))
        }
    }

    /// Renames a variable, so its value here follows a variable renamed in the table.
    /// Nothing changes when the new name is already taken in this environment.
    /// - Returns: False when the new name was taken.
    @discardableResult
    public mutating func renameVariable(_ old: String, to new: String) -> Bool {
        guard !old.isEmpty, !new.isEmpty, old != new else { return true }
        guard override(named: new) == nil else { return false }
        for index in variables.indices where variables[index].key == old { variables[index].key = new }
        return true
    }
}

public enum VariableTable {
    /// The names that have a value in some environment but are not among the given names,
    /// in the order they are first met. The table lists them under the collection's own rows.
    public static func names(onlyIn environments: [APIEnvironment], notAmong names: [String]) -> [String] {
        var seen = Set(names)
        var out: [String] = []
        for environment in environments {
            for variable in environment.variables where !variable.key.isEmpty && !seen.contains(variable.key) {
                seen.insert(variable.key)
                out.append(variable.key)
            }
        }
        return out
    }

    /// A name for a new environment that no other has: "New Environment", then "New Environment 2".
    public static func newEnvironmentName(among environments: [APIEnvironment]) -> String {
        let taken = Set(environments.map(\.name))
        let base = "New Environment"
        guard taken.contains(base) else { return base }
        var counter = 2
        while taken.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }
}
