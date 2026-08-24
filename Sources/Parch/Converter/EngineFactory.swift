import Logging

enum EngineFactory {
    static func make(
        choice: EngineChoice,
        condaEnv: String,
        logger: Logger
    ) -> (primary: ConversionEngine, fallback: FallbackPolicy?) {
        switch choice {
        case .vision:
            return (VisionEngine(logger: logger), nil)
        case .marker:
            return (MarkerEngine(condaEnv: condaEnv, logger: logger), nil)
        case .ovis:
            return (OvisEngine(logger: logger), nil)
        case .auto:
            let marker: ConversionEngine? = MarkerEngine.isAvailable(condaEnv: condaEnv)
                ? MarkerEngine(condaEnv: condaEnv, logger: logger)
                : nil
            let ovis: ConversionEngine? = OvisEngine.isAvailable()
                ? OvisEngine(logger: logger)
                : nil

            let available = [marker == nil ? nil : "marker", ovis == nil ? nil : "ovis"]
                .compactMap { $0 }
            if available.isEmpty {
                logger.info("Auto mode: Vision only (no fallback engines detected)")
                return (VisionEngine(logger: logger), nil)
            }
            logger.info("Auto mode: Vision primary, fallbacks available: \(available.joined(separator: ", "))")
            return (
                VisionEngine(logger: logger),
                FallbackPolicy(marker: marker, ovis: ovis)
            )
        }
    }
}
