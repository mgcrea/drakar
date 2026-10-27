import DrakarKit
import Foundation
import Testing

/// An MCP elicitation as claude 2.1.311 forwards it (`Fixture.elicitation`), read into a card.
@Suite("An MCP server's question")
struct ElicitationTests {

  /// The `request` object of the fixture's line `index`.
  private func request(_ index: Int) throws -> JSONValue {
    try #require(try JSONValue.parse(Fixture.elicitation.lines[index])["request"])
  }

  private func json(_ text: String) throws -> JSONValue {
    try JSONValue.parse(Data(text.utf8))
  }

  /// The captured `ask_team` form.
  private func captured() throws -> ElicitationForm {
    let schema = try #require(request(0)["requested_schema"])
    return try #require(ElicitationForm(schema: schema, order: nil))
  }

  /// A form of one property, `field`, its schema `property`.
  private func form(_ property: String) throws -> ElicitationForm {
    let schema = try json(#"{"type":"object","properties":{"field":\#(property)}}"#)
    return try #require(ElicitationForm(schema: schema, order: nil))
  }

  private func field(_ property: String, key: String = "field") throws -> ElicitationField {
    let schema = try json(#"{"type":"object","properties":{"\#(key)":\#(property)}}"#)
    return try #require(ElicitationForm(schema: schema, order: nil)?.fields.first)
  }

  /// A form request around `schema`, as the CLI would forward it.
  private func elicitation(schema: String) throws -> Elicitation {
    try #require(
      Elicitation(
        claudeRequest: try json(
          #"{"subtype":"elicitation","mcp_server_name":"s","message":"m","mode":"form","requested_schema":\#(schema)}"#
        )))
  }

  @Test func readsAFormRequest() throws {
    let elicitation = try #require(Elicitation(claudeRequest: try request(0)))
    #expect(elicitation.serverName == "elicit")
    #expect(elicitation.serverLabel == "elicit")
    #expect(elicitation.message == "Which team?")
    #expect(elicitation.title == nil)
    #expect(elicitation.description == nil)
    #expect(elicitation.elicitationID == nil)
    guard case .form(let form) = elicitation.content else {
      Issue.record("not a form: \(elicitation.content)")
      return
    }
    #expect(form.fields.map(\.key) == ["team", "size", "api_token", "notify"])
    #expect(form.fields.map(\.title) == ["Team", "Size", "API token", "Notify"])
    #expect(form.fields.map(\.isRequired) == [true, true, false, false])
  }

  @Test func readsALinkRequest() throws {
    let elicitation = try #require(Elicitation(claudeRequest: try request(4)))
    #expect(elicitation.serverName == "elicit")
    #expect(elicitation.message == "Sign in to continue")
    #expect(elicitation.content == .url(URL(string: "https://example.com/auth?x=1")!))
    #expect(elicitation.elicitationID == "el-1")
  }

  /// `display_name` names the server when it comes; nothing to show at all is no card.
  @Test func namesTheServer() throws {
    let named = try #require(
      Elicitation(
        claudeRequest: try json(
          #"{"mcp_server_name":"elicit","display_name":"Elicit","message":"m","mode":"url","url":"https://example.com"}"#
        )))
    #expect(named.serverLabel == "Elicit")
    let anonymous = try #require(Elicitation(claudeRequest: try json(#"{"message":"m"}"#)))
    #expect(anonymous.serverName == "")
    #expect(Elicitation(claudeRequest: try json(#"{"mode":"form"}"#)) == nil)
  }

  @Test func ordersRequiredFirstWithoutPropertyOrder() throws {
    #expect(try captured().fields.map(\.key) == ["team", "size", "api_token", "notify"])
  }

  @Test func keysMissingFromTheOrderComeLast() throws {
    let schema = try #require(request(0)["requested_schema"])
    let form = try #require(ElicitationForm(schema: schema, order: ["notify"]))
    #expect(form.fields.map(\.key) == ["notify", "api_token", "size", "team"])
  }

