import Foundation

// The Variables sheet shows each variable with one value. These are the rules behind
// that, kept here so they can be tested without the app.

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

extension APICollection {
    /// Takes an environment's variables into the collection's own, which is how an
    /// environment from Postman or another app is imported: a collection has one set of
    /// variables. A variable with the same name is replaced, as an environment's value
    /// would have been used in place of the collection's.
    /// - Returns: How many variables were added and how many replaced.
    @discardableResult
    public mutating func adopt(_ environment: APIEnvironment) -> (added: Int, replaced: Int) {
        var added = 0, replaced = 0
        for variable in environment.variables where !variable.key.isEmpty {
            if let index = variables.firstIndex(where: { $0.key == variable.key }) {
                variables[index] = variable
                replaced += 1
            } else {
                variables.append(variable)
                added += 1
            }
        }
        return (added, replaced)
    }
}
