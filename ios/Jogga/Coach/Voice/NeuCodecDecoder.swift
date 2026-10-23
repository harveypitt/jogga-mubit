import Foundation
import OnnxRuntimeBindings

/// NeuCodec ONNX decoder: speech token codes → 24 kHz mono PCM.
final class NeuCodecDecoder {
    static let hop = 480 // samples per code at 24 kHz

    private let session: ORTSession

    enum Error: Swift.Error { case noOutput, badOutput }

    init(path: String) throws {
        let env = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setGraphOptimizationLevel(.all)
        try options.setIntraOpNumThreads(2)
        session = try ORTSession(env: env, modelPath: path, sessionOptions: options)
    }

    /// codes → PCM. Input "codes" int32 [1,1,F]; output float32 [1,1,F*480].
    func decode(_ codes: [Int32]) throws -> [Float] {
        var codes = codes
        let data = NSMutableData(
            bytes: &codes, length: codes.count * MemoryLayout<Int32>.size
        )
        let input = try ORTValue(
            tensorData: data, elementType: .int32,
            shape: [1, 1, NSNumber(value: codes.count)]
        )
        let outputNames = try session.outputNames()
        let outputs = try session.run(
            withInputs: ["codes": input],
            outputNames: Set(outputNames),
            runOptions: ORTRunOptions()
        )
        guard let name = outputNames.first,
              let out = outputs[name] else { throw Error.noOutput }
        let outData = try out.tensorData()
        let count = outData.length / MemoryLayout<Float>.size
        guard count > 0 else { throw Error.badOutput }
        var pcm = [Float](repeating: 0, count: count)
        outData.getBytes(&pcm, length: outData.length)
        return pcm
    }
}