  @Test func marksSecrets() throws {
    #expect(try captured().fields.filter(\.isSecret).map(\.key) == ["api_token"])
    let secrets = [
      "password", "Passphrase", "client_secret", "API key", "apiToken", "accessToken",
      "authToken", "githubToken", "userPassword", "newPassword", "clientSecret", "openaiApiKey",
      "password2",
    ]
    for key in secrets {
      #expect(try field(#"{"type":"string"}"#, key: key).isSecret, "\(key)")
      #expect(try field(#"{"type":"string","title":"\#(key)"}"#).isSecret, "\(key)")
    }
    for key in ["passport", "tokens_used_label"] {
      #expect(try !field(#"{"type":"string"}"#, key: key).isSecret, "\(key)")
      #expect(try !field(#"{"type":"string","title":"\#(key)"}"#).isSecret, "\(key)")
    }
  }

  /// A number is typed like text, so a secret one is hidden too; a choice or a flag shows
  /// nothing typed and never is.
  @Test func marksSecretNumbersOnly() throws {
    #expect(try field(#"{"type":"integer"}"#, key: "secret_code").isSecret)
    #expect(try !field(#"{"type":"boolean"}"#, key: "secret").isSecret)
    #expect(try !field(#"{"type":"string","enum":["a","b"]}"#, key: "token").isSecret)
    #expect(
      try !field(#"{"type":"array","items":{"type":"string","enum":["a"]}}"#, key: "password")
        .isSecret)
  }

