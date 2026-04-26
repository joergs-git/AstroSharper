// Shared Metal device + command queue + default library.
// One instance per app.
import Metal
import MetalKit

final class MetalDevice {
    static let shared = MetalDevice()

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary?

    private init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal not supported on this Mac")
        }
        guard let queue = device.makeCommandQueue() else {
            fatalError("Failed to create Metal command queue")
        }
        self.device = device
        self.commandQueue = queue
        // Default library pulls in all .metal files compiled into the bundle.
        // May be nil in M1 if no shaders exist yet — harmless.
        self.library = try? device.makeDefaultLibrary(bundle: .main)
    }
}
