/*
     // TODO: GLOBAL
     - Filters/Modifiers are supported longform, consider implementing short form -> Possibly compile out to longform
         `@(foo.bar()` == `@bar(foo)`
         `@(foo.bar().waa())` == `@bar(foo) { @waa(self) }`
     - Extendible Leafs
     - Allow no argument tags to terminate with a space, ie: @h1 {` or `@date`
     - HTML Tags, a la @h1() { }
*/
import Core
import Foundation

var workDir: String {
    let parent = #file.characters.split(separator: "/").map(String.init).dropLast().joined(separator: "/")
    let path = "/\(parent)/../../Resources/"
    return path
}

func loadLeaf(named name: String) throws -> Leaf {
    let stem = Stem()
    let template = try stem.loadLeaf(named: name)
    return template
}

func load(path: String) throws -> Bytes {
    guard let data = NSData(contentsOfFile: path) else {
        throw "unable to load bytes"
    }
    var bytes = Bytes(repeating: 0, count: data.length)
    data.getBytes(&bytes, length: bytes.count)
    return bytes
}

public enum Parameter {
    case variable(String)
    case constant(String)
}

extension Leaf {
    public enum Component {
        case raw(Bytes)
        case tagTemplate(TagTemplate)
        case chain([TagTemplate])
    }
}

enum Argument {
    case variable(key: String, value: Any?)
    case constant(value: String)
}

// TODO: Should optional be renderable, and render underlying?
protocol Renderable {
    func rendered() throws -> Bytes
}

extension Stem {
    func loadLeaf(raw: String) throws -> Leaf {
        return try loadLeaf(raw: raw.bytes)
    }

    func loadLeaf(raw: Bytes) throws -> Leaf {
        let raw = raw.trimmed(.whitespace)
        var buffer = Buffer(raw)
        let components = try buffer.components().map(postcompile)
        let template = Leaf(raw: raw.string, components: components)
        return template
    }

    func loadLeaf(named name: String) throws -> Leaf {
        var subpath = name.finished(with: SUFFIX)
        if subpath.hasPrefix("/") {
            subpath = String(subpath.characters.dropFirst())
        }
        let path = workingDirectory + subpath

        let raw = try load(path: path)
        return try loadLeaf(raw: raw)
    }

    private func postcompile(_ component: Leaf.Component) throws -> Leaf.Component {
        func commandPostcompile(_ tagTemplate: TagTemplate) throws -> TagTemplate {
            guard let command = tags[tagTemplate.name] else { throw "unsupported tagTemplate: \(tagTemplate.name)" }
            return try command.postCompile(stem: self,
                                           tagTemplate: tagTemplate)
        }

        switch component {
        case .raw(_):
            return component
        case let .tagTemplate(tagTemplate):
            let updated = try commandPostcompile(tagTemplate)
            return .tagTemplate(updated)
        case let .chain(tagTemplates):
            let mapped = try tagTemplates.map(commandPostcompile)
            return .chain(mapped)
        }
    }
}

extension TagTemplate {
    func makeArguments(filler: Scope) -> [Argument] {
        var input = [Argument]()
        parameters.forEach { arg in
            switch arg {
            case let .variable(key):
                let value = filler.get(path: key)
                input.append(.variable(key: key, value: value))
            case let .constant(c):
                input.append(.constant(value: c))
            }
        }
        return input
    }
}

final class _Include: Tag {
    let name = "include"

    // TODO: Use
    var cache: [String: Leaf] = [:]

    func postCompile(
        stem: Stem,
        tagTemplate: TagTemplate) throws -> TagTemplate {
        guard tagTemplate.parameters.count == 1 else { throw "invalid include" }
        switch tagTemplate.parameters[0] {
        case let .constant(name): // ok to be subpath, NOT ok to b absolute
            let body = try stem.loadLeaf(named: name)
            return TagTemplate(
                name: tagTemplate.name,
                parameters: [], // no longer need parameters
                body: body
            )
        case let .variable(name):
            throw "include's must not be dynamic, try `@include(\"\(name)\")"
        }
    }

