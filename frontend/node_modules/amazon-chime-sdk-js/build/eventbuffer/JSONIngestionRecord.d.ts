import EventsIngestionMetadata from '../eventreporter/EventsIngestionMetadata';
import JSONIngestionEvent from './JSONIngestionEvent';
export default interface JSONIngestionRecord {
    metadata: EventsIngestionMetadata;
    events: JSONIngestionEvent[];
    authorization?: string;
}
