import SigV4 from './SigV4';
export default class DefaultSigV4 implements SigV4 {
    chimeClient: any;
    constructor(chimeClient: any);
    private makeTwoDigits;
    private hmac;
    private getDateTimeString;
    private getDateString;
    private getSignatureKey;
    signURL(method: string, scheme: string, serviceName: string, hostname: string, path: string, payload: string, queryParams: Map<string, string[]> | null): Promise<string>;
}
