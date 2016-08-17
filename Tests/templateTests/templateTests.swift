import Core
import Foundation
import XCTest
@testable import template

var workDir: String {
    let parent = #file.characters.split(separator: "/").map(String.init).dropLast().joined(separator: "/")
    let path = "/\(parent)/../../Resources/"
    return path
}

func loadTemplate(named: String) throws -> Template {
    let helloData = NSData(contentsOfFile: workDir + "\(named).vt")!
    var bytes = Bytes(repeating: 0, count: helloData.length)
    helloData.getBytes(&bytes, length: bytes.count)
    return try Template(raw: bytes.string)
}

class FuzzyAccessibleTests: XCTestCase {
    func testSingleDictionary() {
        let object: [String: Any] = [
            "hello": "world"
        ]
        let result = object.get(key: "hello")
        XCTAssertNotNil(result)
        guard let unwrapped = result else { return }
        XCTAssert("\(unwrapped)" == "world")
    }

    func testSingleArray() {
        let object: [Any] = [
            "hello",
            "world"
        ]

        let assertions: [String: String] = [
            "0": "Optional(\"hello\")",
            "1": "Optional(\"world\")",
            "2": "nil",
            "notidx": "nil"
        ]
        assertions.forEach { key, expectation in
            let result = object.get(key: key)
            print("\(result)")
            XCTAssert("\(result)" == expectation)
        }
    }

    func testLinkedDictionary() {
        let object: [String: Any] = [
            "hello": [
                "subpath": [
                    "to": [
                        "value": "Hello!"
                    ]
                ]
            ]
        ]

        let result = object.get(path: "hello.subpath.to.value")
        XCTAssertNotNil(result)
        guard let unwrapped = result else { return }
        XCTAssert("\(unwrapped)" == "Hello!")
    }

    func testLinkedArray() {
        let object: [Any] = [
            // 0
            [Any](arrayLiteral:
                [Any](),
                // 1
                [Any](arrayLiteral:
                    [Any](),
                    [Any](),
                     //2
                    [Any](arrayLiteral:
                        // 0
                        [Any](arrayLiteral:
                            "",
                            "",
                            "",
                            "Hello!" // 3
                        )
                    )
                )
            )
        ]

        let result = object.get(path: "0.1.2.0.3")
        XCTAssertNotNil(result)
        guard let unwrapped = result else { return }
        XCTAssert("\(unwrapped)" == "Hello!", "have: \(unwrapped), want: Hello!")
    }

    func testFuzzyTemplate() throws {
        let raw = "Hello, @(path.to.person.0.name)!"
        let context: [String: Any] = [
            "path": [
                "to": [
                    "person": [
                        ["name": "World"]
                    ]
                ]
            ]
        ]

        let template = try Template(raw: raw)
        let rendered = try template.render(with: context).string
        let expectation = "Hello, World!"
        XCTAssert(rendered == expectation)
    }
}

class TemplateLoadingTests: XCTestCase {
    func testBasicRawOnly() throws {
        let template = try loadTemplate(named: "template-basic-raw")
        XCTAssert(template.components ==  [.raw("Hello, World!".bytes)])
    }

    func testBasicInstructions() throws {
        let template = try loadTemplate(named: "template-basic-instructions-no-body")
        // @custom(two, variables, "and one constant")
        let instruction = try Template.Component.Instruction(
            name: "custom",
            parameters: [.variable("two"), .variable("variables"), .constant("and one constant")],
            body: nil
        )

        let expectation: [Template.Component] = [
            .raw("Some raw text here. ".bytes),
            .instruction(instruction)
        ]
        XCTAssert(template.components ==  expectation)
    }

    func testBasicNested() throws {
        /*
            Here's a basic template and, @command(parameter) {
                now we're in the body, which is ALSO a @template("constant") {
                    and a third sub template with a @(variable)
                }
            }

        */
        let template = try loadTemplate(named: "template-basic-nested")

        let command = try Template.Component.Instruction(
            name: "command",
            // TODO: `.variable(name: `
            parameters: [.variable("parameter")],
            body: "now we're in the body, which is ALSO a @template(\"constant\") {\n\tand a third sub template with a @(variable)\n\t}"
        )

        let expectation: [Template.Component] = [
            .raw("Here's a basic template and, ".bytes),
            .instruction(command)
        ]
        XCTAssert(template.components ==  expectation)
    }
}