    func run(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument]) throws -> Any? {
        return nil
    }

    func shouldRender(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument], value: Any?) -> Bool {
        // throws at precompile, should always render
        return true
    }
}

final class _Loop: Tag {
    let name = "loop"

    func run(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument]) throws -> Any? {
        guard arguments.count == 2 else {
            throw "loop requires two arguments, var w/ array, and constant w/ sub name"
        }

        switch (arguments[0], arguments[1]) {
        case let (.variable(key: _, value: value?), .constant(value: innername)):
            let array = value as? [Any] ?? [value]
            return array.map { [innername: $0] }
        // return true
        default:
            return nil
            // return false
        }
    }

    func render(stem: Stem, filler: Scope, value: Any?, template: Leaf) throws -> Bytes {
        guard let array = value as? [Any] else { fatalError() }

        // return try array.map { try template.render(with: $0) } .flatMap { $0 + [.newLine] }
        return try array
            .map { item -> Bytes in
                if let i = item as? FuzzyAccessible {
                    filler.push(i)
                } else {
                    filler.push(["self": item])
                }

                let rendered = try template.render(in: stem, with: filler)

                filler.pop()

                return rendered
            }
            .flatMap { $0 + [.newLine] }
    }
}

final class _Uppercased: Tag {

    let name = "uppercased"

    func run(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument]) throws -> Any? {
        guard arguments.count == 1 else { throw "\(self) only accepts single arguments" }
        switch arguments[0] {
        case let .constant(value: value):
            return value.uppercased()
        case let .variable(key: _, value: value as String):
            return value.uppercased()
        case let .variable(key: _, value: value as Renderable):
            return try value.rendered().string.uppercased()
        case let .variable(key: _, value: value?):
            return "\(value)".uppercased()
        default:
            return nil
        }
    }

    func process(arguments: [Argument], with filler: Scope) throws -> Bool {
        guard arguments.count == 1 else { throw "uppercase only accepts single arguments" }
        switch arguments[0] {
        case let .constant(value: value):
            filler.push(["self": value.uppercased()])
        case let .variable(key: _, value: value as String):
            filler.push(["self": value.uppercased()])
        case let .variable(key: _, value: value as Renderable):
            let uppercased = try value.rendered().string.uppercased()
            filler.push(["self": uppercased])
        case let .variable(key: _, value: value?):
            filler.push(["self": "\(value)".uppercased()])
        default:
            return false
        }

        return true
    }
}

final class _Else: Tag {
    let name = "else"
    func run(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument]) throws -> Any? {
        return nil
    }
    func shouldRender(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument], value: Any?) -> Bool {
        return true
    }
}

final class _If: Tag {
    let name = "if"

    func run(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument]) throws -> Any? {
        guard arguments.count == 1 else { throw "invalid if statement arguments" }
        return nil
    }

    func shouldRender(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument], value: Any?) -> Bool {
        guard arguments.count == 1 else { return false }
        let argument = arguments[0]
        switch argument {
        case let .constant(value: value):
            let bool = Bool(value)
            return bool == true
        case let .variable(key: _, value: value as Bool):
            return value
        case let .variable(key: _, value: value as String):
            let bool = Bool(value)
            return bool == true
        case let .variable(key: _, value: value as Int):
            return value == 1
        case let .variable(key: _, value: value as Double):
            return value == 1.0
        case let .variable(key: _, value: value):
            return value != nil
        }
    }
}

final class _Variable: Tag {
    let name = "" // empty name, ie: @(variable)

    func run(stem: Stem, filler: Scope, tagTemplate: TagTemplate, arguments: [Argument]) throws -> Any? {
        /*
         Currently ALL '@' signs are interpreted as tagTemplates.  This means to escape in

         name@email.com

         We'd have to do:

         name@("@")email.com

         or more pretty

         contact-email@("@email.com")

         By having this uncommented, we could allow

         name@()email.com
         */
        if arguments.isEmpty { return [TOKEN].string } // temporary escaping mechanism?
        guard arguments.count == 1 else { throw "invalid var argument" }
        let argument = arguments[0]
        switch argument {
        case let .constant(value: value):
            return value
        case let .variable(key: _, value: value):
            return value
        }
    }
}

