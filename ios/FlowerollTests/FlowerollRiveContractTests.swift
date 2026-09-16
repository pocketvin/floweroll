import CryptoKit
import RiveRuntime
import XCTest
@testable import Floweroll

@MainActor
final class FlowerollRiveContractTests: XCTestCase {
    private let expectedSHA256 = "4b1dab6737e4f3dbcf95c64a808866d1e935317bf557801d23a68bab30daf295"

    private func shippingData() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "floweroll-home", withExtension: "riv"),
            "shipping app bundle must contain floweroll-home.riv"
        )
        return try Data(contentsOf: url)
    }

    func testShippingRiveAssetIdentityAndStateMachineContract() throws {
        let data = try shippingData()
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, expectedSHA256)
        XCTAssertEqual(data.count, 800_071)

        let file = try RiveFile(data: data, loadCdn: false)
        let model = RiveModel(riveFile: file)
        try model.setArtboard("FlowerollOfficial")
        try model.setStateMachine("FlowerollStateMachine")
        let stateMachine = try XCTUnwrap(model.stateMachine)
        let inputs = Dictionary(uniqueKeysWithValues: stateMachine.inputs.map { ($0.name, $0.type) })

        XCTAssertEqual(inputs["poke"], .trigger)
        XCTAssertEqual(inputs["isListening"], .boolean)
        XCTAssertEqual(inputs["lookX"], .number)
        XCTAssertEqual(inputs["lookY"], .number)
    }

    func testRequiredAuthoredAnimationsRemainAvailable() throws {
        let data = try shippingData()
        for name in [
            "idle", "poke", "listening",
            "lookLeft", "lookCenterX", "lookRight",
            "lookUp", "lookCenterY", "lookDown",
        ] {
            let file = try RiveFile(data: data, loadCdn: false)
            let model = RiveModel(riveFile: file)
            try model.setArtboard("FlowerollOfficial")
            try model.setAnimation(name)
            XCTAssertNotNil(model.animation, "missing authored Rive animation: \(name)")
        }
    }
}
