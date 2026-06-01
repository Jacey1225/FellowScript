import TranscriptEntity from './TranscriptEntity';
import TranscriptItem from './TranscriptItem';
export default class TranscriptAlternative {
    items: TranscriptItem[];
    transcript: string;
    entities?: TranscriptEntity[];
}