extension Leaf: CustomStringConvertible {
    public var description: String {
        let components = self.components.map { $0.description } .joined(separator: ", ")
        return "Leaf: " + components
    }
}

extension Leaf.Component: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .raw(r):
            return ".raw(\(r.string))"
        case let .tagTemplate(i):
            return ".tagTemplate(\(i))"
        case let .chain(chain):
            return ".chain(\(chain))"
        }
    }
}

extension TagTemplate: CustomStringConvertible {
    public var description: String {
        return "(name: \(name), parameters: \(parameters), body: \(body)"
    }
}

extension Parameter: CustomStringConvertible {
    public var description: String {
        switch self {
        case let .variable(v):
            return ".variable(\(v))"
        case let .constant(c):
            return ".constant(\(c))"
        }
    }
}

extension Leaf.Component: Equatable {}
public func == (lhs: Leaf.Component, rhs: Leaf.Component) -> Bool {
    switch (lhs, rhs) {
    case let (.raw(l), .raw(r)):
        return l == r
    case let (.tagTemplate(l), .tagTemplate(r)):
        return l == r
    default:
        return false
    }
}

extension Leaf: Equatable {}
public func == (lhs: Leaf, rhs: Leaf) -> Bool {
    return lhs.components == rhs.components
}

extension TagTemplate: Equatable {}
public func == (lhs: TagTemplate, rhs: TagTemplate) -> Bool {
    return lhs.name == rhs.name
        && lhs.parameters == rhs.parameters
        && lhs.body == rhs.body
}

extension Parameter: Equatable {}
public func == (lhs: Parameter, rhs: Parameter) -> Bool {
    switch (lhs, rhs) {
    case let (.variable(l), .variable(r)):
        return l == r
    case let (.constant(l), .constant(r)):
        return l == r
    default:
        return false
    }
}

extension Parameter {
    init<S: Sequence where S.Iterator.Element == Byte>(_ bytes: S) throws {
        let bytes = bytes.array.trimmed(.whitespace)
        guard !bytes.isEmpty else { throw "invalid argument: empty" }
        if bytes.first == .quotationMark {
            guard bytes.count > 1 && bytes.last == .quotationMark else { throw "invalid argument: missing-trailing-quotation" }
            self = .constant(bytes.dropFirst().dropLast().string)
        } else {
            self = .variable(bytes.string)
        }
    }
}

extension Scope {
    func rendered(path: String) throws -> Bytes? {
        guard let value = self.get(path: path) else { return nil }
        guard let renderable = value as? Renderable else {
            let made = "\(value)".bytes
            print("Made: \(made.string)")
            print("")
            return made
        }
        return try renderable.rendered()
    }
}

let Default = Stem()