  @Test func readsEveryKind() throws {
    let named = try field(#"{"type":"string","enum":["a","b"],"enumNames":["Alpha","Beta"]}"#)
    #expect(
      named.kind
        == .choice([.init(value: "a", title: "Alpha"), .init(value: "b", title: "Beta")]))
    let titled = try field(
      #"{"type":"string","oneOf":[{"const":"a","title":"Alpha"},{"const":"b","title":"Beta"}]}"#)
    #expect(
      titled.kind
        == .choice([.init(value: "a", title: "Alpha"), .init(value: "b", title: "Beta")]))
    let several = try field(
      #"{"type":"array","items":{"type":"string","enum":["a","b"]},"minItems":1,"maxItems":2}"#)
    #expect(
      several.kind
        == .choices(
          [.init(value: "a", title: "a"), .init(value: "b", title: "b")], minItems: 1, maxItems: 2))
    let email = try field(#"{"type":"string","format":"email","maxLength":40}"#)
    #expect(email.kind == .text(minLength: nil, maxLength: 40, format: "email"))
    #expect(
      try field(#"{"type":"number","minimum":0.5}"#).kind
        == .number(isInteger: false, minimum: 0.5, maximum: nil))
    #expect(try field(#"{"type":"boolean"}"#).kind == .flag)
    #expect(try field(#"{"type":"boolean","description":"Ping me"}"#).description == "Ping me")
  }

  @Test func refusesWhatItCannotShow() throws {
    let nested = #"{"type":"object","properties":{"a":{"type":"object","properties":{}}}}"#
    let bareArray =
      #"{"type":"object","properties":{"a":{"type":"array","items":{"type":"string"}}}}"#
    let notObject = #"{"type":"array","items":{"type":"string"}}"#
    for schema in [nested, bareArray, notObject] {
      #expect(try elicitation(schema: schema).content == .unsupported, "\(schema)")
    }
    let file = try #require(
      Elicitation(
        claudeRequest: try json(
          #"{"mcp_server_name":"s","message":"m","mode":"url","url":"file:///etc/passwd"}"#)))
    #expect(file.content == .unsupported)
    let unknown = try #require(
      Elicitation(claudeRequest: try json(#"{"mcp_server_name":"s","message":"m","mode":"chat"}"#)))
    #expect(unknown.content == .unsupported)
  }

  @Test func requiresRequiredFields() throws {
    #expect(try captured().problems(in: [:]) == ["team": "Required", "size": "Required"])
    #expect(try captured().content(from: [:]) == nil)
  }

  @Test func readsNumbersStrictly() throws {
    let form = try captured()
    func check(_ size: String) -> (problem: String?, size: JSONValue?) {
      let inputs: [String: ElicitationInput] = ["team": .picks(["core"]), "size": .text(size)]
      return (form.problems(in: inputs)["size"], form.content(from: inputs)?["size"])
    }
    #expect(check(" 4 ").problem == nil)
    #expect(check(" 4 ").size == .number(4))
    #expect(check("4.0").problem == nil)
    #expect(check("4.0").size == .number(4))
    #expect(check("4.5").problem == "Must be a whole number")
    #expect(check("1,5").problem == "Must be a number")
    #expect(check("1e3").problem == "Must be a number")
    #expect(check("12").problem == "Must be at most 9")
    #expect(check("0").problem == "Must be at least 1")
  }

  @Test func checksLengthAndFormat() throws {
    let short = try form(#"{"type":"string","minLength":3}"#)
    #expect(short.problems(in: ["field": .text("ab")]) == ["field": "At least 3 characters"])
    #expect(short.problems(in: ["field": .text("abc")]).isEmpty)
    let email = try form(#"{"type":"string","format":"email"}"#)
    #expect(email.problems(in: ["field": .text("x")]) == ["field": "Must be an email address"])
    #expect(email.problems(in: ["field": .text("a@b@c")])["field"] == "Must be an email address")
    #expect(email.problems(in: ["field": .text("@b")])["field"] == "Must be an email address")
    #expect(email.problems(in: ["field": .text("a@b")]).isEmpty)
    let date = try form(#"{"type":"string","format":"date"}"#)
    #expect(date.problems(in: ["field": .text("2026-10-27")]).isEmpty)
    #expect(date.problems(in: ["field": .text("27/10/2026")])["field"] != nil)
    let moment = try form(#"{"type":"string","format":"date-time"}"#)
    #expect(moment.problems(in: ["field": .text("2026-10-27T14:30:00Z")]).isEmpty)
    #expect(moment.problems(in: ["field": .text("2026-10-27")])["field"] != nil)
    let link = try form(#"{"type":"string","format":"uri"}"#)
    #expect(link.problems(in: ["field": .text("https://example.com")]).isEmpty)
    #expect(link.problems(in: ["field": .text("example")])["field"] != nil)
  }

  @Test func omitsEmptyOptionalFields() throws {
    let content = try captured().content(from: [
      "team": .picks(["core"]), "size": .text("3"), "api_token": .text(""),
    ])
    #expect(content == ["team": .string("core"), "size": .number(3)])
  }

  @Test func startsFromDefaults() throws {
    let schema = try json(
      #"{"type":"object","properties":{"notify":{"type":"boolean","default":true},"size":{"type":"integer","default":4},"team":{"type":"string","enum":["core","web"],"default":"web"}}}"#
    )
    let inputs = try #require(ElicitationForm(schema: schema, order: nil)).initialInputs
    #expect(inputs["notify"] == .flag(true))
    #expect(inputs["size"] == .text("4"))
    #expect(inputs["team"] == .picks(["web"]))
  }

  /// Only a field with a `default` starts filled in, and a required flag starts off: an
  /// optional flag nobody touched is not sent as false.
  @Test func startsOnlyWhatHasADefault() throws {
    let schema = try json(
      #"{"type":"object","properties":{"agree":{"type":"boolean"},"notify":{"type":"boolean"},"size":{"type":"integer"},"team":{"type":"string","default":"web"}},"required":["agree"]}"#
    )
    let form = try #require(ElicitationForm(schema: schema, order: nil))
    #expect(form.initialInputs == ["agree": .flag(false), "team": .text("web")])
    #expect(
      form.content(from: form.initialInputs) == ["agree": .bool(false), "team": .string("web")])
  }
}