class TemplateRenderTests: XCTestCase {
    func testBasicRender() throws {
        let template = try loadTemplate(named: "basic-render")
        let contexts = ["a", "ab9***", "ajcm301kc,s--11111", "World", "👾"]

        try contexts.forEach { context in
            let expectation = "Hello, \(context)!"
            let rendered = try template.render(with: context)
                .string
            XCTAssert(rendered == expectation, "have: \(rendered), want: \(expectation)")
        }
    }

    func testNestedBodyRender() throws {
        let template = try loadTemplate(named: "nested-body")

        let contextTests: [[String: Any]] = [
            ["best-friend": ["name": "World"]],
            ["best-friend": ["name": "@@"]],
            ["best-friend": ["name": "!*7D0"]]
        ]

        try contextTests.forEach { ctxt in
            let rendered = try template.render(with: ctxt)
            let name = (ctxt["best-friend"] as! Dictionary<String, Any>)["name"] as? String ?? "[fail]"
            XCTAssert(rendered.string == "Hello, \(name)!", "got: **\(rendered.string)** expected: **\("Hello, \(name)!")**")
        }
    }
}

class LoopTests: XCTestCase {
    func testBasicLoop() throws {
        let template = try loadTemplate(named: "basic-loop")

        let context: [String: [Any]] = [
            "friends": [
                "asdf",
                "🐌",
                "8***z0-1",
                12
            ]
        ]

        let expectation = "Hello, asdf\nHello, 🐌\nHello, 8***z0-1\nHello, 12\n"
        let rendered = try template.render(with: context).string
        XCTAssert(rendered == expectation, "have: \(rendered), want: \(expectation)")
    }

    func testComplexLoop() throws {
        let context: [String: Any] = [
            "friends": [
                [
                    "name": "Venus",
                    "age": 12345
                ],
                [
                    "name": "Pluto",
                    "age": 888
                ],
                [
                    "name": "Mercury",
                    "age": 9000
                ]
            ]
        ]

        let template = try loadTemplate(named: "complex-loop")
        let rendered = try template.render(with: context).string
        let expectation = "<li><b>Venus</b>: 12345</li>\n<li><b>Pluto</b>: 888</li>\n<li><b>Mercury</b>: 9000</li>\n"
        XCTAssert(rendered == expectation, "have: \(rendered) want: \(expectation)")
    }
}

class IfTests: XCTestCase {
    func testBasicIf() throws {
        let template = try loadTemplate(named: "basic-if-test")

        let context = ["say-hello": true]
        let rendered = try template.render(with: context).string
        let expectation = "Hello, there!"
        XCTAssert(rendered == expectation, "have: \(rendered), want: \(expectation)")
    }

    func testBasicIfFail() throws {
        let template = try loadTemplate(named: "basic-if-test")

        let context = ["say-hello": false]
        let rendered = try template.render(with: context).string
        let expectation = ""
        XCTAssert(rendered == expectation, "have: \(rendered), want: \(expectation)")
    }

    func testBasicIfElse() throws {
        let template = try loadTemplate(named: "basic-if-else")
        let helloContext: [String: Any] = [
            "entering": true,
            "friend-name": "World"
        ]
        let renderedHello = try template.render(with: helloContext).string
        let expectedHello = "Hello, World!"
        XCTAssert(renderedHello == expectedHello, "have: \(renderedHello) want: \(expectedHello)")

        let goodbyeContext: [String: Any] = [
            "entering": false,
            "friend-name": "World"
        ]
        let renderedGoodbye = try template.render(with: goodbyeContext).string
        let expectedGoodbye = "Goodbye, World!"
        XCTAssert(renderedGoodbye == expectedGoodbye, "have: \(renderedGoodbye) want: \(expectedGoodbye)")
    }

    func testNestedIfElse() throws {
        let template = try loadTemplate(named: "nested-if-else")
        let expectations: [(input: [String: Any], expectation: String)] = [
            (input: ["a": true], expectation: "Got a."),
            (input: ["b": true], expectation: "Got b."),
            (input: ["c": true], expectation: "Got c."),
            (input: ["d": true], expectation: "Got d."),
            (input: [:], expectation: "Got e.")
        ]

        try expectations.forEach { input, expectation in
            let rendered = try template.render(with: input).string
            XCTAssert(rendered == expectation, "have: \(rendered) want: \(expectation)")
        }
    }
}