extension Leaf {
    func render(in stem: Stem, with filler: Scope) throws -> Bytes {
        let initialQueue = filler.queue
        defer { filler.queue = initialQueue }

        var buffer = Bytes()
        try components.forEach { component in
            switch component {
            case let .raw(bytes):
                buffer += bytes
            case let .tagTemplate(tagTemplate):
                guard let command = stem.tags[tagTemplate.name] else { throw "unsupported tagTemplate" }
                let arguments = try command.makeArguments(
                    stem: stem,
                    filler: filler,
                    tagTemplate: tagTemplate
                )

                let value = try command.run(stem: stem, filler: filler, tagTemplate: tagTemplate, arguments: arguments)
                let shouldRender = command.shouldRender(
                    stem: stem,
                    filler: filler,
                    tagTemplate: tagTemplate,
                    arguments: arguments,
                    value: value
                )
                guard shouldRender else { return }

                switch value {
                    //case let fuzzy as FuzzyAccessible:
                //filler.push(fuzzy)
                case let val?: // unwrap if possible to remove from printing
                    filler.push(["self": val])
                default:
                    filler.push(["self": value])
                }

                if let subtemplate = tagTemplate.body {
                    buffer += try command.render(stem: stem, filler: filler, value: value, template: subtemplate)
                } else if let rendered = try filler.rendered(path: "self") {
                    buffer += rendered
                }
            case let .chain(chain):
                /**
                 *********************
                 ****** WARNING ******
                 *********************
                 
                 Deceptively similar to above, nuance will break e'rything!
                 **/
                print("Chain: \n\(chain.map { "\($0)" } .joined(separator: "\n"))")
                for tagTemplate in chain {
                    // TODO: Copy pasta, clean up
                    guard let command = stem.tags[tagTemplate.name] else { throw "unsupported tagTemplate" }
                    let arguments = try command.makeArguments(
                        stem: stem,
                        filler: filler,
                        tagTemplate: tagTemplate
                    )

                    let value = try command.run(stem: stem, filler: filler, tagTemplate: tagTemplate, arguments: arguments)
                    let shouldRender = command.shouldRender(
                        stem: stem,
                        filler: filler,
                        tagTemplate: tagTemplate,
                        arguments: arguments,
                        value: value
                    )
                    guard shouldRender else {
                        // ** WARNING **//
                        continue
                    }

                    switch value {
                        //case let fuzzy as FuzzyAccessible:
                    //filler.push(fuzzy)
                    case let val?:
                        filler.push(["self": val])
                    default:
                        filler.push(["self": value])
                    }

                    if let subtemplate = tagTemplate.body {
                        buffer += try command.render(stem: stem, filler: filler, value: value, template: subtemplate)
                    } else if let rendered = try filler.rendered(path: "self") {
                        buffer += rendered
                    }

                    // NECESSARY TO POP!
                    filler.pop()
                    return // Once a link in the chain is marked as pass (shouldRender), break scope
                }
            }
        }
        return buffer
    }

/*
    func _render(with filler: Scope) throws -> Bytes {
        let initialQueue = filler.queue
        defer { filler.queue = initialQueue }

        var buffer = Bytes()
        try components.forEach { component in
            switch component {
            case let .raw(bytes):
                buffer += bytes
            case let .tagTemplate(tagTemplate):
                guard let command = tags[tagTemplate.name] else { throw "unsupported tagTemplate" }

                let arguments = try command.preprocess(tagTemplate: tagTemplate, with: filler)
                print(arguments)
                let shouldRender = try command.process(
                    arguments: arguments,
                    with: filler
                )
                print(shouldRender)
                guard shouldRender else { return }
                let template = try command.prerender(
                    tagTemplate: tagTemplate,
                    arguments: arguments,
                    with: filler
                )
                if let template = template {
                    buffer += try command.render(template: template, with: filler)
                } else if let rendered = try filler.rendered(path: "self") {
                    buffer += rendered
                }
            case let .chain(chain):
                for tagTemplate in chain {
                    guard let command = tags[tagTemplate.name] else { throw "unsupported tagTemplate" }
                    let arguments = try command.preprocess(tagTemplate: tagTemplate, with: filler)
                    let shouldRender = try command.process(arguments: arguments, with: filler)
                    guard shouldRender else { continue }
                    if let template = tagTemplate.body {
                        buffer += try command.render(template: template, with: filler)
                    } else if let rendered = try filler.rendered(path: "self") {
                        buffer += rendered
                    }
                    return // Once a link in the chain is marked as pass (shouldRender), break scope
                }
            }
        }
        return buffer
    }
 */
}

extension Leaf.Component {
    mutating func addToChain(_ chainedInstruction: TagTemplate) throws {
        switch self {
        case .raw(_):
            throw "unable to chain \(chainedInstruction) w/o preceding tagTemplate"
        case let .tagTemplate(current):
            self = .chain([current, chainedInstruction])
        case let .chain(chain):
            self = .chain(chain + [chainedInstruction])
        }
    }
}