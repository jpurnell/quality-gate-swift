import Testing
@testable import DesignTokenDriftAuditor

@Suite("TokenSet")
struct TokenSetTests {

    @Test("Colours are the hex custom properties, light and dark both; the -rgb triples are not colours")
    func colours() {
        let tokens = TokenFixtures.tokens
        #expect(tokens.colours.map(\.name) == ["label", "accent", "destructive", "accent"])
        let accents = tokens.colours.filter { $0.name == "accent" }
        #expect(accents.map { [$0.red, $0.green, $0.blue] } == [[255, 141, 40], [255, 146, 48]])
    }

    @Test("Type sizes keep plain lengths only; the clamp() display size is not a size")
    func typeSizes() {
        let sizes = TokenFixtures.tokens.typeSizes
        #expect(sizes.map(\.name) == ["label", "caption", "body", "heading", "title"])
        #expect(sizes.map(\.px) == [11, 13, 16, 28, 34])
    }

    @Test("Radii, gutter and column count")
    func geometry() {
        let tokens = TokenFixtures.tokens
        #expect(tokens.radii.map(\.name) == ["container", "control"])
        #expect(tokens.radii.map(\.px) == [0, 4])
        #expect(tokens.gutterPx == 16)
        #expect(tokens.columns == 12)
    }

    @Test("An empty or token-free file is an empty set")
    func empty() {
        #expect(TokenSet.parse(css: "").isEmpty)
        #expect(TokenSet.parse(css: ".a { color: #E77500; }").isEmpty)
        #expect(!TokenFixtures.tokens.isEmpty)
    }

    @Test("Nearest colour by Euclidean sRGB distance", arguments: [
        (255, 141, 41, "accent", 1.0),
        (255, 141, 40, "accent", 0.0),
        (231, 117, 0, "accent", 52.46),
        (255, 60, 60, "destructive", 4.0),
    ] as [(Int, Int, Int, String, Double)])
    func nearestColour(red: Int, green: Int, blue: Int, name: String, distance: Double) throws {
        let nearest = try #require(TokenFixtures.tokens.nearestColour(red: red, green: green, blue: blue))
        #expect(nearest.colour.name == name)
        #expect(abs(nearest.distance - distance) < 0.01)
    }

    @Test("Nearest type role by size; ties go to the smaller", arguments: [
        (14.0, "caption"), (24.0, "heading"), (16.0, "body"), (40.0, "title"), (12.0, "label"),
    ] as [(Double, String)])
    func nearestType(px: Double, name: String) {
        #expect(TokenFixtures.tokens.nearestTypeRole(px: px)?.name == name)
    }

    @Test("Nearest radius; a tie goes to the smaller", arguments: [
        (8.0, "control"), (0.0, "container"), (2.0, "container"), (5.0, "control"),
    ] as [(Double, String)])
    func nearestRadius(px: Double, name: String) {
        #expect(TokenFixtures.tokens.nearestRadius(px: px)?.name == name)
    }
}
