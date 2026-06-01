export default class DeviceSelection {
    constraints: MediaStreamConstraints;
    stream: MediaStream;
    groupId: string;
    endedCallback?: undefined | (() => void);
    trackMuteCallback?: undefined | (() => void);
    trackUnmuteCallback?: undefined | (() => void);
    matchesConstraints(constraints: MediaStreamConstraints): boolean;
}
