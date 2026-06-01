import JSONIngestionPayloadItem from './JSONIngestionPayloadItem';
export default interface JSONIngestionEvent {
    type: string;
    v: number;
    payloads: JSONIngestionPayloadItem[];
}
