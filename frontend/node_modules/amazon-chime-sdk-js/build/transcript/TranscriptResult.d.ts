import TranscriptAlternative from './TranscriptAlternative';
import TranscriptLanguageWithScore from './TranscriptLanguageWithScore';
export default class TranscriptResult {
    resultId: string;
    channelId?: string;
    isPartial: boolean;
    languageCode?: string;
    languageIdentification?: TranscriptLanguageWithScore[];
    startTimeMs: number;
    endTimeMs: number;
    alternatives: TranscriptAlternative[];
}
