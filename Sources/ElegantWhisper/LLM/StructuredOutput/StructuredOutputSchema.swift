import Foundation

struct ResponseFormat: Encodable {
    let type: String
    let jsonSchema: JSONSchemaResponseFormat

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }

    static let dictationPolishResult = ResponseFormat(
        type: "json_schema",
        jsonSchema: JSONSchemaResponseFormat(
            name: "dictation_polish_result",
            strict: true,
            schema: JSONSchemaObject(
                type: "object",
                additionalProperties: false,
                required: ["corrected_text"],
                properties: [
                    "corrected_text": JSONSchemaProperty(type: "string")
                ]
            )
        )
    )
}

struct JSONSchemaResponseFormat: Encodable {
    let name: String
    let strict: Bool
    let schema: JSONSchemaObject
}

struct JSONSchemaObject: Encodable {
    let type: String
    let additionalProperties: Bool
    let required: [String]
    let properties: [String: JSONSchemaProperty]
}

struct JSONSchemaProperty: Encodable {
    let type: String
}

struct DictationPolishResult: Decodable {
    let correctedText: String

    enum CodingKeys: String, CodingKey {
        case correctedText = "corrected_text"
    }
}
