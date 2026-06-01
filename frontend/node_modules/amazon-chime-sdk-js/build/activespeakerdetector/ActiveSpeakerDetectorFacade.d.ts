import ActiveSpeakerPolicy from '../activespeakerpolicy/ActiveSpeakerPolicy';
/**
 * [[ActiveSpeakerDetectorFacade]] listens to the volume indicator updates from the [[RealtimeController]].
 *
 * When you are done using an `ActiveSpeakerDetectorFacade`, you should perform some
 * cleanup steps in order to avoid memory leaks:
 *
 * 1. Unsubscribe from listeners; e.g., from active speaker callbacks via
 *    {@link ActiveSpeakerDetectorFacade.unsubscribeFromActiveSpeakerDetector}.
 * 2. Drop your reference to the facade to allow it to be garbage collected.
 */
export default interface ActiveSpeakerDetectorFacade {
    subscribeToActiveSpeakerDetector(policy: ActiveSpeakerPolicy, callback: (activeSpeakers: string[]) => void, scoresCallback?: (scores: {
        [attendeeId: string]: number;
    }) => void, scoresCallbackIntervalMs?: number): void;
    unsubscribeFromActiveSpeakerDetector(callback: (activeSpeakers: string[]) => void): void;
}
