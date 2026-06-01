import TranscriptEvent from './TranscriptEvent';
export default interface TranscriptionController {
    /**
     * Subscribe a callback to handle received transcript event
     */
    subscribeToTranscriptEvent(callback: (transcriptEvent: TranscriptEvent) => void): void;
    /**
     * Unsubscribe a callback from receiving transcript event
     */
    unsubscribeFromTranscriptEvent(callback: (transcriptEvent: TranscriptEvent) => void): void;
}
