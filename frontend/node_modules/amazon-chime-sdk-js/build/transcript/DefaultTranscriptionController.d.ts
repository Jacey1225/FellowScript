import RealtimeController from '../realtimecontroller/RealtimeController';
import TranscriptEvent from './TranscriptEvent';
import TranscriptionController from './TranscriptionController';
export declare const TRANSCRIPTION_DATA_MESSAGE_TOPIC = "aws:chime:transcription";
export default class DefaultTranscriptionController implements TranscriptionController {
    private realtimeController;
    private readonly transcriptEventCallbacks;
    constructor(realtimeController: RealtimeController);
    subscribeToTranscriptEvent(callback: (transcriptEvent: TranscriptEvent) => void): void;
    unsubscribeFromTranscriptEvent(callback: (transcriptEvent: TranscriptEvent) => void): void;
}
