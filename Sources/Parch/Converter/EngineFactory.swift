import Logging

enum EngineFactory {
    static func make(
        choice: EngineChoice,
        condaEnv: String,
        logger: Logger
    ) -> (primary: ConversionEngine, fallback: ConversionEngine?) {
        switch choice {
        case .vision:
            return (VisionEngine(logger: logger), nil)
        case .marker:
            return (MarkerEngine(condaEnv: condaEnv, logger: logger), nil)
        case .ovis:
            return (OvisEngine(logger: logger), nil)
        case .auto:
            let fallback: ConversionEngine? = MarkerEngine.isAvailable()
                ? MarkerEngine(condaEnv: condaEnv, logger: logger)
                : nil
            if fallback != nil {
                logger.info("Auto mode: Vision primary, marker available as fallback")
            } else {
                logger.info("Auto mode: Vision only (marker not detected)")
            }
            return (VisionEngine(logger: logger), fallback)
        }
    }
}
