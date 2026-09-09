import Foundation
#if SPARKLE_PROBE
import Sparkle
// Refer to an exported class so the production-like dynamic dependency is retained.
print("SPARKLE_LOADED: \(String(reflecting: SPUStandardUpdaterController.self))")
#else
print("BASELINE_LOADED")
#endif
