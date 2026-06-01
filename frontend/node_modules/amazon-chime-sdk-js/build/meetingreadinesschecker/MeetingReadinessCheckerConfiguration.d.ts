/**
 * [[MeetingReadinessCheckerConfiguration]] includes custom settings used for MeetingReadinessChecker
 */
export default class MeetingReadinessCheckerConfiguration {
    /**
     * Specify how long to wait for each check in a test.
     * If null, it will use the default value.
     */
    timeoutMs: number;
    /**
     * Specify the wait time before checking again when a check condition is not met.
     * If null, it will use the default value.
     */
    waitDurationMs: number;
    /**
     * Specify the frequency of oscillation in hertz for the audio output test.
     */
    audioOutputFrequency?: number;
    /**
     * Specify the gain value from 0 to 1.0 for the audio output test.
     */
    audioOutputGain?: number;
}
