import TranscriptionStatusType from './TranscriptionStatusType';
export default class TranscriptionStatus {
    type: TranscriptionStatusType;
    eventTimeMs: number;
    transcriptionRegion: string;
    transcriptionConfiguration: string;
    message?: string;
}
