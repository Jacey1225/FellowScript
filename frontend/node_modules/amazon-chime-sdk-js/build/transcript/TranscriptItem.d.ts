import Attendee from '../attendee/Attendee';
import TranscriptItemType from './TranscriptItemType';
export default class TranscriptItem {
    type: TranscriptItemType;
    startTimeMs: number;
    endTimeMs: number;
    attendee: Attendee;
    content: string;
    vocabularyFilterMatch?: boolean;
    confidence?: number;
    stable?: boolean;
}
