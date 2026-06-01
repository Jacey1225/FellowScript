import VideoStreamIdSet from './VideoStreamIdSet';
/**
 * [[DefaultVideoStreamIdSet]] implements [[VideoStreamIdSet]].
 */
export default class DefaultVideoStreamIdSet implements VideoStreamIdSet {
    private ids;
    constructor(ids?: number[]);
    add(streamId: number): void;
    array(): number[];
    contain(streamId: number): boolean;
    forEach(callbackFn: (streamId: number) => void): void;
    empty(): boolean;
    size(): number;
    equal(other: DefaultVideoStreamIdSet): boolean;
    clone(): DefaultVideoStreamIdSet;
    remove(streamId: number): void;
    toJSON(): number[];
    truncate(length: number): DefaultVideoStreamIdSet;
}
